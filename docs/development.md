# isolate: development

How to build, test and debug changes to isolate itself. For the rules for
coding agents, see [AGENTS.md](../AGENTS.md). For how the
parts work, see [architecture.md](architecture.md).

## Where things are

| Path | What |
| ---- | ---- |
| `mise/config.toml` | Tasks `isolate.fc`, `isolate.qemu`, `isolate.build`, `isolate.check` and `isolate.test`, and the host tools of this repo. |
| `mise/scripts/isolate-vm.fish` | The launcher: disks, kernel copy, network (TAP and nftables), AppArmor, VMM start, bundle import, review prompt, session logs. Its header comment lists its environment variables. |
| `mise/scripts/isolate-build.fish` | Image build: podman build, dotfiles allowlist, Claude seed, GitHub token as a build secret with a leak check, `rootfs.ext4`, pinned `known_hosts`. |
| `image/Containerfile` | Guest image. The order of the layers is important for the cache: apt, then mise tools with `TOOLS_STAMP`, then dotfiles. |
| `image/mise/config.toml` | The tools in each guest (agents, orientation tools, usage, tmux, starship and others). |
| `image/claude/` | The Claude settings and the plugin list that each new project gets as a seed. |
| `image/rootfs/` | Files that the build copies into the guest without change: systemd units, `/etc/isolate/env`, `isolate-prepare`, `isolate-export`, `isolate-done`. |
| `apparmor/isolate-vm` | The AppArmor profile that confines the VMM. The user installs it. It uses `@{ISOLATE}=@{HOME}/.local/share/isolate`. |
| `mise/scripts/isolate-check.fish` | The static checks of `isolate.check` (see [Tests](#tests)). It never opens `github_tokens.toml`. |
| `mise/scripts/isolate-test.fish` | The end-to-end test of `isolate.test`: throwaway repo, step script, host-side checks of the refs and the logs. |
| `mise/scripts/isolate-drive.py` | A pty driver that plays a step script against a launch. Its docstring gives the step language. |
| `mise/scripts/build-docs` | Renders the markdown to `README.html` and PDF with Lua filters. |
| `test-proj/` | Optional, git ignores it. Put a small git repo of your own here to use for launches. `isolate.test` makes its own throwaway repo. |
| `~/.local/share/isolate/` | Host state: `rootfs.ext4`, `kernel/`, `known_hosts`, `vm.lock`, `projects/<name>-<sha8>/` (`cache.ext4`, `allow`, `logs/` and others). |

## Build the image

The build takes several minutes. podman keeps the apt layer in its cache,
and the build installs the mise tools again each day.

```sh
cd ~/projects/isolate && mise run isolate.build
```

## Launch interactively

```sh
cd ~/projects/isolate/test-proj && mise run isolate.fc   # or isolate.qemu
```

The launcher can ask for sudo one time for each host kernel version (the
kernel copy). It also asks each time that the nftables ruleset changes.
`ISOLATE_NET=none` removes the network and the sudo prompt for it. This
option is enough for most tests. Only one VM can run at a time
(`vm.lock`).

## Tests

Run these commands from the root of the repo after each change:

```sh
mise run isolate.check                    # a few seconds, no VM
mise run isolate.test                     # check, then a Firecracker round trip (~75 s)
mise run isolate.test -- qemu --claude    # QEMU, and also start and /exit Claude Code
```

`isolate.check` does these checks. It reports a check whose tool is missing
as skipped, not as failed.

| Check | What it does |
| ----- | ------------ |
| `fish` | Each fish script parses (`fish --no-execute`). |
| `shellcheck` | The guest and helper shell scripts pass `shellcheck` at warning level and higher. |
| `python` | The Python scripts parse. |
| `json` | The JSON files parse (`jq`). |
| `toml` | The TOML files parse (Python `tomllib`). It skips `github_tokens.toml`. |
| `apparmor` | `apparmor/isolate-vm` compiles (`apparmor_parser`, without a load). |
| `rootfs` | The `chmod` line in the Containerfile makes each command in `image/rootfs/usr/local/bin` executable. |
| `ste` | The markdown files follow ASD-STE100 (`ste-lint` from `npm:agent-ste`). A hard violation fails the check. The check counts the soft violations only. |

To see the full `ste-lint` report, soft violations included:

```sh
ste-lint README.md AGENTS.md docs/*.md docs/roadmap/*.md
```

`isolate.test` needs the guest image and `/dev/kvm`. It boots a throwaway
repo `isolate-selftest` under `$XDG_RUNTIME_DIR` with `ISOLATE_NET=none`, so
it needs no sudo. It checks these items:

- Enter gets to the guest as `\r`.
- The guest mounts `/persist`.
- A guest commit comes back as `isolate/main`.
- Uncommitted work comes back as `isolate/isolate-wip`.
- The launcher copies the session logs.

After a pass, the test deletes the repo and its state directory. After a
failure, it keeps them and prints the path of the console log. The log marks
each step with `==== step N: … ====`. To remove the escape sequences before
you read the log, use the `ANSI` regex in `isolate-drive.py`. `--keep` keeps
the files after a pass too.

## Update the host tools

`mise/config.toml` pins the host tools (Firecracker, firectl, podman, qdns,
agent-ste and shellcheck) to the versions that the tests passed with. To update a tool,
do these steps:

1. Change its version in `mise/config.toml`.
2. Run `mise install`.
3. Run `mise run isolate.test` and `mise run isolate.test qemu`.
4. Commit the new version only after both tests pass.

## Drive other launches

For a launch that the test does not cover, write a step script for
`isolate-drive.py`. Do not write a new pty script. The docstring gives the
steps: `wait`, `send`, `type`, `key`, `settle`, `reject`, `termios` and
`mark`. The driver already handles the problems that earlier scripts had:

- It sends Enter as `\r`.
- It types only after `isolate: project is in /workspace` appears. The
  guest loses keys that you send during boot.
- It stops immediately at a sudo prompt.
- It answers the `[d]iff` review prompt.

Type markers as `o"k"`, so that the echo of the command line cannot match
the `wait` pattern.

In the TUI of Claude, use `/exit` to stop it. Two Ctrl-C keys do not always
stop it. Claude takes several seconds to stop, and Claude gets anything that
you type in that time. So, wait for the shell prompt (`workspace on …
main`) before you send the next command.

## Inspect disks without a boot

Use `debugfs -R 'ls -l /path' image.ext4`, `debugfs -R 'cat /path'
image.ext4`, or `rdump` to copy a tree out. These commands work on
`rootfs.ext4` and on the `cache.ext4` of each project. Use them on
`cache.ext4` only when no VM runs.

## Clean up after a test VM that you stopped

An interrupted launch keeps `project-unimported-<stamp>.ext4` in the state
directory of the project. For throwaway test repos, delete the full
`~/.local/share/isolate/projects/<name>-<sha8>/` directory. Do not delete
the directories of real projects. Their `cache.ext4` holds agent logins and
history.

## Traps that we found

- **The Firecracker console makes the terminal only partially raw.** It
  clears ICANON, ECHO and ISIG, but it keeps ICRNL. So Enter arrived as
  `\n`, and Ink TUIs ignored it. The `-chardev stdio` of QEMU does not have
  this problem. Do not remove the `stty` wrapper in `isolate-vm.fish`.
- **`isolate-prepare` copies the seed files only in the first session of a
  project.** A change to `image/claude/*` does not get to existing projects.
  The exception is `.claude.json`, which `isolate-prepare` merges. The same
  applies to the state that `/persist/home` holds through symlinks.
- **Do not check the termios of the host at the review prompt.** The fish
  `read` command clears ICRNL while it waits. So the flag is off there,
  although the launcher restored it. The test checks only that ICRNL is off
  while the VM runs.
- **The `shellcheck` and `jq` commands on the host are mise shims.** They
  fail when mise cannot load its configuration (untrusted or broken), and
  this hides the real error. For this reason, `isolate-check.fish` uses
  `/usr/bin/python3`.
- **mise configuration tests:** `MISE_GLOBAL_CONFIG_FILE=/dev/null` fails.
  Point it at an empty `.toml` file.
- **`MISE_SHARED_INSTALL_DIRS`** (read-only extra install directories, shown
  as `(shared)`) works on the host with mise 2026.10.19. We tested it. The
  guest uses the same mise binary as the host.
- **The guest boots the kernel of the host.** Firecracker needs it
  uncompressed (`extract-vmlinux` extracts it). The launcher keeps only the
  current version and deletes old copies.
- **`/workspace` gets tracked and untracked files, but not ignored files**
  (`.env` stays on the host) and no submodules. This is the correct
  behavior, not a bug.
- **When you open `host:11434`** for lumen, the guest gets the full Ollama
  API, model create, delete, pull and push included. The docs tell this, and
  the roadmap has an item to fix it.
