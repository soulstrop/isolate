# Roadmap

The current state, the open questions, and the planned and proposed work for
isolate. When an item gets a schedule, move it from the backlog into a
release section.

## Status (2026-11-13)

The tool works from start to end. The maintainer ran `isolate.fc` on a real
project, and the build and the tests passed in the guest. These items are
complete and verified:

- Agent state and shell history persist for each project under
  `/persist/home` (codex, pi, opencode, agy, fish, bash). Claude uses
  `CLAUDE_CONFIG_DIR=/persist/claude`. The code is in
  `image/rootfs/usr/local/bin/isolate-prepare`.
- After each session, the launcher copies the session logs (not the
  credentials) to `~/.local/share/isolate/projects/<project>/logs/`. It
  keeps the earlier versions of changed files in `logs-previous/<stamp>/`.
- Enter works in the TUI of Claude under Firecracker. The launcher clears
  `ICRNL` on the host terminal while the VMM runs (`stty -icrnl -inlcr
  -igncr`), and then it restores the settings.
- The onboarding and theme wizard of Claude does not appear.
  `isolate-prepare` merges the onboarding flags of the seed into an existing
  `.claude.json`.
- Automatic checks: `mise run isolate.check` (static) and `mise run
  isolate.test` (end to end). Both pass under Firecracker and QEMU with
  `--claude`. This also verified the QEMU console after the tty change.

These items are not verified:

- The agy login persistence. agy can use a keyring, and the guest has none
  (see architecture.md, "Agent state and session logs").
- A full session on a real project with the newest image.

## Public release on GitHub

The items that the project needed before it went public, in order of
priority. All items in "Must do" and "Should do" are complete.

### Must do

- [x] **1. Make dotfiles opt-in.** The build copies no dotfiles unless you
  set `ISOLATE_DOTFILES`. The default excludes are generic credential
  patterns. `ISOLATE_DOTFILE_EXCLUDE` adds personal patterns. Before, the
  build copied `~/dotfiles` by default, with an exclude list for one person.
  Other users could leak secrets into their image.
- [x] **2. Give all the host requirements in the README.** These are x86-64,
  the Debian-family kernel layout, `fish`, `rsync`, `jq`, `nftables`,
  `uidmap` and the SSH key.
- [x] **3. Add a `git clone` step to the Quick start.**
- [x] **4. Tell users how the launcher changes the host.** The README section
  "Changes to the host" lists the TAP device, `ip_forward`, the nftables
  table, and the Docker and ufw rules. The ufw rules persist.

### Should do

- [x] **5. Remove the legacy qcow2 tasks.** `isolate.snapshot`,
  `isolate.sync` and `isolate.image` used a private sandbox path.
- [x] **6. Move personal notes out of the public files.** `AGENTS.md` keeps
  the project rules. The preferences of the maintainer and the private project
  names are in the git-ignored `CLAUDE.local.md`. The personal build settings
  are in the git-ignored `mise.local.toml`.
- [x] **7. Add `SECURITY.md`.** Tell people how to report a VM escape
  privately. Give the threat model: what isolate protects, and what it does
  not protect.
- [x] **8. Pin the host tool versions.** `mise/config.toml` used `latest` for
  Firecracker, firectl, podman, qdns and agent-ste. Now it pins the versions
  that `isolate.test` passed with, so that users get the same tools as the
  tests. It also adds shellcheck, because `isolate.check` skips that step
  without it.

### Before the first push

- [x] Replace `<owner>` in the `git clone` URL in the README (`soulstrop`).
- [x] Enable private vulnerability reporting in the repository settings
  (Security, then Private vulnerability reporting). `SECURITY.md` tells
  people to use it.

### Nice to have

- [ ] A GitHub Actions workflow that runs `mise run isolate.check`. It needs
  no KVM. `isolate.test` stays local.
- [ ] `CONTRIBUTING.md` that points to `AGENTS.md` and
  `docs/development.md`, and issue templates.
- [ ] A short demo (asciinema or GIF) of a session and the review prompt.

## Open questions

- Which backlog item to do first. The Ollama API restriction is the one open
  security concern.
- Video and audio in the guest: what is the use case (see the backlog item)?
- Whether to link the roadmap from the README.

## Backlog

Do not start an item without the approval of the maintainer.

### Restrict the guest's access to the host Ollama API

