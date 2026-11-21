#!/usr/bin/env python3
"""Drive an isolate launch through a pseudo-terminal, for automated tests.

usage: isolate-drive.py [options] fc|qemu  <steps

Runs `fish isolate-vm.fish fc|qemu` from the current directory (which must be
inside a git repo) on a pty sized --rows x --cols, the way a person at a
terminal would, and plays a step script read from stdin, one step per line:

  wait REGEX [SECS]   wait until REGEX (Python re, matched on the output with
                      escape sequences stripped) appears after the last
                      `wait` match. Default timeout 120s.
  send TEXT           type TEXT and press Enter (sent as \\r, like a terminal).
  type TEXT           type TEXT without Enter. Escapes such as \\x1b work.
  key NAME            press enter, esc, tab, up, down, ctrl-c, ctrl-d or
                      ctrl-l.
  settle [SECS]       wait until output has been quiet for SECS (default 2).
  reject REGEX        from here on, fail if REGEX ever appears in the output.
  termios FLAG on|off check a local-mode/input flag of the pty (e.g. icrnl)
                      as the launcher has set it right now.
  mark TEXT           write a ==== TEXT ==== line into the log.
  # ...               comment; blank lines are ignored.

Before any step, the driver fails if the launcher asks for a sudo password
(tests should run where that isn't needed, e.g. ISOLATE_NET=none) or prints
an "isolate:" error it can't recover from. After the last step it waits for
the launcher to exit (answering its review prompt with --answer, default q)
and exits with the launcher's status, or 1 if a step failed, 2 on timeout.

The full raw output goes to --log (default isolate-drive.log).
"""

import argparse
import codecs
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
ANSI = re.compile(rb"\x1b\[[0-9;?<>=!]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>78NOM]|\r")
KEYS = {"enter": b"\r", "esc": b"\x1b", "tab": b"\t", "up": b"\x1b[A",
        "down": b"\x1b[B", "ctrl-c": b"\x03", "ctrl-d": b"\x04", "ctrl-l": b"\x0c"}
ALWAYS_FATAL = [
    (re.compile(r"\[sudo\] password for"), "the launcher asked for a sudo password (new host kernel? launch once by hand with mise run isolate.fc, then rerun)"),
    (re.compile(r"isolate: (no guest image yet|another isolate VM is already running|.* is not inside a git repository)"),
     "the launcher refused to start"),
]


# fish asks the terminal for its attributes (DA1) and waits up to 2 s for the
# answer. Keys typed in that wait can get lost. A pty has no terminal to
# answer, so the driver answers each query like a VT220 would.
DA1 = re.compile(rb"\x1b\[0?c")
DA1_REPLY = b"\x1b[?62;22c"


class StepFailed(Exception):
    pass


