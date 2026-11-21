#!/usr/bin/fish
# Run the current git project in a throwaway microVM, then bring the agent's
# work back as git refs you review before merging.
#
#   isolate-vm.fish fc     Firecracker
#   isolate-vm.fish qemu   QEMU microvm
#
# Both boot the same disks:
#   vda  rootfs.ext4   fresh copy of the image from `mise run isolate.build`
#   vdb  cache.ext4    per-project, persistent: /persist (package caches, agent login)
#   vdc  project.ext4  fresh copy of the repo: /workspace
#
# Nothing on the host is shared with the guest. Work comes back only as a git
# bundle written at guest shutdown, fetched into refs/remotes/isolate/*.
#
# Env:
#   ISOLATE_MEM=4096  ISOLATE_CPUS=2
#   ISOLATE_NET=none        no network at all (no sudo needed)
#   ISOLATE_ALLOW="host:5432 192.168.1.10:5432"
#                           extra TCP destinations the guest may reach. "host"
#                           is this machine as 172.16.0.1, so the service must
#                           listen there, not on 127.0.0.1. Also read from
#                           ~/.local/share/isolate/projects/<project>/allow
#   ISOLATE_CACHE_SIZE=32G  size of a newly created cache disk (sparse)

set -l vmm $argv[1]
if not contains -- "$vmm" fc qemu
    echo "usage: isolate-vm.fish fc|qemu" >&2
    exit 2
end

set -l state $HOME/.local/share/isolate
set -l base $state/rootfs.ext4
mkdir -p $state

# One VM at a time: they share the isolate0 TAP and 172.16.0.2.
if not set -q _ISOLATE_LOCKED
    if not flock -n $state/vm.lock true
        echo "isolate: another isolate VM is already running." >&2
        exit 1
    end
    set -x _ISOLATE_LOCKED 1
    exec flock -n $state/vm.lock fish (status filename) $argv
end

if not test -f $base
    echo "isolate: no guest image yet. Run: mise run isolate.build" >&2
    exit 1
end

# --- Project ------------------------------------------------------------------
set -q MISE_ORIGINAL_CWD; and cd $MISE_ORIGINAL_CWD
set -l top (git rev-parse --show-toplevel 2>/dev/null)
if test -z "$top"
    echo "isolate: $PWD is not inside a git repository." >&2
    exit 1
end
set -l pname (path basename $top)
set -l pdir $state/projects/$pname-(echo -n $top | sha256sum | string sub -l 8)
mkdir -p $pdir
echo $top >$pdir/path

# A previous session whose work never made it back keeps its disk.
if test -f $pdir/project.ext4
    set -l keep $pdir/project-unimported-(date +%Y%m%d-%H%M%S).ext4
    mv $pdir/project.ext4 $keep
    echo "isolate: the last session's work was not imported; its disk is kept at"
    echo "         $keep"
end

# --- Kernel: the host's own, copied once per version ---------------------------
set -l kver (uname -r)
set -l kdir $state/kernel
set -l vmlinuz $kdir/vmlinuz-$kver
set -l vmlinux $kdir/vmlinux-$kver
mkdir -p $kdir
if not test -f $vmlinuz; and not test $vmm = fc -a -f $vmlinux
    echo "Copying host kernel $kver (it's root-only readable, so this needs sudo once)."
    sudo install -m 0644 -o (id -u) -g (id -g) /boot/vmlinuz-$kver $vmlinuz.tmp
    and mv $vmlinuz.tmp $vmlinuz
    or exit 1
end
if test $vmm = fc; and not test -f $vmlinux
    # Firecracker only boots an uncompressed ELF kernel.
    set -l extract /usr/src/linux-headers-$kver/scripts/extract-vmlinux
    test -x $extract; or set extract (path filter -x /usr/src/linux-headers-*/scripts/extract-vmlinux)[1]
    if test -z "$extract"
        echo "isolate: extract-vmlinux not found (install linux-headers-$kver)." >&2
        exit 1
    end
    $extract $vmlinuz >$vmlinux.tmp; and mv $vmlinux.tmp $vmlinux
    or begin
        rm -f $vmlinux.tmp
        exit 1
    end
end
# The guest always runs exactly the host's kernel, so copies for any other
# version are dead weight (~85 MB each). Safe: only one VM runs at a time.
for old in $kdir/vmlinu*-*
    string match -q -- "*-$kver" $old; or rm -f $old
end

