# Contributing to isolate

Thank you for your help. isolate is a security tool, so a change must keep
the boundary between the guest and the host. This file tells you how to
report a problem and how to send a change.

## Security vulnerabilities

Do not open a public issue for a vulnerability. Read
[SECURITY.md](SECURITY.md) and use the private report form of GitHub.

## Report a bug

Open an issue with the **Bug report** form. Before you do this, look at
[docs/troubleshooting.md](docs/troubleshooting.md). Many failures have a
known cause there.

Give the isolate commit, the VMM and the host distribution. Also give the
part of the console log that shows the failure. Remove tokens, email
addresses and private paths before you paste a log.

## Suggest a feature

Open an issue with the **Feature request** form. Tell us the problem first,
then your proposal. Also tell us whether the change shares anything new
between the host and the guest. [The roadmap](docs/roadmap/roadmap.md)
shows the planned work and the open questions.

## Send a change

1. For a change that is larger than a small fix, open an issue first. Then
   we can agree on the approach before you write the code.
2. Read [AGENTS.md](AGENTS.md). Its rules apply to all contributors, also
   to persons. The most important rules are these:
   - The host shares copies only with the guest. No bind mounts, 9p or
     virtiofs.
   - The guest must not write to anything that the host keeps.
   - No secrets in the guest image or in the host copy of the session logs.
3. Set up the repo as the [README](README.md#quick-start) tells you. Then read
   [docs/development.md](docs/development.md).
4. Run `mise run isolate.check` after each change. CI runs it on each pull
   request.
5. After a change to the launcher, the image or the guest scripts, also run
   `mise run isolate.test`. CI cannot run it, because it needs KVM. Tell us in
   the pull request which VMMs you tested (`fc`, `qemu` or both).
6. Update the docs in the same pull request. The table in
   [AGENTS.md](AGENTS.md#change-discipline) shows which file to update.

Keep a pull request small and about one subject.

## Coding agents

You can use a coding agent to make a change. isolate exists for this
purpose. The agent must read [AGENTS.md](AGENTS.md) first. You are
responsible for the change, so read the full diff before you send it.

## Writing style

The docs use ASD-STE100 Simplified Technical English. `mise run
isolate.check` runs `ste-lint` on each markdown file. A hard violation fails
the check. The main rules are in [AGENTS.md](AGENTS.md#writing-the-docs).

## License

isolate uses the MIT license. When you send a change, you agree that it
uses the same license. See [LICENSE](LICENSE).