class Session:
    def __init__(self, argv, log_path, rows, cols, verbose):
        self.log = open(log_path, "wb")
        self.raw = b""
        self.text = ""          # output with escape sequences stripped
        self.pos = 0            # `wait` searches from here
        self.answered = 0       # DA1 queries answered so far
        self.rejects = []
        self.verbose = verbose
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.setdefault("TERM", "xterm-256color")
            try:
                os.execvp(argv[0], argv)
            finally:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.alive = True
        self.status = None

    def note(self, msg):
        self.log.write(f"\n==== {msg} ====\n".encode())
        self.log.flush()
        if self.verbose:
            print(f"isolate-drive: {msg}", file=sys.stderr)

    def pump(self, timeout):
        """Read whatever arrives within timeout. Returns True if anything did."""
        if not self.alive:
            time.sleep(min(timeout, 0.2))
            return False
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            self.alive = False
            return False
        self.raw += data
        self.log.write(data)
        self.log.flush()
        asked = len(DA1.findall(self.raw))
        if asked > self.answered:
            os.write(self.fd, DA1_REPLY * (asked - self.answered))
            self.answered = asked
        # Strip escapes on the whole tail so sequences split across reads match.
        self.text = ANSI.sub(b"", self.raw).decode("utf-8", "replace")
        self.check_fatal()
        return True

    def check_fatal(self):
        for pat, why, start in [(p, w, 0) for p, w in ALWAYS_FATAL] + self.rejects:
            if pat.search(self.text, start):
                raise StepFailed(f"{why} (matched {pat.pattern!r})")

    def write(self, data):
        if not self.alive:
            raise StepFailed("the launcher exited before the step could be sent")
        os.write(self.fd, data)

    def wait(self, pattern, secs):
        pat = re.compile(pattern)
        deadline = time.time() + secs
        while True:
            m = pat.search(self.text, self.pos)
            if m:
                self.pos = m.end()
                return
            if time.time() > deadline:
                raise TimeoutError(f"no {pattern!r} within {secs:g}s")
            if not self.alive and not self.pump(0):
                raise StepFailed(f"the launcher exited before {pattern!r} appeared")
            self.pump(0.5)

    def settle(self, quiet, cap=300):
        end = time.time() + cap
        last = time.time()
        while time.time() < end and time.time() - last < quiet:
            if self.pump(0.25):
                last = time.time()

    def termios_flag(self, name, want):
        flag = getattr(termios, name.upper(), None)
        if flag is None:
            raise StepFailed(f"unknown termios flag {name}")
        iflag, _, _, lflag, _, _, _ = termios.tcgetattr(self.fd)
        word = iflag if name.lower() in ("icrnl", "inlcr", "igncr", "ixon", "istrip") else lflag
        have = bool(word & flag)
        if have != want:
            raise StepFailed(f"termios {name} is {'on' if have else 'off'}, expected {'on' if want else 'off'}")

    def finish(self, answer, secs):
        """Answer the review prompt (if it comes) and wait for the launcher to exit."""
        deadline = time.time() + secs
        answered = False
        while self.alive:
            if time.time() > deadline:
                raise TimeoutError(f"the launcher didn't exit within {secs:g}s")
            if not answered and re.search(r"\[d\]iff .*\[q\]uit: ", self.text):
                self.note(f"answering review prompt with {answer!r}")
                self.write(answer.encode() + b"\r")
                answered = True
            self.pump(0.5)
        _, st = os.waitpid(self.pid, 0)
        self.status = os.waitstatus_to_exitcode(st)
        return self.status

    def kill(self):
        if self.status is None:
            try:
                os.killpg(self.pid, signal.SIGTERM)  # the launcher and its VMM
                time.sleep(2)
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run_steps(s, steps):
    for lineno, line in enumerate(steps, 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cmd, _, arg = line.strip().partition(" ")
        s.note(f"step {lineno}: {line.strip()}")
        if cmd == "wait":
            parts = arg.rsplit(" ", 1)
            if len(parts) == 2 and re.fullmatch(r"\d+(\.\d+)?", parts[1]):
                s.wait(parts[0], float(parts[1]))
            else:
                s.wait(arg, 120)
        elif cmd == "send":
            s.write(arg.encode() + b"\r")
        elif cmd == "type":
            s.write(codecs.decode(arg, "unicode_escape").encode("latin-1"))
        elif cmd == "key":
            if arg not in KEYS:
                raise StepFailed(f"line {lineno}: unknown key {arg!r}")
            s.write(KEYS[arg])
        elif cmd == "settle":
            s.settle(float(arg) if arg else 2)
        elif cmd == "reject":
            s.rejects.append((re.compile(arg), "rejected output appeared", len(s.text)))
        elif cmd == "termios":
            name, _, state = arg.partition(" ")
            s.termios_flag(name, state.strip() == "on")
        elif cmd == "mark":
            pass  # note() above already wrote it
        else:
            raise StepFailed(f"line {lineno}: unknown step {cmd!r}")


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("vmm", choices=["fc", "qemu"])
    ap.add_argument("--log", default="isolate-drive.log")
    ap.add_argument("--answer", default="q", help="reply to the review prompt (default q)")
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--exit-timeout", type=float, default=300,
                    help="seconds to wait for the launcher to exit after the last step")
    ap.add_argument("-v", "--verbose", action="store_true", help="print each step to stderr")
    a = ap.parse_args()

    steps = sys.stdin.readlines() if not sys.stdin.isatty() else []
    s = Session(["fish", os.path.join(HERE, "isolate-vm.fish"), a.vmm],
                a.log, a.rows, a.cols, a.verbose)
    try:
        run_steps(s, steps)
        status = s.finish(a.answer, a.exit_timeout)
        s.note(f"launcher exited with status {status}")
        return status
    except (StepFailed, TimeoutError) as e:
        s.note(f"FAILED: {e}")
        print(f"isolate-drive: {e} (log: {a.log})", file=sys.stderr)
        s.kill()
        return 2 if isinstance(e, TimeoutError) else 1
    except KeyboardInterrupt:
        s.kill()
        return 130


if __name__ == "__main__":
    sys.exit(main())