# --- Disks ------------------------------------------------------------------------
echo "Preparing disks..."
set -l rootfs $pdir/rootfs.ext4
rm -f $rootfs
cp --sparse=always $base $rootfs; or exit 1

set -l cache $pdir/cache.ext4
if not test -f $cache
    set -l csize 32G
    set -q ISOLATE_CACHE_SIZE; and set csize $ISOLATE_CACHE_SIZE
    truncate -s $csize $cache
    mkfs.ext4 -q -F -L isolate-cache -E root_owner=(id -u):(id -g) $cache; or exit 1
end

# Project: the repo's refs plus the working tree exactly as `git status` sees it
# (tracked + untracked, minus ignored). Ignored files such as .env stay behind.
set -l stage $pdir/stage
rm -rf $stage
git init -q $stage; or exit 1
git -C $stage fetch -q --no-tags --update-head-ok $top '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
or begin
    echo "isolate: copying git history failed." >&2
    exit 1
end
set -l branch (git -C $top symbolic-ref -q --short HEAD)
set -l head (git -C $top rev-parse -q --verify HEAD)
if test -n "$branch"
    git -C $stage symbolic-ref HEAD refs/heads/$branch
else if test -n "$head"
    git -C $stage update-ref --no-deref HEAD $head
end
git -C $top ls-files -z -co --exclude-standard \
    | rsync -a --from0 --files-from=- --ignore-missing-args $top/ $stage/
or exit 1
test -n "$head"; and git -C $stage reset -q

if test -n "$(git -C $top status --porcelain)"
    echo "note: $pname has uncommitted changes. They go into the VM as uncommitted changes too."
end
if test -n "$(git -C $top submodule status 2>/dev/null)"
    echo "note: submodule contents are not copied into the VM."
end

set -l pmb (du -sm --apparent-size $stage | string split -f1 \t)
set -l pimg $pdir/project.ext4
truncate -s (math "ceil($pmb * 1.25) + 2048")M $pimg
mkfs.ext4 -q -F -L project -E root_owner=(id -u):(id -g) -d $stage $pimg; or exit 1
debugfs -w -R 'rmdir /lost+found' $pimg >/dev/null 2>&1   # root-only dir git would trip over
rm -rf $stage

# --- Network: isolate0 TAP, NAT, egress filter (needs sudo when it changes) ------
set -l tap isolate0
set -l use_net 1
test "$ISOLATE_NET" = none; and set use_net 0

if test $use_net = 1
    set -l allow (string split -n ' ' -- "$ISOLATE_ALLOW")
    test -f $pdir/allow; and set -a allow (string match -rv '^\s*(#|$)' <$pdir/allow | string split -n ' ')
    set -l input_rules
    set -l forward_rules
    for a in $allow
        set -l m (string match -rg '^(host|\d+\.\d+\.\d+\.\d+):(\d+)$' -- $a)
        if test (count $m) -ne 2
            echo "isolate: bad ISOLATE_ALLOW entry '$a' (want host:PORT or IP:PORT)" >&2
            exit 1
        end
        if test $m[1] = host
            set -a input_rules "iifname \"$tap\" ip daddr 172.16.0.1 tcp dport $m[2] accept"
        else
            set -a forward_rules "iifname \"$tap\" ip daddr $m[1] tcp dport $m[2] accept"
        end
    end

    # The guest gets the public internet and nothing else: no LAN, no host
    # services, no other VMs/containers, unless listed in ISOLATE_ALLOW.
    set -l ruleset "