**Problem.** lumen needs an embedding server, so a project can open
`host:11434` (see [lumen and Ollama](../architecture.md#plugins)). This
gives the guest the full Ollama API, not only embeddings. So an agent in
the guest can change the shared model store of the host:

- `/api/create` or `/api/copy` can replace a model under an existing name,
  such as `ordis/jina-embeddings-v2-base-code`. Each project and host tool
  that uses that model then gets the replacement. This is cache poisoning.
- `/api/delete` removes models.
- `/api/pull` fills the disk with models.
- `/api/push` sends a model to a registry, which is a path to send data
  out.

**Fix.** Put a small filter proxy on the host side of the VM link, on
`172.16.0.1:11434`. It sends the requests to an Ollama that listens only on
localhost. It lets through only what lumen needs:

| Method | Path |
| ------ | ---- |
| `POST` | `/api/embed` |
| `GET`  | `/api/tags` |
| `POST` | `/api/show` |
| `GET`  | `/api/version` |

It answers all other requests with 403.

**Done when:**

- The guest keeps `OLLAMA_HOST=http://172.16.0.1:11434` without change, and
  lumen indexes and searches through the proxy.
- From the guest, `/api/create`, `/api/copy`, `/api/delete`, `/api/pull` and
  `/api/push` return 403, and the model list of the host does not change.
- The host Ollama does not have to listen on the VM link or on `0.0.0.0`.
- `docs/architecture.md` (lumen and Ollama) and `docs/troubleshooting.md`
  describe the proxy and the remaining exposure. The guest can still call
  the embedding model and list the models.

### Share host mise installs with the guest, read-only

**Problem.** A `mise install` or `mise up` in the guest downloads each tool
again, also when the host has the same version. For large tools such as
ollama (4.8G on the host), each project loses time and disk space.

**Fix.** Build `~/.local/share/isolate/host-tools.ext4` on the host from an
allowlist (for example `ISOLATE_HOST_TOOLS="ollama"`). Copy the directories
of those tools from `~/.local/share/mise/installs`. Keep the relative
`latest` and version-prefix symlinks. Share the disk across projects, and
build it again when the host versions change. Attach it read-only
(Firecracker `is_read_only: true`, QEMU `readonly=on`), mount it `ro` at
`/opt/host-mise`, and set `MISE_SHARED_INSTALL_DIRS=/opt/host-mise/installs`.
mise then shows those versions as `(shared)` and does not download them.

**Safety.** The VMM enforces the read-only flag, so even root in the guest
cannot write to the disk. The guest never sees the real install directory of
the host, and nothing comes back to the host. A `mise up` in the guest
installs into the throwaway disk of the guest. Possible hardening: build the
image from a new `mise install` instead of the live directory, and verify it
against `mise.lock`.

**Done when:**

- A guest `mise ls ollama` shows the host versions as `(shared)`, and
  `mise install` does not download them.
- A write under `/opt/host-mise` fails, also as root.
- After a host `mise up`, a new session shows the new version.
- AppArmor lets the VMM open the image, and `docs/architecture.md` describes
  the disk.

### Refresh the guest's apt packages

**Problem.** podman builds the apt layer of the image with `--pull=missing`
and keeps it in its cache. Nothing makes this layer invalid.
`TOOLS_STAMP` causes a new build of the mise layer only. So the apt
packages (jq, for example) never get bug or security fixes after the first
build.

**Fix options:**

- Add an `APT_STAMP` build argument to the apt layer, and let
  `isolate.build` set it (for example to the week, or with a flag on
  request). The build then makes the layer again and upgrades the packages.
- Move tools that change frequently, such as jq, from apt to mise. Then the
  existing `TOOLS_STAMP` refresh includes them.

**Done when:** after the stamp changes, a new build gets a newer package
version. With the same stamp, the build uses the layer from the cache.

### Size the serial console to the host terminal

**Problem.** The VM console is a serial console, so the guest uses 80×24,
whatever the size of the host window is. Full-screen tools such as Claude
show in a small area, and they do not follow a change of the window size.
`ssh isolate` prevents this problem, but it needs the network.

**Fix.** The launcher puts the rows and columns of the host terminal on the
kernel command line. At console login, the guest sets them with `stty rows
… cols …`. Add a guest command that sets the size again after a resize (for
example, a command that reads the size with an escape-sequence query).

**Done when:** at launch, Claude on the console fills the host window. After
a resize, the new command corrects the size. Both work under Firecracker and
QEMU.

### Video and audio in the guest (needs a use case)

**Problem.** The guest has no display or sound. Firecracker has no such
devices. QEMU has `virtio-gpu-device` and `virtio-sound-device`, but the
guest has no drivers for them.

**Possible approach (QEMU only):**

- Copy the matching modules of the host kernel (`virtio-gpu`, `snd-virtio`)
  into the guest, and update them after each kernel upgrade.
- Add launcher arguments such as `-device virtio-gpu-device -display gtk`
  and `-audiodev pipewire,id=a -device virtio-sound-device,audiodev=a`.
- Let the AppArmor profile of QEMU get access to the Wayland and PipeWire
  sockets.

**Isolation costs.** QEMU gets a connection to the desktop session. So,
if an attack from the guest uses a QEMU bug, the attack gets to the desktop
session. Enable playback only. Capture lets the agent listen to the room.
No USB passthrough, and never X11 forwarding.

**Next step.** Decide what it is for (to watch a UI under test, to play
audio output, or something different). A headless option, such as a virtual
framebuffer with screenshots, can be enough and keeps the isolation.
