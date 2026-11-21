#!/usr/bin/env python3
"""Play the README demo in a clean host shell, for asciinema to record.

usage: isolate-demo.py [--rows N] [--cols N] [--typing SECS] STEPS_FILE
       isolate-demo.py --split CAST OUTDIR

Starts `fish --private --no-config` on a pty with a neutral prompt and no
history, so nothing personal shows on screen. Then it plays the steps of
isolate-drive.py, with these changes:

  send TEXT     types TEXT one key at a time, like a person, then Enter.
  pause SECS    waits SECS while the output stays on screen.
  cut NAME      starts the piece NAME of the demo. Output after it goes to
                NAME.cast when you split. The name `-` drops the output up to
                the next cut. Follow a cut with `key ctrl-l` where fish reads
                keys, so that the piece starts with a prompt.

All output goes to stdout, so asciinema records it. At the end it waits for
the shell to exit. isolate-demo.fish runs this; see that file for the steps.

--split cuts a recorded cast at the cut marks into OUTDIR/NAME.cast, one per
piece, and prints the names in order. Each piece starts on a blank screen.
"""

import argparse
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("drive", os.path.join(HERE, "isolate-drive.py"))
assert spec and spec.loader
drive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drive)

PROMPT = r"""
set -g fish_greeting
set -g fish_autosuggestion_enabled 0
function fish_prompt; set_color --bold green; printf '~/demo'; set_color normal; printf ' $ '; end
function fish_title; echo demo; end
"""

# An OSC sequence that terminals ignore. --split looks for it in the cast.
CUT = "\x1b]5379;isolate-demo-cut={}\x07"
CUT_PREFIX, CUT_END = CUT.split("{}")


class Demo(drive.Session):
    typing = 0.045

    def __init__(self, argv, rows, cols):
        super().__init__(argv, os.devnull, rows, cols, verbose=False)
        self.log = sys.stdout.buffer   # pump() mirrors all output here

    def note(self, msg):
        pass                           # no ==== markers in the recording

    def write(self, data):
        if data.endswith(b"\r") and len(data) > 1:
            for ch in data[:-1]:       # type it, and let the echo show
                super().write(bytes([ch]))
                self.pump(self.typing)
            time.sleep(0.3)
            self.pump(0)
            data = b"\r"
        super().write(data)

    def pause(self, secs):
        end = time.time() + secs
        while time.time() < end:
            self.pump(max(0.0, min(0.25, end - time.time())))

    def cut(self, name):
        self.pump(0)                   # flush what arrived before the cut
        self.log.write(CUT.format(name).encode())
        self.log.flush()


def split(cast, outdir):
    """Cut CAST at the cut marks. Returns the names of the pieces in order."""
    with open(cast) as f:
        header, *events = [json.loads(line) for line in f if line.strip()]
    v3 = header.get("version") == 3    # v3 times are intervals, v2 absolute
    pieces = []                        # [name, [(abs_time, data), ...]]
    t = 0.0
    for e in events:
        t = t + e[0] if v3 else e[0]
        if e[1] != "o":
            continue
        rest = e[2]
        while CUT_PREFIX in rest:
            before, _, after = rest.partition(CUT_PREFIX)
            name, _, rest = after.partition(CUT_END)
            if before and pieces:
                pieces[-1][1].append((t, before))
            pieces.append([name, []])
        if rest and pieces:
            pieces[-1][1].append((t, rest))

    os.makedirs(outdir, exist_ok=True)
    names = []
    for name, out in pieces:
        if name == "-" or not out:
            continue
        start = out[0][0]
        with open(os.path.join(outdir, name + ".cast"), "w") as f:
            f.write(json.dumps(header) + "\n")
            prev = start
            for at, data in out:
                stamp = at - prev if v3 else at - start
                f.write(json.dumps([round(stamp, 6), "o", data]) + "\n")
                prev = at
        names.append(name)
    return names


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("steps", nargs="?", help="step file (stdin is the terminal under asciinema)")
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--typing", type=float, default=Demo.typing, help="seconds per key")
    ap.add_argument("--split", nargs=2, metavar=("CAST", "OUTDIR"), help="cut a cast into pieces")
    a = ap.parse_args()
    if a.split:
        print("\n".join(split(*a.split)))
        return 0
    if not a.steps:
        ap.error("give a steps file, or --split")
    Demo.typing = a.typing

    with open(a.steps) as f:
        steps = f.readlines()
    s = Demo(["fish", "--private", "--no-config", "-C", PROMPT], a.rows, a.cols)
    try:
        s.settle(1)
        for line in steps:
            cmd, _, arg = line.strip().partition(" ")
            if cmd == "pause":
                s.pause(float(arg or 2))
            elif cmd == "cut":
                s.cut(arg)
            else:
                drive.run_steps(s, [line])
        while s.alive:                 # the steps end with `send exit`
            s.pump(0.5)
        os.waitpid(s.pid, 0)
        return 0
    except (drive.StepFailed, TimeoutError) as e:
        print(f"\r\nisolate-demo: {e}", file=sys.stderr)
        s.kill()
        return 1
    except KeyboardInterrupt:
        s.kill()
        return 130


if __name__ == "__main__":
    sys.exit(main())
