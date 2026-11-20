# Session environment for bash login shells (the agent's shell is fish; see
# /etc/fish/conf.d/isolate.fish). Shared variables live in /etc/isolate/env.
set -a
. /etc/isolate/env
set +a
# mise shims make image and project tools visible to non-interactive commands.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/persist/npm-global/bin:/persist/cargo/bin:/persist/go/bin:$PATH"

if [ "$(id -u)" != 0 ] && [ -z "${ISOLATE_GREETED:-}" ] && [ -t 1 ] && [ "${TERM:-}" != dumb ]; then
  export ISOLATE_GREETED=1
  [ -d /workspace/.git ] && cd /workspace
  echo "isolate: project is in /workspace. Run 'isolate-done' to save your work and shut down."
fi
