# Why isolate exists

isolate is a response to a survey of sandboxes for AI agents, [Sandboxes
for AI](https://www.luiscardoso.dev/blog/sandboxes-for-ai) by Luis Cardoso
(January 2026). This document gives the main points of the survey. Then it
shows how each design choice of isolate answers one of those points. It also
tells where isolate does not yet follow the advice of the survey.

For how the parts work, see [architecture.md](architecture.md). For the
threat model in short form, see [SECURITY.md](../SECURITY.md).

## The argument of the survey

### "Sandbox" means four different things

| Type | Where the isolation is | What you must trust |
| ---- | ---------------------- | ------------------- |
| Container | Namespaces on the host kernel. A kernel bug in any syscall is a host bug. | The host kernel |
| gVisor | A userspace kernel (the Sentry) handles the syscalls first. It uses a small allowlist of host syscalls. | The userspace kernel |
| MicroVM | A guest kernel on hardware virtualization. The host sees only KVM ioctls and virtio device I/O. | The guest kernel and the VMM |
| Wasm or isolates | A runtime. The code has no syscall ABI and gets only the host APIs that you give it. | The runtime and the embedder |

Containers were the default answer because they held *trusted* code. Code
that an AI agent writes or downloads is not trusted. Prompt injection,
dependency confusion and supply chain attacks are the reasons. The survey
says that "Our code is trusted" is a common mistake.

### Three decisions, three questions

The survey separates a sandbox into three decisions:

1. **Boundary:** where the isolation is. This is the line that you bet an
   attacker cannot cross.
2. **Policy:** what the code can touch inside the boundary. This includes
   files, network, processes, devices, quotas and the interface surface. A
   tight policy on a weak boundary gives a weak sandbox. A strong boundary
   with a loose policy is a missed opportunity.
3. **Lifecycle:** what persists between runs. This can be a fresh run, a
   workspace or a snapshot.

From these, it gets three questions. You understand a sandbox only when you
can answer all three:

- What is shared between the code and the host?
- What can the code touch?
- What survives between runs?

### The threat for agents is a policy failure

A kernel escape is not the usual problem of an agent sandbox. The usual
problem is a policy failure:

- A sandbox that can read a repo and connect out can leak the repo.
- A sandbox that can read `~/.aws` or a host mount can leak credentials.
- A sandbox that can get to internal services becomes a tool for lateral
  movement.

So an agent sandbox needs explicit capability design, and a plan to control
the blast radius when the agent goes bad.

The survey also warns about the common container pitfalls. These are
`--privileged`, a mounted Docker socket, writable host mounts, broad
capabilities, host namespaces and raw device passthrough. It also warns that
"We will just block the network" is not enough. A network rule is policy, not
a boundary.

### A minimum viable policy and a rule of thumb

The minimum policy of the survey is:

- Deny outbound traffic by default, then allow a list.
- No long-lived credentials in the sandbox. Use short-lived tokens with a
  narrow scope.
- Access to the workspace only, and only explicit host mounts.
- Limits on CPU, memory, disk, time and processes.
- Logs of the process tree, the network egress and the failures.

The rule of thumb is: when the code needs a shell and package managers, and
you do not fully trust it, start at a microVM.

## How isolate answers

isolate runs a coding agent on a developer workstation. The agent has a
shell and package managers, and it reads web pages and dependencies that
anyone can write. The rule of thumb applies directly.

### Boundary: a microVM, not a container

isolate boots each session under Firecracker or the QEMU `microvm` machine.
The guest has its own kernel. The host kernel sees KVM ioctls and three
virtio devices (block, network and console), not the syscalls of the agent.

For a self-hosted agent, the table in the survey suggests a hardened
container or gVisor. It calls such an agent "semi-trusted". isolate does not
accept that label. One prompt injection in a README or an issue makes the
agent hostile, and the agent then runs that code with a full shell. So
isolate uses the boundary that the survey recommends for hostile code.

The trusted part is the guest kernel and the VMM. isolate makes the VMM a
smaller risk with the AppArmor profile `apparmor/isolate-vm`. If an attack
gets out of the guest into the VMM, the profile gives it no network sockets.
It also gives no access to your home directory, other than the disk images
and kernel copies of isolate.

The image is an OCI image that podman builds. But the build flattens it into
an ext4 filesystem, and nothing runs as a container. The container format is
only a convenient way to make a root filesystem. So the container pitfalls
are not present. There is no privileged mode, no Docker socket, no host
namespace and no device passthrough.

### Policy: explicit capabilities

| Policy area | What isolate does |
| ----------- | ----------------- |
| Filesystem | The guest gets a *copy* of the repo on a disk image. There are no bind mounts, no 9p and no virtiofs. Ignored files, such as `.env`, stay on the host. |
| Host and LAN | The firewall drops all guest traffic to the host and to private, loopback, link-local, CGNAT and multicast ranges, and all IPv6. `ISOLATE_ALLOW` opens one `host:PORT` at a time. |
| Internet | Open by default. `ISOLATE_NET=none` removes the network device. See [Gaps](#gaps-and-next-work). |
| Credentials | The image has no secrets. The GitHub token of the build is a build secret for one step, and the build then searches the image for it. Only your public ssh key goes in, with no agent forwarding. |
| Shared data | Data that more than one project uses must be read-only, and the VMM, not the guest, enforces this. |
| Devices | Block, network and console only. No GPU, no USB, no display and no sound. |
| Quotas | The memory and the vCPUs of the VM do not change during a session (`ISOLATE_MEM`, default 4096 MiB, and `ISOLATE_CPUS`, default 2). The cache disk has a fixed size (`ISOLATE_CACHE_SIZE`). |
| Observability | After each session, the launcher copies the agent transcripts and the shell history to the host, without the credential files. |

The answers to the three examples of a policy failure are:

- **Leak the repo:** possible, because the internet is open. This is the
  largest gap (see below).
- **Leak credentials:** the guest has no host credentials to leak. There is
  no `~/.aws`, no `~/.ssh` private key, no ssh agent and no host mount.
- **Lateral movement:** the firewall blocks the host, the LAN and the
  private ranges. Only the ports that you name in `ISOLATE_ALLOW` are open.

isolate does not use the network as the boundary. The microVM is the
boundary, and the firewall is policy on top of it.

### Lifecycle: a throwaway system and a workspace for each project

isolate uses two lifecycles at the same time:

- **Fresh run:** the root disk is a new copy of the image at each launch.
  The `/workspace` disk is a new copy of the repo at each launch. A tool
  that the agent installs system-wide is gone the next time.
- **Workspace:** each project has one persistent disk, `cache.ext4` at
  `/persist`. It holds package caches, agent logins, transcripts and shell
  history.

The survey says that a workspace is "great for agents" but "dangerous if
secrets leak or persistence is abused". It also says that a workspace needs
a policy for secrets. isolate limits the risk in these ways:

- Each project has its own cache disk. An agent in one project cannot see
  the logins or caches of a different project.
- The host never mounts the cache disk. The launcher reads the logs from it
  with `debugfs`, and it does not copy the credential files.
- To reset a project, delete its `cache.ext4`.

isolate does not use snapshots.

### The way back: a git bundle and a human review

The survey looks mostly at what the code can touch. For a coding agent, the
output is also a risk, because you run that code on your machine later. A
shared folder would give the guest a live channel to write into your
filesystem, for example into `.git/hooks`.

So the only thing that comes back is a git bundle. It is one inert file. The
import checks its objects with fsck and puts them under
`refs/remotes/isolate/*`, which your checkout does not use. Nothing runs
until you merge. The review prompt names the changed files that can run code
after a merge, such as CI configuration, `.envrc`, hook managers, task
runners and package manifests.

This is the control of the blast radius. The agent can damage only its own
VM. Its work gets to you the same way as a pull request from a stranger.

## The three questions for isolate

**What is shared between the code and the host?**

- A copy of the host kernel image. The guest runs its own instance of it
  behind KVM.
- The KVM and virtio interface of the VMM, which AppArmor confines.
- A TAP link with a firewall, and the ports in `ISOLATE_ALLOW`.
- No files. All files go in as copies.

**What can the code touch?**

- A copy of the repo, without the ignored files.
- Its own three disks.
- The public internet, unless `ISOLATE_NET=none` is set.
- The host and LAN ports that you allow.

**What survives between runs?**

- The cache disk of the project: logins, caches and history.
- The commits and the uncommitted work, as a git bundle, after you review
  them.
- A host copy of the session logs, without credentials.

## Gaps and next work

isolate does not yet meet all of the minimum policy of the survey. These are
the known gaps:

- **Outbound traffic is open.** An agent can send the repo to any host. The
  [domain allowlist](roadmap/roadmap.md#limit-the-internet-access-of-the-guest-to-an-allowlist-of-domains)
  item in the roadmap adds a default-deny mode with a CONNECT proxy. Even then, the agent API
  stays a path out.
- **Agent logins are long-lived credentials in the sandbox.** They persist
  on the cache disk, because a new login for each session is not practical.
  This is a trade-off for the workspace lifecycle. Use tokens with a narrow
  scope when an agent needs access to a different service.
- **An allowed host port can give too much.** A port for Ollama gives the
  full Ollama API, which can change the shared model store of the host. The
  [Ollama](roadmap/roadmap.md#restrict-the-guests-access-to-the-host-ollama-api)
  item in the roadmap adds a filter proxy.
- **The logs are not complete.** isolate keeps transcripts and shell
  history. It does not log the process tree or the network egress.
- **There are no time limits.** A session runs until you stop it.

The local tools in the survey, such as macOS Seatbelt, Linux Landlock with
seccomp, and Windows AppContainer, need no privileges. But they all share the
host kernel, so they do not protect against a kernel bug. The design of
isolate accepts the cost of a VM to get a boundary that does not share the
kernel.
