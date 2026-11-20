# Security policy

isolate is a security tool. It runs coding agents and untrusted code in a
disposable microVM, so that they cannot touch the host. A bug that lets the
guest get through that boundary is a security vulnerability. I value the work
of security researchers, and I want to fix these bugs quickly.

## Report a vulnerability

Do not open a public issue for a vulnerability.

Use the private vulnerability reporting of GitHub. On the repository page,
go to **Security**, then **Report a vulnerability**. Only the maintainer can
read the report.

Give this data in the report:

- The isolate commit, the VMM (`isolate.fc` or `isolate.qemu`), the host
  distribution and the host kernel version.
- Whether the host had the AppArmor profile `isolate-vm`.
- The steps to reproduce the problem, and a proof of concept.
- The effect: what the guest could read, write or execute on the host.

I will reply to a report within 7 days. I will tell you when I have a fix.
I will give you credit in the advisory, unless you do not want it.

## Supported versions

Only the newest commit on `main` gets security fixes. isolate has no
releases yet.

## Threat model

isolate assumes that all code in the guest is hostile. This includes the
agent, the dependencies of the project and the repo itself.

### What isolate protects

- **The host filesystem.** The guest gets copies on disk images only. It has
  no bind mounts, 9p or virtiofs. The guest must not read or write a host
  file that it did not get as a copy.
- **Data that the host keeps.** The guest must not write to tool installs,
  model stores or caches that more than one project shares. The VMM enforces
  this, not the guest.
- **Secrets.** The guest image must not contain a secret. The GitHub token of
  the build must not get into the image. The host copy of the session logs
  must not contain agent credential files.
- **The host and the LAN on the network.** The guest gets the public internet
  only. It must not get to the host, the LAN or private address ranges,
  unless you open a port with `ISOLATE_ALLOW`.
- **The import of the work.** The work comes back only as a git bundle. The
  launcher fetches it with object checks into `refs/remotes/isolate/*`.
  Nothing from the guest executes on the host before you merge. The review
  step flags files that can execute after a merge, and suspicious Unicode.
- **The VMM.** With the AppArmor profile, the VMM process can open only the
  files of the session.

### In scope

- A guest escape to the host through isolate, its VMM configuration or its
  AppArmor profile.
- A guest write to a file or a shared store that the host keeps.
- A bypass of the egress firewall to the host, the LAN or a private range.
- A secret in the built image, or a credential file in the host copy of the
  session logs.
- A bundle or a ref that executes code on the host during the import, or that
  writes outside `refs/remotes/isolate/*` and `refs/isolate-archive/*`.
- A change that the review step must flag but does not flag, for example a
  hidden change to a CI file or a git hook.

### Out of scope

- A vulnerability in Firecracker, QEMU, KVM or the Linux kernel. Report it to
  that project. If the configuration of isolate makes such a bug easier to
  exploit, it is in scope.
- What the guest can do with its own access, by design. The agent can read
  the repo copy and send it to the internet. It has root in the guest.
- Risks that you accept with an option: ports in `ISOLATE_ALLOW`, the
  dotfiles that you select, or an agent that runs with its permission checks
  off.
- Code that you merge after the review step showed it.
- A launch without the AppArmor profile, unless the bug is also present with
  the profile.
- Use of all of the resources of the host (CPU, disk, memory) by the guest.
- Theoretical vulnerabilities without a proof of concept.
- Reports about best practices that do not show a bypass of a protection
  above.

### Known limitations

- With `ISOLATE_ALLOW="host:11434"`, the guest gets the full Ollama API of the
  host, not only the embeddings that the lumen plugin needs. See the Ollama
  item in [the roadmap](docs/roadmap/roadmap.md).
- The guest boots a copy of the host kernel. So a kernel bug that the guest
  can use in the VM is often also present on the host.

For the full design, see [docs/architecture.md](docs/architecture.md).

## Safe harbor

If you make a good-faith effort to obey this policy during your research, I
consider that I authorized your research. I will not start a civil or
criminal action against you for activities that obey these guidelines.

## Guidelines

- Test only on computers that you own or that you have permission to use.
- Do not attack the systems of other persons, and do not cause service
  disruptions. This includes denial-of-service attacks.
- Do not get access to data that is not yours, and do not change or delete
  it.
- Give a detailed report with steps that reproduce the problem.
- Give me a reasonable time to fix the problem (usually 30 to 90 days) before
  you make it public.
