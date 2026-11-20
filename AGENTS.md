# AGENTS.md

Instructions for coding agents that work on isolate. Read this file first.
Then read the file in the table below that matches your task.

## What isolate is

`mise run isolate.fc` (Firecracker) or `mise run isolate.qemu` (QEMU
microvm) boots the current git repo in a disposable microVM. A coding agent
(Claude Code, codex, pi, opencode, agy) can then work on the repo, but it
cannot touch the workstation. The host shares nothing with the guest. The
repo goes in as a copy on a disk image.

The work comes back only as a git bundle. The launcher fetches the bundle
into `refs/remotes/isolate/*` and shows a review prompt (`[d]iff [m]erge
[s]quash [q]uit`). `mise run isolate.build` builds the guest image from
`image/Containerfile` with podman. It writes the image to
`~/.local/share/isolate/rootfs.ext4`.

## Where to read

| Task | Read |
| ---- | ---- |
| Use isolate, or explain it to the user | [README.md](README.md) |
| Change how isolate works (disks, boot, network, image, import) | [docs/architecture.md](docs/architecture.md) |
| Diagnose a failure | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Build, test, drive a launch, inspect disks, known traps | [docs/development.md](docs/development.md) |
| Current state, open questions, next work | [docs/roadmap/roadmap.md](docs/roadmap/roadmap.md) |

## Rules (do not break)

Security is the purpose of the project. These rules come from the maintainer.

- **Do not read secrets.** Do not open
  `~/.config/mise/github_tokens.toml`, `mise/github_tokens.toml`,
  `~/.claude/.credentials.json`, podman or docker auth files, or other
  credential files. Refer to them by path only. For `~/.claude.json`, list
  the key names only. You can also read the onboarding and hint flag values
  that the seed uses.
- **No secrets in the guest image.** The GitHub token is a build secret. The
  build mounts it for one `RUN` step only, and then it searches the image for
  the token. Keep both steps.
- **Host to guest is copies only.** No bind mounts, 9p or virtiofs. Only the
  git bundle comes back. The host-side copy of the session logs is the one
  exception, and it must never include `auth.json`, `.credentials.json` or
  similar files.
- **The guest must not write to anything that the host keeps.** This
  includes tool installs, model stores and caches that more than one project
  shares. All shared data is read-only, and the VMM enforces this, not the
  guest. See the Ollama item in the roadmap for an open case.
- **Do not send personal data anywhere.** This includes email addresses,
  names and the paths of private projects.
- **Ask before outward-facing actions or actions that are hard to reverse.**
  Also ask before you start work that the person you work for did not
  approve. Do not start a roadmap item without approval.

## Personal preferences

Put your own preferences for agents in `CLAUDE.local.md` (Claude Code reads
it automatically) or in a different file that git ignores. Do not put them in
this file.

## Change discipline

- The repo has a short git history. Commit only when the user asks. Look at
  a file before you overwrite it, and keep edits small.
- Keep the docs in step with the code. The table below shows which documents
  to update after a change.
- After each change, run `mise run isolate.check`. After a change to the
  launcher, the image or the guest scripts, also run `mise run isolate.test`
  (see [docs/development.md](docs/development.md#tests)).

| When you change | Also update |
| --------------- | ----------- |
| Behavior that the user sees (tasks, variables, prompts) | `README.md` and `docs/architecture.md` |
| A new failure mode or error message | The symptom table in `docs/troubleshooting.md` |
| Build, test or development steps, or a new trap | `docs/development.md` |
| A completed item, or a new item or question | `docs/roadmap/roadmap.md` |
| A project rule | This file |
| A file in the repository layout | The layout in `README.md` |

## Writing the docs

- Write plain markdown with relative links. `mise/scripts/build-docs` renders
  the docs to HTML and PDF.
- Write prose in ASD-STE100 Simplified Technical English. `mise run
  isolate.check` runs `ste-lint` on each markdown file, and a hard violation
  fails the check. The main rules are: no contractions and no semicolons. A
  sentence has a maximum of 25 words (20 in an instruction). Use the active
  voice when you know the actor.
- When you correct the style, do not change the meaning.
- When a rule reports text that is correct, silence that rule on that line
  only. Put `<!-- ste-disable-next-line <rule> -->` on the line before it.
  To change the severity of a rule for the whole repo, add a `.ste.json` file
  in the root of the repo (see the `agent-ste` README).
