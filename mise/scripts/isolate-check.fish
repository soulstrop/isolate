#!/usr/bin/fish
# Static checks for this repo: no VM, no sudo, no network, a few seconds.
#
#   fish      every fish script parses (fish --no-execute)
#   sh        guest and helper shell scripts pass shellcheck (warnings and up)
#   python    Python scripts parse
#   json      JSON files parse (jq)
#   toml      TOML files parse (Python tomllib); github_tokens.toml is skipped
#   apparmor  apparmor/isolate-vm compiles (apparmor_parser, without loading)
#   rootfs    every guest command in image/rootfs/usr/local/bin is made
#             executable by the Containerfile's chmod line
#   ste       markdown docs follow ASD-STE100 (ste-lint, from npm:agent-ste):
#             hard violations fail, soft ones are only counted
#
# A check whose tool is missing is reported as skipped, not failed.

set -l root (path resolve (status dirname)/../..)
cd $root; or exit 1
set -l failed
set -l skipped
# Prefer the system python: a mise shim fails when mise/config.toml is broken,
# which would hide the real error behind mise's.
set -l py python3
test -x /usr/bin/python3; and set py /usr/bin/python3

function _check_result -a name ok detail
    if test $ok -eq 0
        echo "  ok    $name"
    else
        echo "  FAIL  $name"
        test -n "$detail"; and printf '%s\n' $detail | sed 's/^/        /'
    end
    return $ok
end

echo "isolate-check: $root"

# fish
set -l out
for f in mise/scripts/*.fish image/home/config.fish image/rootfs/etc/fish/conf.d/*.fish
    set -a out (fish --no-execute $f 2>&1)
end
_check_result fish (test (count $out) -eq 0; echo $status) "$out"; or set -a failed fish

# sh: guest scripts are POSIX sh. profile.d is sourced, so `cd || exit` (SC2164)
# would be wrong there.
if command -q shellcheck
    set -l sh_files image/rootfs/usr/local/bin/*
    for f in mise/scripts/*
        test -f $f; and string match -qr '^#!.*\b(ba)?sh\b' -- (head -n1 $f); and set -a sh_files $f
    end
    set out (shellcheck -S warning $sh_files 2>&1; shellcheck -S warning -s sh -e SC2164 image/rootfs/etc/profile.d/*.sh 2>&1)
    _check_result shellcheck (test -z "$out"; echo $status) "$out"; or set -a failed shellcheck
else
    set -a skipped shellcheck
end

# python
set -l py_files
for f in mise/scripts/*
    test -f $f; and string match -qr '\.py$|^#!.*python' -- $f (head -n1 $f); and set -a py_files $f
end
set out ($py -I -c '
import ast, sys
for f in sys.argv[1:]:
    try:
        ast.parse(open(f, encoding="utf-8").read(), f)
    except SyntaxError as e:
        print(f"{f}:{e.lineno}: {e.msg}")
' $py_files 2>&1)
_check_result python (test -z "$out"; echo $status) "$out"; or set -a failed python

# json
set -l json_files (find image mise apparmor -name '*.json' -type f)
set out
for f in $json_files
    test -f $f; or continue
    set -l err (jq empty $f 2>&1); or set -a out "$f: $err"
end
_check_result json (test -z "$out"; echo $status) "$out"; or set -a failed json

# toml (never open github_tokens.toml: it holds a secret)
set -l toml_files (find . -path ./test-proj -prune -o -path ./tuple-test -prune -o -name '*.toml' ! -name 'github_tokens.toml' -type f -print)
set out ($py -I -c '
import sys, tomllib
for f in sys.argv[1:]:
    try:
        tomllib.load(open(f, "rb"))
    except Exception as e:
        print(f"{f}: {e}")
' $toml_files 2>&1)
_check_result toml (test -z "$out"; echo $status) "$out"; or set -a failed toml

# apparmor
if test -x /usr/sbin/apparmor_parser; or command -q apparmor_parser
    set -l parser apparmor_parser
    command -q apparmor_parser; or set parser /usr/sbin/apparmor_parser
    set out ($parser -Q -K -T apparmor/isolate-vm 2>&1)
    set -l st $status
    _check_result apparmor $st "$out"; or set -a failed apparmor
else
    set -a skipped apparmor
end

# rootfs executables: COPY keeps the repo's modes, but the Containerfile sets
# them explicitly, so a new command must be added to its chmod line.
set out
set -l chmods (string match -r 'chmod 0755 [^\\&]*' <image/Containerfile)
for f in image/rootfs/usr/local/bin/*
    set -l g /usr/local/bin/(path basename $f)
    string match -q -- "* $g *" " $chmods "; or set -a out "$g is not in image/Containerfile's chmod 0755 line"
end
_check_result rootfs (test -z "$out"; echo $status) "$out"; or set -a failed rootfs

# ste: the repo's own markdown (tracked or untracked, not ignored, so test-proj
# and generated files are left out). Exit 1 = hard violations, 2 = no config or
# engine. A line that is right can be silenced with
# <!-- ste-disable-next-line <rule> --> (see AGENTS.md).
if command -q ste-lint
    set -l md_files (git ls-files --cached --others --exclude-standard -- '*.md' 2>/dev/null)
    test (count $md_files) -gt 0; or set md_files (find . -path ./.git -prune -o -path ./test-proj -prune -o -path ./tuple-test -prune -o -name '*.md' -type f -print)
    set out (ste-lint $md_files 2>&1)
    set -l st $status
    set -l summary (string match -r -- '^\d+ hard, \d+ soft.*' $out)
    set -l detail (string match -r -- '.*: error .*' $out) $summary
    test $st -eq 2; and set detail $out
    set -l name ste
    test $st -eq 0 -a -n "$summary"; and set name "ste ($summary)"
    _check_result $name $st "$detail"; or set -a failed ste
else
    set -a skipped ste
end

test (count $skipped) -gt 0; and echo "  skip  $skipped (tool not installed)"
if test (count $failed) -gt 0
    echo "isolate-check: FAIL ($failed)"
    exit 1
end
echo "isolate-check: PASS"
