# isolate: troubleshooting

The tables below group the symptoms by the phase where they show up. When
no row matches, see [Narrowing it down](#narrowing-it-down). Paths are
relative to `~/.local/share/isolate/` unless they start with `/` or `~`.
`<p>` is the state directory of the project, `projects/<name>-<sha8>/`. For
how the parts work together, see [architecture.md](architecture.md). For
development traps, see [development.md](development.md#traps-that-we-found).

## Which phase failed?

Each message starts with a prefix that identifies the script that printed it:

| Prefix or output | Phase | Section |
|---|---|---|
| `isolate.build: ...`, podman output | building the image | [Build](#build) |
| `isolate: ...` before `Booting <project>` | launcher setup on the host | [Launch](#launch) |
| nothing after `Booting`, or the VM stops in a few seconds | kernel / systemd boot | [Boot and console](#boot-and-console) |
| a fish prompt, but something in it does not work correctly | inside the guest | [Network](#network), [Inside the guest](#inside-the-guest), [Claude Code and plugins](#claude-code-and-plugins) |
| text after `VM exited (N).` | importing the work | [Getting the work back](#getting-the-work-back) |

## Build

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `no public key at ...` | No `~/.ssh/id_ed25519.pub` | Set `ISOLATE_SSH_PUBKEY` to a different `.pub` file. |
| `no mise binary found` | mise is not on `PATH` for the build | Set `ISOLATE_MISE=/path/to/mise`. |
| `ISOLATE_DOTFILES=... is not a directory` | The path in `ISOLATE_DOTFILES` does not exist | Correct the path, or unset the variable to build without dotfiles. |
| `no dotfiles package .../<pkg>, skipping` | That package is not in `ISOLATE_DOTFILES` | Harmless. To stop the message, change `ISOLATE_DOTFILE_PKGS`. |
| `no GitHub token from mise; installing anonymously` | `mise token github` gave nothing on the host | This is satisfactory for occasional builds. If the `mise install` step then fails with HTTP 403 or rate-limit errors, configure a token for mise on the host. |
| `podman build failed` | A Containerfile step failed | Scroll up to the `STEP` that failed. Run the build again. podman keeps the earlier layers in its cache, so the build gets to the failure quickly. |
| apt step fails | Mirror problems, or a package name that you added does not exist in 26.04 | `podman run --rm docker.io/library/ubuntu:26.04 sh -c 'apt-get update && apt-cache policy <pkg>'` |
| `mise install` step fails on one tool | The upstream release has no assets, or a backend needs something that the image does not have | The log names the tool. `mise registry <name>` on the host shows the backend. Pin a version or change the backend in `image/mise/config.toml`. |
| `claude plugin marketplace add` / `install` fails | GitHub is not available, a typo in `image/claude/plugins`, or upstream renamed the plugin | Compare the `<source> <plugin@marketplace>` of the line with the repo of the marketplace. To build without the plugin, make the line a comment. |
| `context-mode needs node >= 22.5` | The apt `nodejs` is too old for `node:sqlite` | Add `node = "22"` (or newer) to `image/mise/config.toml`, or remove context-mode from `image/claude/plugins`. |
| lumen prints a usage error during the build | Its launcher ran with `--help` only to download the binary | Harmless. The step ignores the exit code. |
| `GitHub token found in the image, refusing to continue` | Something wrote the token into a layer | The message lists the files. Usually a tool keeps credentials under `~`. Add an `rm` for that path to the step that makes it. Never go around this check. |
| `making the ext4 filesystem failed` | The disk is full, or `mkfs.ext4` is too old for `-d` | `df -h ~/.local/share`. You need e2fsprogs 1.43 or newer. |
| `ownership looks wrong (sudo uid=..., home uid=...)` | The uid mapping of rootless podman is incorrect | Make sure that your user has ranges in `/etc/subuid` and `/etc/subgid`. Then run `podman system migrate`. |
| `could not read the guest ssh host key` | The build wrote the ext4 file, but the file is not complete | This usually occurs after the disk becomes full. Make free space and build again. |
| The build has no more disk space | The podman storage and `tmp/` become larger with each build | `podman image prune`, `podman system df`. You can empty `tmp/` safely when no build runs. |
| A tool is older than expected | `latest` resolved earlier today, and the build used the layer again | `ISOLATE_REFRESH=1 mise run isolate.build` |

## Launch

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `mise run isolate.fc` says no such task | You are outside this repo, and the tasks are not in the global mise config | Add them to `~/.config/mise/config.toml` (see the README). |
| `... is not inside a git repository` | You started the launch from a directory that is not a repo | First `cd` into the repo. The launcher uses the current directory. |
| `no guest image yet` | `rootfs.ext4` is missing | `mise run isolate.build` |
| `mise run isolate.test` fails | The expected output of a step did not appear, or a host-side check failed | Read the console log that the test keeps, from the step before `==== FAILED`. Then delete the `isolate-test.*` and `isolate-selftest-*` directories that it names. |
| `another isolate VM is already running` | A process holds `vm.lock` | Only one VM can run at a time. `pgrep -af 'firecracker\|qemu-system'` finds it. When a launcher crashes, it releases the lock automatically. |
| sudo prompt for the kernel on each launch | The copy failed silently, or you cannot write to `kernel/` | `ls -l ~/.local/share/isolate/kernel/`. It must hold `vmlinuz-$(uname -r)` (and `vmlinux-...` for Firecracker). |
| `extract-vmlinux not found` | No kernel headers for the kernel that runs (Firecracker only) | `sudo apt install linux-headers-$(uname -r)`, or use `isolate.qemu`. |
| `firecracker not found` | mise did not install it | Run `mise install` in this repo. |
| `bad ISOLATE_ALLOW entry` | Incorrect format, here or in `<p>/allow` | The entries are `host:PORT` or `IPv4:PORT`, with spaces or newlines between them. `#` starts a comment. |
| sudo prompt for networking on each launch | The ruleset hash changes (the allow list is different), or something deletes `$XDG_RUNTIME_DIR` | This is expected after a reboot or a change to the allow list. If not, compare `$XDG_RUNTIME_DIR/isolate-net.sha` between runs. |
| `warning: AppArmor profile 'isolate-vm' isn't installed` | The profile is not loaded | `sudo install -m644 apparmor/isolate-vm /etc/apparmor.d/ && sudo apparmor_parser -r /etc/apparmor.d/isolate-vm` |
| QEMU does not start, and it mentions `qemu-agent` | The old profile blocks the disks | Install the `isolate-vm` profile as above. |
| The VMM fails with `Permission denied` on a file or device | AppArmor blocked a path that the VMM needs | `journalctl -k -g 'apparmor="DENIED"' --since -5min` names the path. Add it to `apparmor/isolate-vm` and load the profile again. The usual causes are a new Firecracker version under a different install path, or a QEMU firmware file. |
| `Could not access KVM` / `/dev/kvm` errors | Virtualization is off, or you are not in the `kvm` group | `ls -l /dev/kvm`, `groups`. Enable VT-x/AMD-V in the firmware. |

## Boot and console

| Symptom | Likely cause | Check / fix |
|---|---|---|
| The VM stops in a few seconds with no output | Kernel panic (`panic=1` reboots, and this stops the VMM) | Run it again with visible output. Temporarily remove `systemd.show_status=error` from the cmdline of the launcher. Or use the other VMM, to see if the problem is specific to one VMM. |
| `VFS: Unable to mount root fs` | virtio-blk or ext4 is not built into the kernel (the guest has no modules) | Usually, distro kernels contain them, but custom kernels possibly do not. Make sure that `grep -E 'VIRTIO_BLK\|EXT4_FS=' /boot/config-$(uname -r)` shows `=y`. |
| The boot stops before a prompt | A unit waits for a device | Wait for the 10 s device timeout. Then, in the guest, run `systemctl --failed` and `journalctl -b -p warning`. |
| A prompt appears, but `/workspace` or `/persist` is empty | The launcher did not attach a disk, or the label of the disk is incorrect | In the guest, `lsblk -f` must show `project` on `vdc` and `isolate-cache` on `vdb`. If `cache.ext4` is damaged, run `e2fsck -f <p>/cache.ext4` on the host when no VM runs. |
| Full-screen apps draw at the incorrect size, and long lines wrap incorrectly | The serial/virtio console does not report a window size | Use `ssh isolate`. Or run `stty rows $LINES cols $COLUMNS` with the values of your host terminal. Or work in `tmux`. |
| Enter does nothing in the menus of Claude (theme picker, permission prompts), but the arrow keys work and the shell is correct | The host tty changes Enter (CR) into LF, and the raw mode of Firecracker does not stop this | The launcher now runs `stty -icrnl` for the session. If you start the VMM in a different way, do the same. In the guest, run `python3 -c 'import tty,os; tty.setraw(0); print(os.read(0,4))'` and push Enter. It must print `b'\r'`, not `b'\n'`. |
| Ctrl-C does not stop the VM (QEMU) | This is the design: `signal=off` sends it to the guest | Use `isolate-done` to stop. To force the VM to stop, kill the VMM from a different terminal. The work then does not get exported. |

## Network

Start from the outside and go in: the host link, the firewall, then the guest.

| Symptom | Likely cause | Check / fix |
|---|---|---|
| No network at all, and `ip addr` shows no `eth0` | You launched with `ISOLATE_NET=none` | Launch again without it. |
| `eth0` is up, but nothing gets to the internet | The firewall or forwarding on the host | On the host, run `ip link show isolate0` (it must be UP), `sudo nft list table inet isolate`, and `sysctl net.ipv4.ip_forward` (it must be 1). The Docker `FORWARD` drop or ufw can block it. Look at `sudo iptables -S DOCKER-USER` and `sudo ufw status`. To force the setup to run again, delete `$XDG_RUNTIME_DIR/isolate-net.sha`. |
| IP addresses work, names do not | Something upstream blocks DNS to `1.1.1.1` / `9.9.9.9` | In the guest, run `getent hosts example.com` and `ping -c1 1.1.1.1`. If your network forces its own resolver, edit `image/rootfs/etc/resolv.conf` and build again. |
| IPv6 addresses do not work | The firewall drops all IPv6 intentionally | Use IPv4. |
| A LAN or private address times out | The firewall drops private ranges intentionally | Add `IP:PORT` to `ISOLATE_ALLOW` or `<p>/allow`. |
| You allowed `host:PORT`, but the host refuses the connection | The host service listens only on `127.0.0.1` | On the host, `ss -ltnp \| grep PORT` must show `172.16.0.1:PORT` or `0.0.0.0:PORT`. |
| You allowed `host:PORT`, but the connection times out | The input policy of ufw drops it before the isolate rule | `sudo ufw allow in on isolate0 to 172.16.0.1 port PORT proto tcp` |
| An allow entry has a typo (for example `127.16.0.1`) | The address is not the link address of the host | For a host service, always use `host:PORT`. `IP:PORT` is for other machines. |
| `ssh isolate` does not respond | No network, or the guest is not up yet | It needs networking on and the `Host isolate` block from architecture.md. From the host, run `ping 172.16.0.2`. |
| `ssh isolate`: host key mismatch | ssh does not use the pinned `known_hosts` | Put `UserKnownHostsFile ~/.local/share/isolate/known_hosts` in the `Host isolate` block. |
| `ssh isolate`: permission denied (publickey) | The image authorizes a different key than the key that you offer | The build used `ISOLATE_SSH_PUBKEY` or `~/.ssh/id_ed25519.pub`. Offer that key, or build again. |
| TRAMP does not respond or shows garbage | Something in the shell printed output | For `TERM=dumb`, the guest does not show its greeting and prompt. Look in the fish snippets of your dotfiles for output that has no condition. |

## Inside the guest

| Symptom | Likely cause | Check / fix |
|---|---|---|
| A tool from `image/mise/config.toml` is "command not found" | The shims are not on `PATH` (non-login shell), or the install failed during the build | `mise ls --current`, `mise doctor`. `bash -l` loads `/etc/profile.d/isolate.sh`. |
| The tools of the project's own `mise.toml` install again in each session | This is expected: each launch starts with a new rootfs | The downloads stay in the cache on `/persist/cache/mise`. If one is slow, move it into `image/mise/config.toml`. |
| Something that you installed with `sudo apt install` is gone | This is expected: each launch starts with a new rootfs | Add the package to the apt list of the Containerfile and build again. |
| `/persist` is full | The caches became larger than `ISOLATE_CACHE_SIZE` | Run `du -sh /persist/*` in the guest. Clean the caches, or delete `<p>/cache.ext4` on the host (this logs the agents out). |
| A kernel feature is missing (Docker in the VM, FUSE, some netfilter targets) | The guest has no kernel modules | Only built-in features work. `ls /sys/module` shows the built-in features. |
| The author of the commits is "Isolate agent" | This is the design | Amend or rebase after the merge. |
| Codex, pi, opencode or agy asks for a login in each session | The `/persist/home` links of the project are missing (the image is older than the feature, or `isolate-prepare` failed) | Run `ls -l ~/.codex ~/.pi ~/.local/share/opencode ~/.gemini`. Each must be a symlink into `/persist/home`. `systemctl status isolate-export` shows the prepare errors. `sudo isolate-prepare` makes the links again without a reboot. |
| Only `agy` asks for a login in each session | It keeps its login in the OS keyring, and the guest has none | Known limitation. See [architecture.md](architecture.md#agent-state-and-session-logs). |
| An agent setting that you changed in the image does not apply | After the first session, the copy of the project under `/persist/home` has priority | Edit it in the guest, or delete that path under `/persist/home`. The next session then copies it from the image again. |
| The shell history is empty in a new session | bash: a non-login shell without `HISTFILE`. fish: the link is missing. | `echo $HISTFILE` must show `/persist/home/.bash_history`. `ls -l ~/.local/share/fish` must show a symlink. |

## Claude Code and plugins

Run these commands in the guest. The interactive commands go in a `claude`
session.

| Symptom | Likely cause | Check / fix |
|---|---|---|
| The setup wizard (theme picker) or the trust prompt appears | The image is older than the `.claude.json` merge, or the seed does not have `.claude.json` | Build again. The next boot adds the flags to the `.claude.json` of the project. `ls -a /usr/local/share/isolate/claude-seed/` must list `.claude.json`. `sudo isolate-prepare` applies it without a reboot. |
| Claude asks for a login again | A new project, or the launcher made a new `cache.ext4` | This is expected: one login for each project. |
| Plugins are missing in an existing project | The seed never overwrites, and the `settings.json` of the project existed before the plugins | Run `sudo isolate-prepare` to copy all missing seed entries (`plugins/` included). Then merge the plugin keys: `jq -s '.[0] + (.[1] \| {enabledPlugins, extraKnownMarketplaces})' /persist/claude/settings.json /usr/local/share/isolate/claude-seed/settings.json > /tmp/s && mv /tmp/s /persist/claude/settings.json` |
| Changes to the host settings do not show | The same cause: the launcher copies the seed one time for each project | Build again. Then delete the entry from `/persist/claude` and run `sudo isolate-prepare`. |
| `/plugin` shows that a plugin did not load | A runtime is missing, or the plugin path is incorrect | `/doctor`. The paths under `/persist/claude/plugins/` must be absolute, and they must exist. |
| lumen: the index is not healthy, and search fails | The guest cannot connect to Ollama | In the guest, run `curl -s $OLLAMA_HOST/api/tags`. For connection refused or a timeout, see the [Network](#network) rows for `host:PORT`. If the HTTP output does not include the model, run `ollama pull ordis/jina-embeddings-v2-base-code` on the host. Then run `/lumen:doctor`. |
| The context-mode tools are missing | Node is too old, or the MCP server failed | `node -e 'require("node:sqlite")'`, then `/context-mode:ctx-doctor`. |
| pyright-lsp reports no server | `pyright-langserver` is not on `PATH` | `command -v pyright-langserver`. It comes from `npm:pyright` in `image/mise/config.toml`. |
| Auto mode blocks routine local work | The classifier does not have the VM description | Run `jq .autoMode /persist/claude/settings.json`. Older projects do not have it. Copy it from the `settings.json` of the seed. |

## Getting the work back

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `the guest didn't export its work` | The VM was killed, crashed, or powered off without a clean shutdown | The launcher keeps the disk as `<p>/project-unimported-<stamp>.ext4`. Use `debugfs` to list or copy files from it (see [architecture.md](architecture.md#getting-the-work-back)). Next time, use `isolate-done` to stop. |
| The same message after `isolate-done` | `isolate-export` failed or took more than 5 minutes | In the next session, run `isolate-export` manually before `isolate-done`, and read its output. The usual cause of slow exports is a very large untracked tree (build output that is not in `.gitignore`). |
| `importing the bundle failed` | fsck refused an object, or the bundle is truncated | The bundle stays at `<p>/out.bundle`. `git bundle verify <p>/out.bundle` and `git -c transfer.fsckObjects=true fetch <p>/out.bundle` show the reason. |
| No `[d]iff [m]erge` prompt, only a command | The stdin of the launcher was not a terminal | Run the `git merge ...` command that it printed, or launch from an interactive terminal. |
| "No new commits", but the agent made changes | The changes are on a branch that is not the merge target | `git branch -r --list 'isolate/*'` and `git log --oneline HEAD..isolate/<branch>`. |
| A branch is gone from `refs/remotes/isolate/` | A later session pruned it, and archived it first | `git for-each-ref refs/isolate-archive` |
| The review warns about risky paths | The diff touches files that run code on your machine (CI, hooks, manifests, task runners) | Read those diffs first with `[d]iff`. |
| The review warns about Unicode | The changes added bidirectional or zero-width characters | Examine the flagged lines with `git diff ... \| cat -A`. These characters can hide code from a review. |
| No `Session logs:` line after the VM stops | Nothing to copy (no agent ran, and no history exists yet), or `debugfs` could not read `cache.ext4` | `debugfs -R 'ls -l /home' <p>/cache.ext4`. After a crash, the journal possibly did not replay yet. Then the newest entries can be missing until the next clean shutdown. |
| A log file under `<p>/logs/` changed or became smaller | A later session wrote it again (the guest writes history files again in place) | The previous version is in `<p>/logs-previous/<stamp>/` at the same relative path. Use `diff -r` to compare the two. |
| The merge stopped on conflicts | Your branch changed during the session | Resolve them as for each merge. If you accepted the stash offer, run `git stash pop` after the merge. |

## Narrowing it down

**Change one variable at a time.** Each of these removes a full layer:

- `isolate.qemu` or `isolate.fc`: the same image, disks and network. A
  failure under only one VMM points to that VMM, its kernel format
  (`vmlinux` or `vmlinuz`), or its AppArmor rules.
- `ISOLATE_NET=none`: no TAP, no nft, no sudo. If the problem stops, it is in
  the network setup.
- Remove the AppArmor profile (`sudo apparmor_parser -R
  /etc/apparmor.d/isolate-vm`), and install it again after the test. If the
  VMM starts without it, the profile does not have a path.
  `journalctl -k -g DENIED` names it.
- A new `cache.ext4` (move the old one to a different location, do not delete
  it). If the problem stops, it is in `/persist` (old Claude config, a full
  disk, a broken cache).
- A different repo. If a small throwaway repo works, the cause is the size of
  the project, the layout of its ignored files, or its own `mise.toml`.

**Look at the image without a boot.**

```sh
podman run --rm -it localhost/isolate-guest bash          # the image as built
debugfs -R 'ls -l /usr/local/share/isolate/claude-seed' ~/.local/share/isolate/rootfs.ext4
debugfs -R 'cat /etc/isolate/env' ~/.local/share/isolate/rootfs.ext4
```

The `podman run` shell has no `/persist` or `/workspace` disks and no
systemd. Use it to examine files and tools, not services.

**Look at the persistent disk of a project** (when no VM runs):

```sh
debugfs -R 'ls -l /claude' ~/.local/share/isolate/projects/<p>/cache.ext4
e2fsck -fn ~/.local/share/isolate/projects/<p>/cache.ext4   # read-only check
```

**In the guest**, the usual systemd tools work for the current session:

```sh
systemctl --failed
systemctl status isolate-export          # ExecStart = isolate-prepare
journalctl -b -u isolate-export
journalctl -b -p warning
lsblk -f; findmnt /workspace /persist
ip addr; ip route; getent hosts example.com; curl -sI https://example.com
```

The journal is on the rootfs, and the launcher discards the rootfs at exit.
So collect the data that you need before `isolate-done`.

**On the host, for the network:**

```sh
ip addr show isolate0
sudo nft list table inet isolate          # are your allow entries there?
sysctl net.ipv4.ip_forward
rm $XDG_RUNTIME_DIR/isolate-net.sha       # force the TAP and rules to be set up again
```

**Run one part again manually.** The launcher is plain fish in
`mise/scripts/isolate-vm.fish`. `fish_trace=1 fish
mise/scripts/isolate-vm.fish fc` prints each command when it runs. For the
build, `podman build image/` alone fails without the generated context. So
run `mise run isolate.build` again and read from the first error. In the
guest, you can run `isolate-export` and `sudo isolate-prepare` safely at any
time.
