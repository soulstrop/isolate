#!/usr/bin/fish
# Build the isolate guest root filesystem:
#   image/Containerfile --podman build--> localhost/isolate-guest
#                       --mkfs.ext4 -d--> ~/.local/share/isolate/rootfs.ext4
#
# Rootless throughout. The ext4 is written inside `podman unshare` so files the
# image owns as root stay root-owned in the filesystem.
#
# Env: ISOLATE_SSH_PUBKEY  public key allowed to ssh in (default ~/.ssh/id_ed25519.pub)
#      ISOLATE_AUTHFILE    registry auth file for the base image pull. Default:
#                          anonymous, because Docker Hub rejects stale stored logins.
#      ISOLATE_DOTFILES    stow-style dotfiles dir to copy into the guest home
#                          (default: unset, no dotfiles are copied)
#      ISOLATE_DOTFILE_PKGS  packages copied from it
#                          (default: fish starship tmux claude)
#      ISOLATE_DOTFILE_EXCLUDE  extra rsync exclude patterns, space-separated
#      ISOLATE_MISE        mise binary for the guest (default: the host's)
#      ISOLATE_REFRESH=1   re-resolve "latest" tool versions now (otherwise the
#                          tool layer is reused until the next day's first build)
#
# Secrets: the GitHub token mise uses on the host (`mise token github`) is
# passed as a podman build secret for `mise install` only; the build fails if
# it turns up anywhere in the image. Dotfiles are opt-in, an allowlist with
# common secret-bearing files excluded; Claude settings are a filtered subset.

set -l here (path resolve (status dirname))
set -l imgdir (path resolve $here/../../image)
set -l state $HOME/.local/share/isolate
set -l tag localhost/isolate-guest:latest
set -l out $state/rootfs.ext4

mkdir -p $state/tmp
or exit 1
# Podman stages layer blobs in $TMPDIR; a tmpfs one (/run/user/...) is far too
# small for this image.
set -gx TMPDIR $state/tmp

set -l pubkey $HOME/.ssh/id_ed25519.pub
set -q ISOLATE_SSH_PUBKEY; and set pubkey $ISOLATE_SSH_PUBKEY
if not test -r $pubkey
    echo "isolate.build: no public key at $pubkey (set ISOLATE_SSH_PUBKEY)" >&2
    exit 1
end

# Build context = image/ plus the public key. Built in a temp dir so the key
# never lands in the source tree.
set -l ctx (mktemp -d)
set -l secrets (mktemp -d)
function _cleanup --on-event fish_exit --inherit-variable ctx --inherit-variable secrets
    rm -rf $ctx $secrets
end
cp -a $imgdir/. $ctx/
or exit 1
cp $pubkey $ctx/authorized_keys

# mise: the host's binary, so the guest resolves tools exactly as the host does.
set -l mise_bin (command -s mise)
set -q ISOLATE_MISE; and set mise_bin $ISOLATE_MISE
if test -z "$mise_bin"; or string match -q '*/mise/shims/*' -- $mise_bin
    echo "isolate.build: no mise binary found (set ISOLATE_MISE)" >&2
    exit 1
end
cp (path resolve $mise_bin) $ctx/mise-bin; and chmod 0755 $ctx/mise-bin
or exit 1

# Dotfiles: opt-in. Nothing is copied unless ISOLATE_DOTFILES is set, because
# only you know which of your files hold secrets. Allowlisted stow packages are
# flattened into one home tree. Always excluded: fish universal variables (can
# hold secrets), your host config.fish (the guest has its own), common
# credential files and editor/backup leftovers. Add your own patterns (API-key
# functions, host-only conf.d snippets) with ISOLATE_DOTFILE_EXCLUDE.
mkdir -p $ctx/dotfiles
if set -q ISOLATE_DOTFILES
    set -l dotdir (path resolve $ISOLATE_DOTFILES)
    if not test -d $dotdir
        echo "isolate.build: ISOLATE_DOTFILES=$ISOLATE_DOTFILES is not a directory" >&2
        exit 1
    end
    set -l pkgs fish starship tmux claude
    set -q ISOLATE_DOTFILE_PKGS; and set pkgs (string split -n ' ' -- $ISOLATE_DOTFILE_PKGS)
    set -l excludes --exclude=.git --exclude='*~' --exclude='*.bak' --exclude='#*#' \
        --exclude=fish_variables --exclude=/.config/fish/config.fish \
        --exclude=.credentials.json --exclude=auth.json --exclude='*.pem' --exclude='*.key' \
        --exclude='id_*' --exclude='.env*' --exclude='.netrc' --exclude='*token*' --exclude='*secret*'
    for pat in (string split -n ' ' -- "$ISOLATE_DOTFILE_EXCLUDE")
        set -a excludes --exclude=$pat
    end
    for pkg in $pkgs
        if not test -d $dotdir/$pkg
            echo "isolate.build: no dotfiles package $dotdir/$pkg, skipping" >&2
            continue
        end
        echo "==> dotfiles: $dotdir/$pkg"
        rsync -rL --chmod=u+rwX,go-w $excludes $dotdir/$pkg/ $ctx/dotfiles/
        or exit 1
    end
end

