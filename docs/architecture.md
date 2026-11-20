# isolate: how it works

This document describes the parts behind `mise run isolate.build`,
`isolate.fc` and `isolate.qemu`:

- what each disk holds,
- how the build makes the image,
- how the work gets back to the host,
- what the guest can connect to,
- how to change the tools in the guest.

For usage, see the [README](../README.md). When something does not work, see
[troubleshooting.md](troubleshooting.md). To build and test changes to
isolate, see [development.md](development.md).

## The big picture

```
build time (rootless)                       run time

image/Containerfile                         host repo (git)
  + image/rootfs/   ┐                          │ refs + working tree
  + image/mise/     │ podman build             ▼
  + dotfiles copy   ├──────────────▶ image ──▶ rootfs.ext4 ──copy──▶ vda  /
  + claude seed     │   mkfs.ext4 -d                                vdb  /persist   (cache.ext4, kept)
  + host mise bin   ┘                                               vdc  /workspace (project.ext4, fresh)
                                                                      │
                                         host kernel ──────────▶ Firecracker / QEMU microvm
                                                                      │ isolate-done
                                                                      ▼
                                         git fetch ◀── isolate-out.bundle (read with debugfs)
                                         refs/remotes/isolate/*
```

There are two separate parts:

- **The image** is an OCI container image. podman builds it from
  `image/Containerfile`, and the build then flattens it into an ext4
  filesystem. It is only an easy way to make a root filesystem. Nothing runs
  as a container at run time.
- **The VM** boots that filesystem with the kernel of the host, under a
  microVM monitor (Firecracker, or the `microvm` machine type of QEMU). The
  VM has three raw disk images and a TAP network device.

## Host-side layout

All the host state is under `~/.local/share/isolate/`:

```
~/.local/share/isolate/
├── rootfs.ext4              the built guest image (base copy, never booted directly)
├── known_hosts              the guest's sshd host key, pinned at build time
├── kernel/
│   ├── vmlinuz-<uname -r>   copy of /boot/vmlinuz (QEMU)
│   └── vmlinux-<uname -r>   uncompressed, for Firecracker
├── vm.lock                  flock: one VM at a time
├── tmp/                     podman's TMPDIR during builds
└── projects/
    └── <name>-<sha8>/       one per repo; sha8 = hash of the repo's absolute path
        ├── path             the repo path, for humans
        ├── allow            optional ISOLATE_ALLOW entries, one or more per line
        ├── cache.ext4       /persist, persistent, sparse
        ├── rootfs.ext4      this session's copy of the base image (transient)
        ├── project.ext4     this session's /workspace (transient)
        ├── vm-config.json   Firecracker config (transient)
        ├── logs/            agent transcripts + shell history, copied after each session
        ├── logs-previous/<stamp>/   earlier versions of log files a later session changed
        └── project-unimported-<stamp>.ext4   a session whose export failed
```

At launch, the launcher deletes the kernel copies for all kernel versions
other than the one that runs. Only root can read the kernel image of the
host. So the first launch after each kernel upgrade runs `sudo install` one
time to copy it.

Two repos with the same directory name get separate state, because of the
path hash. When you move a repo, it gets a new cache disk. You can delete the
old directory manually.

## The three disks

| Device | File | Mounted at | Lifetime |
|---|---|---|---|
| `vda` | `projects/<p>/rootfs.ext4` | `/` | A new copy of `rootfs.ext4` at each launch. All that you install system-wide during a session is gone the next time. |
| `vdb` | `projects/<p>/cache.ext4` | `/persist` | The launcher makes it at the first launch (`ISOLATE_CACHE_SIZE`, default 32G, sparse) and keeps it. It holds package caches, agent logins, transcripts and shell history. |
| `vdc` | `projects/<p>/project.ext4` | `/workspace` | The launcher makes it new from the repo at each launch, reads it back at shutdown, and then deletes it. |

The guest mounts the disks by label (`LABEL=isolate-cache`, `LABEL=project`)
from `image/rootfs/etc/fstab`. The root is the full `/dev/vda`, with no
partition table.

### What goes into /workspace

The launcher builds a staging repo. Then it uses `mkfs.ext4 -d` to make
`project.ext4` from it. The staging repo has:

- all local branches and tags (`git fetch` from your repo, no remotes),
- `HEAD` on the same branch (or detached commit) as yours,
- the working tree **as `git status` sees it**: tracked files and untracked
  files, but no ignored files. So `.env`, `node_modules/`, build output and
  other ignored files do **not** go in,
