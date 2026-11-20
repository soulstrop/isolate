#!/usr/bin/fish
# End-to-end smoke test: boot a throwaway git repo in a VM and check the round
# trip, driving the console through a pty with isolate-drive.py.
#
#   isolate-test.fish [fc|qemu] [--claude] [--keep]
#
#   --claude   also start Claude Code in the guest: no setup wizard, no trust
#              prompt, and /exit returns to the shell (works offline).
#   --keep     keep the test repo and its isolate state dir even on success.
#
# Checks:
#   guest     Enter arrives as \r (the ICRNL fix), /persist is mounted
#   host      the launcher clears ICRNL on the terminal while the VM runs (its
#             restore can't be checked here: the review prompt's fish `read`
#             clears ICRNL itself while waiting)
#   return    a guest commit comes back as refs/remotes/isolate/main, and
#             uncommitted work as refs/remotes/isolate/isolate-wip
#   logs      the session-logs copy ran (fish history is always there)
#
# Runs with ISOLATE_NET=none, so no sudo is needed unless the host kernel is
# new to isolate (the launcher copies it once with sudo; the test then fails
# fast and tells you to launch once by hand). Only one VM can run at a time.
#
# The test repo is isolate-selftest under $XDG_RUNTIME_DIR, so its state dir
# (~/.local/share/isolate/projects/isolate-selftest-*) never collides with a
# real project. Both are removed on success; on failure they're kept, with the
# console log, for inspection.

argparse h/help claude keep -- $argv
or exit 2
if set -q _flag_help
    sed -n '2,/^$/s/^# \{0,1\}//p' (status filename)
    exit 0
end
set -l vmm fc
test (count $argv) -gt 0; and set vmm $argv[1]
if not contains -- $vmm fc qemu
    echo "usage: isolate-test.fish [fc|qemu] [--claude] [--keep]" >&2
    exit 2
end

set -l here (status dirname)
set -l state $HOME/.local/share/isolate

# --- Preflight -----------------------------------------------------------------
set -l problems
test -f $state/rootfs.ext4; or set -a problems "no guest image: mise run isolate.build"
test -r /dev/kvm -a -w /dev/kvm; or set -a problems "/dev/kvm is not readable and writable by you"
if test -f $state/vm.lock; and not flock -n $state/vm.lock true
    set -a problems "another isolate VM is running"
end
if test (count $problems) -gt 0
    printf 'isolate-test: %s\n' $problems >&2
    exit 1
end

# --- Throwaway repo ------------------------------------------------------------
set -l base /tmp
set -q XDG_RUNTIME_DIR; and test -d $XDG_RUNTIME_DIR; and set base $XDG_RUNTIME_DIR
set -l work (mktemp -d $base/isolate-test.XXXXXX); or exit 1
set -l repo (path resolve $work)/isolate-selftest
mkdir $repo
git -C $repo init -q -b main
and git -C $repo -c user.name=isolate-test -c user.email=isolate-test@invalid commit -q --allow-empty -m 'isolate-test: start'
or exit 1
set -l pdir $state/projects/isolate-selftest-(echo -n $repo | sha256sum | string sub -l 8)
set -l log $work/console.log

# --- Steps for the driver -----------------------------------------------------
# Markers are typed as o"k" so the echoed command line can't match the output.
set -l steps "
wait isolate: project is in /workspace 240
settle 2
termios icrnl off

mark Enter key reaches the guest as \\r
reject ENTER=b'\\\\n'
send python3 -c 'import os,tty; tty.setraw(0); b=os.read(0,8); tty.setcbreak(0); print(\"ENTER=\"+repr(b))'
settle 2
key enter
wait ENTER=b'\\\\r' 20

mark /persist is mounted
send mountpoint -q /persist; and echo PERSIST=o\"k\"; or echo PERSIST=b\"ad\"
wait PERSIST=(ok|bad) 20
reject PERSIST=bad

mark guest commit plus uncommitted work
send echo from-guest >guest.txt; and git add guest.txt; and git commit -qm 'isolate-test: guest commit'; and echo wip >wip.txt; and echo COMMIT=o\"k\"
wait COMMIT=ok 30
"
if set -q _flag_claude
    set steps "$steps
mark Claude starts without setup wizard or trust prompt
reject (?i)text style that looks best|let's get started|trust the files in this folder|choose .{0,20}theme
send claude
wait (?i)/login|for shortcuts|auto mode 120
settle 3
type /exit
settle 1
key enter
# Claude takes a few seconds to quit; anything typed before the shell prompt is
# back goes to Claude and is lost. Wait for starship's prompt line.
wait workspace on .{0,4}main 60
settle 1
send echo BACK=o\"k\"
wait BACK=ok 60
"
end
set steps "$steps
mark save and shut down
send isolate-done
wait \\[d\\]iff 300
"

# --- Run -----------------------------------------------------------------------
echo "isolate-test: booting $repo with $vmm (log: $log)"
set -e MISE_ORIGINAL_CWD # the launcher cd's there; it must use the test repo
set -e ISOLATE_ALLOW
set -l t0 (date +%s)
echo $steps | begin
    cd $repo
    and env ISOLATE_NET=none ISOLATE_CACHE_SIZE=4G python3 -I $here/isolate-drive.py --log $log $vmm
end
set -l drive_status $status
set -l secs (math (date +%s) - $t0)

# --- Host-side checks ------------------------------------------------------------
set -l fails
test $drive_status -eq 0; or set -a fails "driver/launcher exited with $drive_status (see the end of the log)"
set -l subj (git -C $repo log -1 --format=%s refs/remotes/isolate/main 2>/dev/null)
test "$subj" = 'isolate-test: guest commit'; or set -a fails "refs/remotes/isolate/main is not the guest commit (got: '$subj')"
git -C $repo cat-file -e refs/remotes/isolate/isolate-wip:wip.txt 2>/dev/null
or set -a fails "refs/remotes/isolate/isolate-wip doesn't contain wip.txt"
grep -aq 'Session logs:' $log; and test -f $pdir/logs/home/.local/share/fish/fish_history
or set -a fails "session logs weren't copied to $pdir/logs"

if test (count $fails) -eq 0
    echo "isolate-test: PASS ($vmm, $secs s)"
    if not set -q _flag_keep
        rm -rf $work $pdir
    else
        echo "kept: $repo, $pdir"
    end
    exit 0
end
echo "isolate-test: FAIL ($vmm, $secs s)" >&2
printf '  - %s\n' $fails >&2
echo "kept for inspection: $log, $repo, $pdir (delete both dirs when done)" >&2
exit 1