# Claude seed for /persist/claude.
# settings.json: portable keys from the host (autoCompact*, permissions,
# statusLine, the statusline script re-pointed at the dotfiles copy), overlaid
# with image/claude/settings.json (the guest's autoMode description). Host
# hooks, plugins, marketplaces and autoMode notes are never copied; the image's
# own plugins (image/claude/plugins) are added by the Containerfile.
# .claude.json: onboarding and hint flags only, so Claude starts without the
# setup wizard; plus folder trust for /workspace. No account or machine ids.
mkdir -p $ctx/claude-seed
set -l host_settings $HOME/.claude/settings.json
test -r $host_settings; or set host_settings /dev/null
set -l sl ''
test -f $ctx/dotfiles/.claude/statusline-command.sh
and set sl 'bash /home/agent-user/.claude/statusline-command.sh'
jq -n --arg sl $sl --slurpfile guest $imgdir/claude/settings.json '
    (input? // {})
    | {autoCompactEnabled, autoCompactWindow, permissions, statusLine}
    | with_entries(select(.value != null))
    | if $sl == "" then del(.statusLine)
      else .statusLine = ((.statusLine // {type: "command"}) + {command: $sl}) end
    | . * $guest[0]
' $host_settings >$ctx/claude-seed/settings.json
or exit 1
set -l host_state $HOME/.claude.json
test -r $host_state; or set host_state /dev/null
jq -n '
    (input? // {})
    | {hasCompletedOnboarding, lastOnboardingVersion, theme, hasSeenTasksHint,
       effortCalloutV2Dismissed, hasSeenAutoModeEntryWarning}
    | with_entries(select(.value != null))
    | .hasCompletedOnboarding = true
    | .projects = {"/workspace": {hasTrustDialogAccepted: true}}
' $host_state >$ctx/claude-seed/.claude.json
or exit 1
test -s $HOME/.claude/CLAUDE.md; and cp $HOME/.claude/CLAUDE.md $ctx/claude-seed/

# GitHub token for `mise install`, outside the build context.
set -l token $secrets/github_token
timeout 30 mise token github --raw </dev/null >$token 2>/dev/null
or : >$token
test -s $token
or echo "isolate.build: no GitHub token from mise; installing anonymously (rate limits apply)" >&2

set -l auth $ctx/.noauth.json
echo '{}' >$auth
set -q ISOLATE_AUTHFILE; and set auth $ISOLATE_AUTHFILE

set -l tools_stamp (date +%F)
set -q ISOLATE_REFRESH; and set tools_stamp (date +%s)

echo "==> podman build ($tag)"
podman build --authfile $auth --pull=missing \
    --secret id=github_token,src=$token \
    --build-arg AGENT_UID=(id -u) --build-arg AGENT_GID=(id -g) \
    --build-arg TOOLS_STAMP=$tools_stamp \
    -f $ctx/Containerfile -t $tag $ctx
or begin
    echo "isolate.build: podman build failed" >&2
    exit 1
end

if test -s $token
    echo "==> checking the image for the GitHub token"
    set -l leaks (podman unshare sh -euc '
        mnt=$(podman image mount "$1")
        trap "podman image umount \"$1\" >/dev/null" EXIT
        grep -rlsF -f "$2" "$mnt/home" "$mnt/root" "$mnt/etc" "$mnt/tmp" "$mnt/var" "$mnt/usr/local" || true
    ' sh $tag $token)
    if test -n "$leaks"
        echo "isolate.build: GitHub token found in the image, refusing to continue:" >&2
        printf '    %s\n' $leaks >&2
        exit 1
    end
end

echo "==> writing $out"
# Size: image contents + 20% + 8G headroom for the session (apt installs etc.).
# The file is sparse, so the headroom costs nothing until used.
podman unshare sh -euc '
    tag=$1; out=$2
    mnt=$(podman image mount "$tag")
    trap "podman image umount \"$tag\" >/dev/null" EXIT
    used=$(du -sxm "$mnt" | cut -f1)
    size=$(( used * 12 / 10 + 8192 ))
    rm -f "$out.tmp"
    truncate -s "${size}M" "$out.tmp"
    mkfs.ext4 -q -F -L isolate-root -E lazy_itable_init=1 -d "$mnt" "$out.tmp"
    mv "$out.tmp" "$out"
    echo "    ${used}M of files in a ${size}M filesystem"
' sh $tag $out
or begin
    echo "isolate.build: making the ext4 filesystem failed" >&2
    exit 1
end

# Sanity check: root-owned system files and the agent's home.
set -l owner (debugfs -R 'stat /usr/bin/sudo' $out 2>/dev/null | string match -rg 'User:\s+(\d+)')
set -l agent (debugfs -R 'stat /home/agent-user' $out 2>/dev/null | string match -rg 'User:\s+(\d+)')
if test "$owner" != 0 -o "$agent" != (id -u)
    echo "isolate.build: ownership looks wrong (sudo uid=$owner, home uid=$agent)" >&2
    exit 1
end
# Pin the guest's host key for ssh/TRAMP (Host isolate in ~/.ssh/config uses
# this file). Regenerated with every build, so the old key never lingers.
set -l hostkey (debugfs -R 'cat /etc/ssh/ssh_host_ed25519_key.pub' $out 2>/dev/null | string match -r '^ssh-ed25519 \S+')
if test -z "$hostkey"
    echo "isolate.build: could not read the guest ssh host key" >&2
    exit 1
end
echo "172.16.0.2 $hostkey" >$state/known_hosts

echo "==> done: $out"
echo "    Sessions start from a fresh copy of this file; rebuild any time."