destroy table ip fc_agent
destroy table inet isolate
table inet isolate {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname \"$tap\" ct state established,related accept
        $(string join \n'        ' -- $input_rules)
        iifname \"$tap\" drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        oifname \"$tap\" ct state established,related accept
        oifname \"$tap\" drop
        iifname \"$tap\" ip saddr != 172.16.0.2 drop
        iifname \"$tap\" meta nfproto ipv6 drop
        $(string join \n'        ' -- $forward_rules)
        iifname \"$tap\" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 } drop
        iifname \"$tap\" accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 172.16.0.0/30 oifname != \"$tap\" masquerade
    }
}"
    set -l stamp $XDG_RUNTIME_DIR/isolate-net.sha
    set -l want (echo $ruleset | sha256sum | string sub -l 16)
    if not ip link show $tap >/dev/null 2>&1; or test "$(cat $stamp 2>/dev/null)" != $want
        echo "Setting up network $tap with egress filtering (sudo)..."
        sudo ip link del fc-agent0 2>/dev/null
        if not ip link show $tap >/dev/null 2>&1
            sudo ip tuntap add dev $tap mode tap user (id -un)
            and sudo ip addr add 172.16.0.1/30 dev $tap
            and sudo ip link set $tap up
            or exit 1
        end
        sudo sysctl -q -w net.ipv4.ip_forward=1
        echo $ruleset | sudo nft -f -; or exit 1

        # Docker and ufw put DROP policies on the iptables FORWARD chain, which
        # would discard guest traffic our table already accepted.
        if sudo iptables -n -L DOCKER-USER >/dev/null 2>&1
            for r in "-i $tap -j ACCEPT" "-o $tap -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
                set -l rr (string split ' ' -- $r)
                sudo iptables -C DOCKER-USER $rr 2>/dev/null; or sudo iptables -I DOCKER-USER $rr
            end
        else if sudo ufw status 2>/dev/null | string match -q 'Status: active'
            sudo ufw route allow in on $tap >/dev/null
            sudo ufw route allow out on $tap >/dev/null
        end
        if test (count $input_rules) -gt 0; and sudo ufw status 2>/dev/null | string match -q 'Status: active'
            echo "note: ufw is active. If 'host:PORT' entries can't connect, run: sudo ufw allow in on $tap to 172.16.0.1 port PORT proto tcp"
        end
        echo $want >$stamp
    end
end

# --- Launch -----------------------------------------------------------------------
set -l mem 4096
set -q ISOLATE_MEM; and set mem $ISOLATE_MEM
set -l cpus 2
set -q ISOLATE_CPUS; and set cpus $ISOLATE_CPUS
set -l mac 06:00:ac:10:00:02
set -l cmdline "panic=1 root=/dev/vda rw rootfstype=ext4 init=/lib/systemd/systemd systemd.show_status=error"

set -l run
if test -f /etc/apparmor.d/isolate-vm
    set run aa-exec -p isolate-vm --
else
    echo "warning: AppArmor profile 'isolate-vm' isn't installed; the VMM runs unconfined."
    echo "         Install: sudo install -m644 "(path resolve (status dirname)/../../apparmor/isolate-vm)" /etc/apparmor.d/ && sudo apparmor_parser -r /etc/apparmor.d/isolate-vm"
    if test $vmm = qemu; and test -f /etc/apparmor.d/qemu-agent
        # qemu-agent attaches to /usr/bin/qemu-system-x86_64 by path and only
        # allows the old agent-sandbox files, so QEMU can't open these disks.
        echo "isolate: the old 'qemu-agent' AppArmor profile confines every QEMU started without" >&2
        echo "         aa-exec and will block these disks. Install the isolate-vm profile (above) first." >&2
        exit 1
    end
end