- your uncommitted changes, which stay uncommitted (the launcher resets the
  index, so they show as unstaged).

The launcher does not copy the contents of submodules (it shows a note). It
also does not copy the remotes, stashes, hooks and your `.git/config`. The
guest repo is a plain `git init` that holds your objects.

### What is on /persist

`image/rootfs/etc/tmpfiles.d/isolate.conf` makes these directories at boot,
and `/etc/isolate/env` connects them:

| Path | Used for |
|---|---|
| `/persist/cache` | `XDG_CACHE_HOME`: pip, uv, npm (`npm_config_cache`), mise downloads (`MISE_CACHE_DIR`), tealdeer pages |
| `/persist/claude` | `CLAUDE_CONFIG_DIR`: Claude Code login, settings, plugins, history (mode 0700). The first boot copies the seed from the image. |
| `/persist/home` | The state and shell history of the other agents, with symlinks from the home directory (mode 0700). See [Agent state and session logs](#agent-state-and-session-logs). |
| `/persist/npm-global` | `NPM_CONFIG_PREFIX`: `npm install -g` |
| `/persist/cargo`, `/persist/rustup` | `CARGO_HOME`, `RUSTUP_HOME` |
| `/persist/go` | `GOPATH` |

Each project has its own `/persist`. So an agent in one project cannot see
the caches or logins of a different project. You log in to each agent one
time for each project.

`uv` uses `UV_LINK_MODE=copy`. Its cache (on `/persist`) and the virtualenv
(on `/workspace`) are on different filesystems, so hardlinks are not
possible.

To reset the persistent state of a project, delete its `cache.ext4`.

## Boot

The guest runs **the kernel of the host** (`uname -r`), so you do not have a
guest kernel to maintain. Firecracker needs an uncompressed ELF `vmlinux`.
The launcher extracts it one time for each kernel version, with
`extract-vmlinux` from `/usr/src/linux-headers-<ver>/scripts/`. QEMU boots
the `vmlinuz` directly.

Kernel command line (both):
`panic=1 root=/dev/vda rw rootfstype=ext4 init=/lib/systemd/systemd systemd.show_status=error`

| | Firecracker | QEMU microvm |
|---|---|---|
| Console | `ttyS0` serial | `hvc0` (virtio console) |
| Firmware | none | `qboot.rom` |
| Exit on reboot | `reboot=k` (Firecracker stops on reboot) | `reboot=t` + `-no-reboot` |
| Config | `vm-config.json`, `--no-api` (no control socket) | command-line arguments |
| Host terminal | The launcher adds `stty -icrnl`. The raw mode of Firecracker keeps CR→LF on, and this breaks Enter in TUIs. | `-chardev stdio` makes it fully raw |
| Binary | mise install path, found behind the shim | `/usr/bin/qemu-system-x86_64` |

The guest has no initramfs and **no kernel modules**. It has only the
features that are built into your distro kernel. Ubuntu kernels have virtio,
ext4, networking and the usual filesystems built in. A feature that needs a
loadable module does not load. Examples are some netfilter targets for
Docker in the VM, and FUSE on some kernels.

systemd boots normally. `systemd-networkd` gives `eth0` a static
configuration (`/etc/systemd/network/10-isolate.network`). A getty on the
console logs in `agent-user` automatically. `isolate-export.service` starts
when both disks are mounted:

- **ExecStart** runs `isolate-prepare` as root. It makes the `/persist`
  directories, and copies the seed from the image into `/persist/claude` (see
  [Claude Code settings](#claude-code-settings)). It also links the state
  directories of the other agents into `/persist/home` (see
  [Agent state and session logs](#agent-state-and-session-logs)).
- **ExecStop** runs `isolate-export` as `agent-user` at shutdown.

The console getty and sshd start after `isolate-export.service`. So no shell
starts before those links exist.

## Getting the work back

`isolate-done` is `sudo systemctl reboot`. The launcher sets both VMMs to
stop when the guest reboots. So a reboot is a clean power-off that runs the
stop step of each service. `sudo reboot` and `sudo poweroff` work the same
way. If you kill the VMM, the export does not run.

At shutdown, `isolate-export` does these steps:

1. It stages the full working tree into a **temporary index**. Your real
   index and working tree do not change.
2. If that tree is different from `HEAD`, it commits it as
   `refs/heads/isolate-wip`, with `HEAD` as the parent.
3. It writes `/workspace/.git/isolate-out.bundle`, which contains all
   branches.

After the VMM stops, the launcher does these steps:

1. It uses `debugfs` to get the bundle from `project.ext4`. The host never
   mounts the image.
2. It archives each existing `refs/remotes/isolate/*` ref that no local
   branch contains to `refs/isolate-archive/<stamp>/<name>`. So the unmerged
   work of an earlier session stays after the prune.
3. It runs `git fetch --prune` from the bundle into `refs/remotes/isolate/*`,
   with `transfer.fsckObjects` on.
4. It selects a merge target: `isolate/isolate-wip` if it exists, and if not,
   `isolate/<your branch>`.
5. It shows the new commits, flags risky paths and suspicious Unicode, and
   gives the prompt `[d]iff [m]erge [s]quash [q]uit`. Before a merge or a
   squash, it offers to stash your own uncommitted changes on the host.

If there is no bundle, the launcher renames `project.ext4` to
`project-unimported-<stamp>.ext4` and keeps it. If the bundle exists but the
fetch refuses it, the launcher keeps the disk in the same way. The bundle
then stays at `projects/<p>/out.bundle`. When the stdin of the launcher is
not a terminal, the launcher does not show the prompt. It prints the merge
command. To look in a kept disk without a mount:

```sh
debugfs -R 'ls -l /' project-unimported-<stamp>.ext4
debugfs -R 'dump /path/in/repo /tmp/out' project-unimported-<stamp>.ext4
```

The archived refs from previous sessions:

```sh
git for-each-ref refs/isolate-archive
git log -p HEAD..refs/isolate-archive/<stamp>/<name>
git update-ref -d refs/isolate-archive/<stamp>/<name>    # drop
```

### Why a bundle and not a shared folder

A shared folder (9p, virtiofs) gives the guest a live channel that can write
into your filesystem. Examples are symlink tricks, writes into `.git/hooks`,
and changes to files while you read them. A bundle is one inert file. The
import checks its objects with fsck. It goes into a ref namespace that your
checkout does not use. Nothing executes until you merge.

The review step names the files that can execute something after you merge:

- CI config (`.github/`, `.gitlab-ci*`),
- `.envrc` and `mise*.toml`/`.mise/`,
- editor config (`.vscode/`, `.idea/`),
- hook managers (`.husky/`, `.pre-commit*`),
- `.gitattributes` and `.gitmodules`,
- task runners (`Makefile`, `justfile`, `Taskfile*`),
- package manifests and build scripts (`package.json`, `setup.py`,
  `pyproject.toml`, `conftest.py`, `build.rs`, `.cargo/`),
- `Dockerfile` and compose files.

## Network

With networking on (the default), the guest gets one virtio NIC on a TAP
device:

| | |
|---|---|
| Host side | `isolate0`, `172.16.0.1/30`, owned by your user |
| Guest | `eth0`, `172.16.0.2`, MAC `06:00:ac:10:00:02` |
| DNS | `/etc/resolv.conf` in the image: `1.1.1.1`, `9.9.9.9` |

The launcher installs an nftables table `inet isolate`:

- **input:** from the guest, the firewall accepts only two types of traffic.
  These are replies to traffic that the host started, and the `host:PORT`
  entries from `ISOLATE_ALLOW`. It drops all other traffic to the host. So
  the guest cannot connect to your local databases, dev servers, or `ssh` on
  the host.
- **forward:** the guest can connect to the public internet. The firewall
  drops spoofed source addresses and all IPv6. It also drops all private,
  loopback, link-local, CGNAT, benchmark and multicast ranges, but not the
  `IP:PORT` entries in `ISOLATE_ALLOW`. Nothing outside the host can open a
  connection *to* the guest.
- **postrouting:** masquerade the guest out of your default route.

If Docker is installed, the launcher also adds `ACCEPT` rules for `isolate0`
to the `DOCKER-USER` chain (the `FORWARD` policy of Docker is `DROP`). If
ufw is active, it adds `ufw route allow` rules. For `host:PORT` entries
under ufw, possibly you also need
`sudo ufw allow in on isolate0 to 172.16.0.1 port PORT proto tcp`.

The setup of the TAP and the rules needs sudo. The launcher keeps a hash of
the ruleset in `$XDG_RUNTIME_DIR/isolate-net.sha`. So it needs sudo again
only when the allow list changes, or after a reboot.

`ISOLATE_NET=none` does not do any of this. The guest then has no NIC.

Only one VM runs at a time, because all VMs share `isolate0` and the guest
address. A second launch fails immediately on `vm.lock`.

### ssh and editors

Each build pins the ed25519 host key of the guest into
`~/.local/share/isolate/known_hosts`. It also authorizes your
`~/.ssh/id_ed25519.pub` (or `ISOLATE_SSH_PUBKEY`) for `agent-user`. sshd
accepts only keys, and only for `agent-user`. Put this in `~/.ssh/config`:

```
Host isolate
    HostName 172.16.0.2
    User agent-user
    UserKnownHostsFile ~/.local/share/isolate/known_hosts
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Then you can use `ssh isolate`, `scp`, `rsync`, Emacs TRAMP
(`/ssh:isolate:/workspace/`, and root with `/ssh:isolate|sudo:isolate:/etc/`)
and VS Code Remote-SSH. The host key changes with each build, and the build
writes the pinned file again each time. So you get no host-key warnings
after a new build.

The ssh connection goes from the host to the guest, and the firewall allows
this. The guest still cannot open connections back to the host. The
configuration has no agent forwarding. Do not add `ForwardAgent` for this
host, because it lets the guest use your keys.

## AppArmor

`apparmor/isolate-vm` confines the VMM process itself (Firecracker or QEMU),
in case a guest escapes into it. The launcher applies it with
`aa-exec -p isolate-vm --`. It allows only:

- the VMM binaries (the system QEMU, the Firecracker that mise installed),
- the kernel copies, the three disk images and `vm-config.json` under
  `~/.local/share/isolate/projects/*/`,
- `/dev/kvm`, `/dev/net/tun`, the QEMU firmware, and some `/proc` and `/sys`
  reads,
- signals between its own threads.

It allows no network sockets, and no access to your home directory other
than those files. If the profile is not installed, the launcher shows a
warning and runs the VMM without confinement. After you edit the profile,
install it again:

```sh
sudo install -m644 apparmor/isolate-vm /etc/apparmor.d/
sudo apparmor_parser -r /etc/apparmor.d/isolate-vm
```

An older `/etc/apparmor.d/qemu-agent` profile (from the previous qcow2-based
setup) can be present while `isolate-vm` is not. Then QEMU launches do not
start. That profile attaches to each `qemu-system-x86_64`, and it blocks
these disks.

## The guest image

### Build pipeline

`mise run isolate.build` (`mise/scripts/isolate-build.fish`) does these steps,
all rootless:

1. It copies `image/` to a temporary build context, and adds these items:
   - `authorized_keys`: your public key,
   - `mise-bin`: the mise binary of the host (`ISOLATE_MISE` overrides it),
   - `dotfiles/`: the filtered dotfiles copy ([below](#dotfiles)),
   - `claude-seed/`: `settings.json` (filtered host settings, merged with
     `image/claude/settings.json`), `.claude.json` (onboarding flags and
     `/workspace` trust) and `CLAUDE.md` ([below](#claude-code-settings)).
2. It gets a GitHub token from `mise token github --raw` into a separate
   temporary directory, outside the build context.
3. It runs `podman build --secret id=github_token,... --build-arg
   TOOLS_STAMP=...` to `localhost/isolate-guest:latest`.
4. In `podman unshare`, it searches the filesystem of the image for the token.
   If it finds the token, the build fails. Then it writes `rootfs.ext4` with
   `mkfs.ext4 -d`, so files that root owns stay owned by root.
5. It does a sanity check of the ownership in the ext4 (root owns `sudo`, and
   your uid owns the home). Then it uses `debugfs` to read the sshd host key
   from the ext4, and it writes `known_hosts`.

At exit, the build removes the temporary directories.

### What the Containerfile does

In this sequence (each step is a layer in the cache):

1. `FROM ubuntu:26.04`, apt packages (systemd, sshd, git, build-essential,
   python3, nodejs/npm, ripgrep, fd, jq, fish, ...).
2. Replace the uid-1000 `ubuntu` user of Ubuntu with `agent-user`. It uses
   your host uid/gid, so that the ownership of the `/workspace` files is
   correct. The login shell is fish. The user is a member of `sudo` with
   NOPASSWD (`/etc/sudoers.d/agent-user`).
3. `COPY rootfs/ /`: all static configuration. Then enable
   `systemd-networkd` and `isolate-export`. Mask the units that make the boot
   slow or connect to external services (apt timers, motd-news,
   wait-online). Make new sshd host keys, and empty `machine-id`.
4. `authorized_keys`, the mise binary, `image/mise/config.toml`, dotfiles,
   `image/home/config.fish`, the Claude seed.
5. As `agent-user`: `mise install`, with the GitHub token from the build
   secret if there is one.
6. Claude plugins from `image/claude/plugins`. The build stages the
   `settings.json` of the seed in `/persist/claude`. It adds each marketplace
   and installs each plugin there, so the recorded paths are the same as in
   the guest. It gets the lumen binary, and it checks `node:sqlite` for
   context-mode. Then `plugins/` and the updated `settings.json` move into the
   seed, and the build empties `/persist` again. ([Plugins](#plugins))

### Guest filesystem layout

```
/usr/local/bin/mise                  host's mise binary
/usr/local/bin/isolate-done          save + power off
/usr/local/bin/isolate-export        shutdown: write the bundle
/usr/local/bin/isolate-prepare       boot: /persist dirs, Claude seed, agent state links
/usr/local/share/isolate/claude-seed/   settings.json, .claude.json, CLAUDE.md, plugins/
/etc/isolate/env                     shared env vars (KEY=VALUE, no shell syntax)
/etc/profile.d/isolate.sh            bash login: loads env, PATH, greeting
/etc/fish/conf.d/isolate.fish        fish: loads env, PATH, mise activate, greeting
/etc/gitconfig                       "Isolate agent <agent@isolate.invalid>", safe.directory
/home/agent-user/
├── .config/mise/config.toml         guest-wide tools (from image/mise/config.toml)
├── .config/fish/config.fish         from image/home/config.fish
├── .config/{starship.toml,tmux,...} your dotfiles
├── .local/share/mise/installs/      the guest-wide tools, baked in
└── .codex .pi .gemini ... (symlinks)   agent state on /persist/home
/workspace                           your repo (vdc)
/persist                             per-project cache (vdb)
```

The author of the commits in the guest is `Isolate agent
<agent@isolate.invalid>`, so they are easy to see in `git log`. If you want
your own name on them, amend or rebase after the merge.

### Shell environment

`/etc/isolate/env` is the one list of environment variables. Both shells read
it:

- **bash** login shells (console, `ssh isolate bash -l`) through
  `/etc/profile.d/isolate.sh`,
- **fish** through `/etc/fish/conf.d/isolate.fish`.

Both put the mise shims, `~/.local/bin`, `/persist/npm-global/bin`,
`/persist/cargo/bin` and `/persist/go/bin` on `PATH`. Interactive fish also
runs `mise activate`, and starship from `config.fish`. When `TERM=dumb`
(TRAMP, scripts), the shells do not show the greeting and the prompt, and do
not activate mise. So nothing adds to the output.

The file sets the `/persist` locations above (`HISTFILE=/persist/home/.bash_history`
included). It also sets `DISABLE_AUTOUPDATER=1`, `UV_LINK_MODE=copy` and
`OLLAMA_HOST=http://172.16.0.1:11434` (for [lumen](#plugins)).

To add a variable for each session, add a `KEY=VALUE` line to
`image/rootfs/etc/isolate/env` and build again.

## Adding and removing tools

Tools come from three locations. Select the location by how many projects
need the tool, and by how the tool is distributed.

| Where | Scope | Installed | Persists |
|---|---|---|---|
| `image/mise/config.toml` | every project | at image build | in the image |
| apt list in `image/Containerfile` | every project | at image build | in the image |
| `mise.toml` in your repo | that repo | per session, on first use | download cache only |

### Guest-wide tools: image/mise/config.toml

This file is the `~/.config/mise/config.toml` of the guest. The current set:

```toml
[tools]
# agents
claude = "latest"
codex = "latest"
pi = "latest"
agy = "latest"
"aqua:anomalyco/opencode" = "latest"   # plain "opencode" resolves to npm first
# orientation
witr = "latest"
tealdeer = "latest"
qdns = "latest"
# language servers for the image's Claude plugins (image/claude/plugins)
"npm:pyright" = "latest"              # pyright-lsp needs pyright-langserver
# session (usage: needed for mise's shell completions)
usage = "latest"
tmux = "latest"
starship = "latest"
```

To **add** a tool, add a line with a mise backend and build again:

```toml
gh = "latest"                    # registry short name
"aqua:BurntSushi/ripgrep" = "14" # explicit backend + version constraint
"npm:prettier" = "latest"        # npm package (needs node: the apt nodejs works)
"pipx:httpie" = "latest"         # Python CLI (uses uv if present)
"cargo:tokei" = "latest"         # built from source: slow, needs a Rust toolchain in [tools]
```

Prefer backends that download prebuilt binaries (aqua, github, ubi, the
defaults of the registry). They are fast, and they do not need compilers in
the image. To see what a short name resolves to, run `mise registry <name>`
on the host.

To **remove** a tool, delete its line and build again. The removal has an
effect immediately, because the build makes the tool layer again each time
that the file changes.

The `[settings]` in the same file:

- `trusted_config_paths = ["/workspace"]`: mise trusts the own `mise.toml` of
  the project without a prompt. This is intentional: the guest exists to run
  the code of the project.
- `minimum_release_age_excludes = ["claude"]`: mise takes Claude Code updates
  immediately, also if you set a minimum release age.
- `python.uv_venv_auto = "create|source"`: for projects with a uv/Python
  setup, mise makes and activates a `.venv` automatically.

The env file sets `DISABLE_AUTOUPDATER=1`. So the agents do not try to update
themselves in a rootfs that the launcher discards anyway. Updates come from
new builds.

### When "latest" resolves

`"latest"` resolves when the `mise install` layer runs. The build makes that
layer again in three cases: when `image/mise/config.toml` changes, when the
mise binary changes, or when the `TOOLS_STAMP` build argument changes.
`TOOLS_STAMP` is the build date. So the **first build each day** gets new
releases, and later builds on that day use the layer again. To force a new
resolve:

```sh
ISOLATE_REFRESH=1 mise run isolate.build
```

When reproducibility is more important than new versions, pin a version
(`claude = "2.1"`).

### System packages: the apt list

Some tools are not available through mise, or other packages need them
(compilers, `-dev` headers, `ncurses-term`). Put them in the `apt-get
install` list at the top of `image/Containerfile`. Add or remove package
names and build again. This makes all later layers invalid, so the build
takes a few minutes.

Keep the image small. If only one project needs a tool, put it in the
`mise.toml` of that project.

### Per-project tools: the mise.toml of the repo

The repo can have a `mise.toml` (or `.mise.toml`, `.tool-versions`). This
file is in `/workspace` and mise trusts it. So the own toolchain of the
project (node 22, python 3.13, go, rust, terraform...) works as on the host.
In the guest:

```sh
mise install          # or let `mise activate` / shims prompt it
```

mise installs these tools into the rootfs of the guest, which is new in each
session. So they **install again in each session**. The downloads stay in the
cache on `/persist/cache/mise`. After the first session, this is an unpack,
not a download. If a project tool is slow to install each time (for example,
because it compiles from source), think about a move into
`image/mise/config.toml`.

The agent can install tools itself with `npm install -g`, `cargo install`,
`go install` or `uv tool install`. These tools go under `/persist` and stay
across the sessions of that project. Packages that you install with
`sudo apt install` are gone at the next launch.

### Rebuilding

```sh
mise run isolate.build
```

A new build has no effect on VMs that run. The next launch uses the new
`rootfs.ext4`. The cache disks of the projects stay across new builds.

## Dotfiles

Dotfiles are opt-in. If `ISOLATE_DOTFILES` is not set, the build copies no
dotfiles. Only you know which of your files hold secrets, so the build does
not guess.

If you set `ISOLATE_DOTFILES`, the build copies an allowlist of stow-style
packages from that directory into the guest home. Each package directory has
the same structure as `$HOME` (`~/dotfiles/fish/.config/fish/...`). The default
list is `ISOLATE_DOTFILE_PKGS="fish starship tmux claude"`. The build skips
missing packages.

The build always excludes these files, in all packages:

- VCS and editor debris: `.git`, `*~`, `*.bak`, `#*#`
- `fish_variables` (universal variables, often secrets)
- `.config/fish/config.fish` (`image/home/config.fish` replaces it)
- files that look like credentials: `.credentials.json`, `auth.json`, `*.pem`,
  `*.key`, `id_*`, `.env*`, `.netrc`, `*token*`, `*secret*`

Add your own rsync exclude patterns in `ISOLATE_DOTFILE_EXCLUDE`, separated by
spaces. Use it for files that hold API keys, and for host-only snippets that
do not apply in the guest. For example:

```sh
ISOLATE_DOTFILES=~/dotfiles \
ISOLATE_DOTFILE_EXCLUDE="/.config/fish/conf.d/desktop.fish my_api_key.fish" \
  mise run isolate.build
```

To keep these settings, put them in the `[env]` table of a `mise.local.toml`
file in the root of this repo. Git ignores that file. To see what the build
copied:

```sh
podman run --rm localhost/isolate-guest find /home/agent-user -path '*/mise/installs' -prune -o -type f -print
```

Think of all that goes into the image as data that the agent can read, and
also all code that the agent runs.

## Claude Code settings

The config directory of Claude Code is `/persist/claude`. So its login and
history persist for each project. The image has a seed in
`/usr/local/share/isolate/claude-seed/`. At boot, `isolate-prepare` copies the
seed into `/persist/claude`, **but only if the target file does not exist
yet**. So it never overwrites the changes that you make in the guest.

The one exception is `.claude.json`. If it exists, `isolate-prepare` adds the
onboarding flags and the `/workspace` trust of the seed where they are
missing. The existing values have priority. `isolate-prepare` always sets
`hasCompletedOnboarding`, so an older project does not stop at the setup
wizard.

The seed contains:

- `settings.json`: from your host `~/.claude/settings.json`, only
  `autoCompactEnabled`, `autoCompactWindow`, `permissions` and `statusLine`.
  The build keeps `statusLine` only if the `claude` dotfiles package has
  `~/.claude/statusline-command.sh`, and then points it at that guest path.
  On top of that goes `image/claude/settings.json`, the guest settings
  of this repo. Then come the plugin entries (`enabledPlugins`,
  `extraKnownMarketplaces`) that the plugin install below writes. The build
  never copies the host hooks, MCP servers, env, plugins and `autoMode`
  notes. They describe the host, its paths and its projects.
- `.claude.json`: the onboarding and hint flags from your host
  `~/.claude.json` (`hasCompletedOnboarding`, `lastOnboardingVersion`,
  `theme` and some dismissed hints), and folder trust for `/workspace`. So
  Claude starts without the setup wizard or the trust prompt. The build does
  not copy account details, user and machine ids, per-project history and
  caches.
- `CLAUDE.md`, if it is not empty.
- `plugins/`: the plugins that `image/claude/plugins` lists, installed at
  build time.

The build never copies the credentials (`.credentials.json`). Log in in the
guest one time for each project. To copy the seed again after you change
your host settings, build again. Then delete the entry from the
`/persist/claude` of the project (or the full `cache.ext4`).

### Auto mode

The seeded `permissions.defaultMode` comes from your host. So if you use auto
mode there, the guest also uses it. The auto mode classifier reads
`autoMode.environment`, which is free text about where Claude runs. The guest
version, in `image/claude/settings.json`, describes the VM:

- a disposable copy of the repo,
- no host credentials,
- outgoing traffic to the public internet only,
- work that comes back as a bundle that you review.

With that text, the classifier thinks of local damage as routine. But it
still thinks of data that goes out, and of all publishing, as high risk. To
change what the guest classifier gets, edit that file, not your host
settings.

`--dangerously-skip-permissions` removes that classifier fully. In the VM,
it can only damage the copy. But a prompt-injected agent can still send
`/workspace` or its own login to the internet.

### Plugins

`image/claude/plugins` lists one `<marketplace source> <plugin@marketplace>`
on each line. The default:

| Plugin | Needs in the guest |
|---|---|
| `lumen@ory` (semantic code search) | An Ollama (or LM Studio) embedding server. See below. The build gets its binary. |
| `context-mode@context-mode` | Node 22.5 or newer (the apt `nodejs`, and the build checks it) |
| `pyright-lsp@claude-plugins-official` | `pyright-langserver`, from `npm:pyright` in `image/mise/config.toml` |

The build installs them with `CLAUDE_CONFIG_DIR=/persist/claude`, because
Claude records absolute paths. Then it moves `plugins/` into the seed. A
project gets its copy in its first session, and later builds do not replace
it. To use a changed plugin list in an existing project, delete
`/persist/claude/plugins` and the `enabledPlugins`/`extraKnownMarketplaces`
keys from its `settings.json`. Or run `claude plugin install` there.

**lumen and Ollama.** lumen embeds code with a local model. The guest is too
small to run a model well, so lumen uses Ollama on the host.
`/etc/isolate/env` sets `OLLAMA_HOST=http://172.16.0.1:11434`. To make it
work, do these steps:

1. Make the Ollama of the host listen on the VM link (for example
   `OLLAMA_HOST=172.16.0.1:11434 ollama serve`, or `0.0.0.0`).
2. Pull the model (`ollama pull ordis/jina-embeddings-v2-base-code`).
3. Open the port for the project:

```sh
echo host:11434 >> ~/.local/share/isolate/projects/<project>/allow
```

This gives the guest the full Ollama API (pull and delete of models
included), not only embeddings. Without it, lumen reports an index that is
not healthy, and its search tool fails. The other plugins continue to work.

## Agent state and session logs

The login, settings and conversation history of each agent persist for each
project. Claude uses `CLAUDE_CONFIG_DIR=/persist/claude`. The other agents
keep their state at fixed paths in the home directory. So at boot,
`isolate-prepare` replaces each of those paths with a symlink to the same
path under `/persist/home`.

In the first session of a project, `isolate-prepare` first moves the copy of
the image (if there is one) there. After that, the `/persist` copy has
priority. So a change to the config of an agent in the image does not get to
existing projects. (`isolate-prepare` does not redirect `XDG_DATA_HOME`,
because the baked-in mise tools are under `~/.local/share/mise`.)

| Agent / shell | Home path (symlinked) | Login | Sessions / history |
|---|---|---|---|
| Claude Code | `/persist/claude` (env var) | `.credentials.json` | `projects/`, `history.jsonl` |
| Codex | `~/.codex` | `auth.json` | `sessions/`, `history.jsonl` |
| pi | `~/.pi` | `agent/auth.json` | `agent/sessions/` |
| opencode | `~/.local/share/opencode`, `~/.local/state/opencode` | `auth.json` | `opencode.db`, `storage/`, `log/` |
| Antigravity (`agy`) | `~/.gemini`, `~/.antigravity` | OS keyring, see below | `antigravity/brain/`, `antigravity/conversations/` |
| fish | `~/.local/share/fish` | | `fish_history` |
| bash | `HISTFILE=/persist/home/.bash_history` | | `.bash_history` |

`agy` asks for credentials through the Secret Service API
(`org.freedesktop.secrets`). The guest has no keyring daemon. So the login
stays only if agy has a fallback for this case. If it asks you to log in
in each session, this is the cause.

The agent configuration in `~/.config` (for example `~/.config/opencode`)
does not persist. It comes from the image (your dotfiles) at each launch.

**Host copy.** After the VM stops, the launcher copies the logs, also when the
session did not export. It uses `debugfs rdump` to read the transcript and
history paths in the table from `cache.ext4`. It copies them into
`projects/<p>/logs/`, with the same layout as in the guest
(`logs/claude/projects/...`, `logs/home/.codex/sessions/...`).

- The launcher does not copy the credentials. It drops symlinks and special
  files, and it makes all files private to you.
- The launcher only adds or updates files, and never deletes them.
- When the content of a file changed since the last copy, the launcher moves
  the old version to `logs-previous/<stamp>/`.

So a later session (or a compromised agent) cannot secretly change the record
of an earlier session.

To read them:

```sh
cd ~/.local/share/isolate/projects/<p>/logs
ls home/.local/share/fish/fish_history home/.bash_history
ls -t claude/projects/*/*.jsonl | head        # Claude transcripts, newest first
ls -t home/.codex/sessions/*/*/*/*.jsonl | head
sqlite3 home/.local/share/opencode/opencode.db .tables
```

When you delete `cache.ext4`, the state of the agents resets, but `logs/`
does not change.

## Secrets policy

The image must never contain a secret, because each agent and each
dependency can read it.

- **GitHub token:** mise needs one to prevent GitHub API rate limits when it
  installs tools. The build gets it from `mise token github` on the host, and
  writes it to a temporary file outside the build context. It gives it to
  podman as a **build secret**, which podman mounts only during the `mise
  install` step. Then the build searches the exported image for the token
  string, and fails if it finds it. The guest has no GitHub
  token at run time. If an agent needs one, give it a token with a narrow
  scope in the session, not in the image.
- **Dotfiles:** an allowlist and excludes, as above.
- **Claude:** filtered settings and onboarding flags only. No credentials,
  account details or ids.
- **Session logs:** the host copy of the transcripts and history does not
  include the credential files of the agents (`auth.json`,
  `.credentials.json`). The transcripts can still contain all that an agent
  printed or read. So treat `logs/` with the same care as the project itself.
- **ssh:** only your *public* key goes in. No agent forwarding.
- **Registry auth:** the build pulls the base image anonymously, unless
  `ISOLATE_AUTHFILE` is set.

The repo goes in without the ignored files. So keep `.env` and similar files
in `.gitignore`. Secrets that you committed to the repo do go in. That is a
problem of the repo, not of isolate.

## Troubleshooting

See [troubleshooting.md](troubleshooting.md). It gives the symptoms for each
phase (build, launch, network, guest, Claude plugins, import), and how to
find the cause of a problem.