if test $vmm = fc
    # Use the real binary, not a mise shim: shims only resolve inside a
    # directory whose mise config pins firecracker, and the AppArmor profile
    # only allows the installed path.
    set -l fc (command -s firecracker)
    if test -z "$fc"; or string match -q '*/mise/shims/*' -- $fc
        set fc (path resolve ~/.local/share/mise/installs/aqua-firecracker-microvm-firecracker/*/*/firecracker | path filter -fx | sort -uV | tail -n1)
    end
    if test -z "$fc"
        echo "isolate: firecracker not found (it's in mise [tools]; try 'mise install')." >&2
        exit 1
    end
    set -l net '[]'
    test $use_net = 1; and set net "[{\"iface_id\": \"eth0\", \"guest_mac\": \"$mac\", \"host_dev_name\": \"$tap\"}]"
    set -l cfg $pdir/vm-config.json
    echo "{
  \"boot-source\": {
    \"kernel_image_path\": \"$vmlinux\",
    \"boot_args\": \"console=ttyS0 reboot=k pci=off $cmdline\"
  },
  \"drives\": [
    {\"drive_id\": \"rootfs\",  \"path_on_host\": \"$rootfs\", \"is_root_device\": false, \"is_read_only\": false},
    {\"drive_id\": \"cache\",   \"path_on_host\": \"$cache\",  \"is_root_device\": false, \"is_read_only\": false},
    {\"drive_id\": \"project\", \"path_on_host\": \"$pimg\",   \"is_root_device\": false, \"is_read_only\": false}
  ],
  \"machine-config\": {\"vcpu_count\": $cpus, \"mem_size_mib\": $mem, \"smt\": false},
  \"network-interfaces\": $net
}" >$cfg
    set -a run $fc --no-api --config-file $cfg
else
    set -a run qemu-system-x86_64 \
        -M microvm,x-option-roms=off,pit=off,pic=off,rtc=off \
        -bios /usr/share/qemu/qboot.rom \
        -enable-kvm -cpu host -m $mem -smp $cpus \
        -kernel $vmlinuz -append "console=hvc0 reboot=t $cmdline" \
        -nodefaults -no-user-config -nographic -no-reboot \
        -device virtio-serial-device -device virtconsole,chardev=con0 \
        -chardev stdio,id=con0,signal=off \
        -drive file=$rootfs,format=raw,if=none,id=vda -device virtio-blk-device,drive=vda \
        -drive file=$cache,format=raw,if=none,id=vdb -device virtio-blk-device,drive=vdb \
        -drive file=$pimg,format=raw,if=none,id=vdc -device virtio-blk-device,drive=vdc
    test $use_net = 1; and set -a run \
        -netdev tap,id=n0,ifname=$tap,script=no,downscript=no \
        -device virtio-net-device,netdev=n0,mac=$mac
end

echo
echo "Booting $pname ($vmm, $cpus vCPU, $mem MiB). Project is at /workspace."
test $use_net = 1; and echo "  ssh:  ssh isolate    (Emacs: /ssh:isolate:/workspace/)"
echo "  Finish with 'isolate-done' in the guest; that saves your work and exits."
echo
# Start the VMM from its state dir so it never touches the project checkout.
pushd $pdir
# Firecracker's raw mode only clears ICANON/ECHO/ISIG, so the host tty still turns
# Enter (CR) into LF, and TUIs in the guest (Claude's menus) never see a Return.
# Pass CR and LF through untranslated, and put the terminal back afterwards.
set -l tty_saved
if isatty stdin
    set tty_saved (stty -g)
    stty -icrnl -inlcr -igncr
end
$run
set -l vm_status $status
test -n "$tty_saved"; and stty $tty_saved
popd
rm -f $rootfs
echo
echo "VM exited ($vm_status)."

# --- Session logs -------------------------------------------------------------------
# Copy agent transcripts and shell history off the cache disk into $pdir/logs, so the
# host keeps a record a later session can't rewrite: a file that changed since the
# last copy has its previous version moved to logs-previous/<stamp>/. Credentials
# are not copied. Runs for every session, exported or not.
set -l logs $pdir/logs
set -l logtmp (mktemp -d $pdir/.logs.XXXXXX)
set -l rdumps
for f in /claude/projects /claude/history.jsonl \
        /home/.codex/sessions /home/.codex/history.jsonl \
        /home/.pi/agent/sessions \
        /home/.local/share/opencode/opencode.db /home/.local/share/opencode/opencode.db-wal \
        /home/.local/share/opencode/storage /home/.local/share/opencode/log \
        /home/.gemini/antigravity/brain /home/.gemini/antigravity/conversations \
        /home/.local/share/fish/fish_history /home/.bash_history
    set -l into $logtmp(path dirname $f)
    mkdir -p $into
    set -a rdumps "rdump $f $into"
end
printf '%s\n' $rdumps | debugfs -f - $cache >/dev/null 2>&1
# Guest-written data: keep only regular files and directories, private to you.
find $logtmp -mindepth 1 ! -type f ! -type d -delete
find $logtmp -mindepth 1 -type d -empty -delete
chmod -R u=rwX,go= $logtmp
if test -n "$(find $logtmp -mindepth 1 -print -quit)"
    rsync -a --checksum --backup --backup-dir=$pdir/logs-previous/(date +%Y%m%d-%H%M%S) $logtmp/ $logs/
    and echo "Session logs: $logs"
end
rm -rf $logtmp

# --- Bring the work back ------------------------------------------------------------
set -l bundle $pdir/out.bundle
rm -f $bundle
debugfs -R "dump /.git/isolate-out.bundle $bundle" $pimg >/dev/null 2>&1
if not test -s $bundle
    rm -f $bundle
    set -l keep $pdir/project-unimported-(date +%Y%m%d-%H%M%S).ext4
    mv $pimg $keep
    echo "isolate: the guest didn't export its work (it exits cleanly only via 'isolate-done' or 'sudo reboot')."
    echo "         The project disk is kept at $keep"
    echo "         Inspect it without mounting: debugfs -R 'ls -l /' $keep"
    exit 1
end

# The fetch below prunes/overwrites refs/remotes/isolate/*. Work from an earlier
# session that no local branch contains is moved aside first, never dropped.
set -l archived
set -l stamp (date +%Y%m%d-%H%M%S)
for ref in (git -C $top for-each-ref --format='%(refname)' refs/remotes/isolate)
    if test -z "$(git -C $top branch --contains $ref --format=x 2>/dev/null)"
        set -l name (string replace refs/remotes/isolate/ '' -- $ref)
        git -C $top update-ref refs/isolate-archive/$stamp/$name $ref
        and set -a archived isolate-archive/$stamp/$name
    end
end
if set -q archived[1]
    echo "Unmerged work from an earlier session was moved aside (not lost):"
    printf '  %s\n' $archived
    echo "  Review: git log -p HEAD..<ref>   Drop: git update-ref -d refs/<ref>"
end

# The bundle is untrusted data: fetch only objects and refs (fully fsck'd), into
# a namespace of their own. Nothing from the guest runs on the host.
git -C $top -c transfer.fsckObjects=true fetch -q --prune --no-write-fetch-head \
    $bundle '+refs/heads/*:refs/remotes/isolate/*'
or begin
    echo "isolate: importing the bundle failed; it is kept at $bundle" >&2
    mv $pimg $pdir/project-unimported-(date +%Y%m%d-%H%M%S).ext4
    exit 1
end
rm -f $pimg $bundle

cd $top
set -l target
if git rev-parse -q --verify refs/remotes/isolate/isolate-wip >/dev/null
    set target isolate/isolate-wip
else if test -n "$branch"; and git rev-parse -q --verify refs/remotes/isolate/$branch >/dev/null
    set target isolate/$branch
end
echo "Guest branches are now in refs/remotes/isolate/* ("(git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/isolate | string join ', ')")."

if test -z "$target"; or test (git rev-list --count HEAD..$target) -eq 0
    echo "No new work on "(test -n "$branch"; and echo $branch; or echo HEAD)"."
    exit 0
end
test $target = isolate/isolate-wip; and echo "($target = the guest's branch plus its uncommitted changes)"
echo
git --no-pager log --oneline --no-decorate HEAD..$target
echo
git --no-pager diff --stat HEAD...$target

# Things worth a hard look before merging: hidden Unicode, and files your host
# tooling executes on its own (CI, task runners, editors, direnv, hooks managers).
set -l bidi (git diff HEAD...$target | LC_ALL=C.UTF-8 grep -cP '[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200B}-\x{200F}]')
test "$bidi" -gt 0 2>/dev/null; and echo \n"WARNING: $bidi changed line(s) contain bidirectional/zero-width Unicode."
set -l risky (git diff --name-only HEAD...$target | string match -re '(?:^|/)(?:\.github/|\.gitlab-ci|\.envrc$|\.?mise[^/]*\.toml$|\.mise/|\.vscode/|\.idea/|\.husky/|\.pre-commit|\.gitattributes$|\.gitmodules$|Makefile$|justfile$|Taskfile|package\.json$|setup\.py$|pyproject\.toml$|conftest\.py$|build\.rs$|\.cargo/|Dockerfile|docker-compose|compose\.ya?ml$)')
if test (count $risky) -gt 0
    echo \n"Review closely, these can run code on your machine:"
    printf '  %s\n' $risky
end

if not isatty stdin
    echo \n"Merge with: git merge $target"
    exit 0
end
while true
    echo
    read -l -P "[d]iff  [m]erge  [s]quash (stage changes, no commit)  [q]uit: " ans
    switch $ans
        case d D
            git diff HEAD...$target
        case m M s S
            # Uncommitted host changes went into the VM too, so the guest's
            # result already contains them; they'd only block the merge here.
            if test -n "$(git status --porcelain)"
                echo "Your working tree has uncommitted changes (the VM's result already includes the ones you had at launch)."
                read -l -P "Stash them first (kept as a backup, see 'git stash list')? [y/N] " st
                string match -qi 'y*' -- $st; or continue
                git stash push -q -u -m "isolate: before merging $target"; or exit 1
            end
            if string match -qi m -- $ans
                git merge --no-edit $target
            else
                git merge --squash $target
            end
            exit $status
        case '*'
            echo "Left as $target. Later: git diff HEAD...$target; git merge $target"
            exit 0
    end
end
