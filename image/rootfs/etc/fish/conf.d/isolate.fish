# Session environment for fish. conf.d snippets (system and ~/.config/fish/conf.d)
# run in filename order, all before config.fish.
# Shared variables live in /etc/isolate/env (also read by bash).
for line in (string match -rv '^\s*(#|$)' </etc/isolate/env)
    set -l kv (string split -m1 = -- $line)
    set -gx $kv[1] $kv[2]
end
fish_add_path -gP $HOME/.local/share/mise/shims $HOME/.local/bin \
    /persist/npm-global/bin /persist/cargo/bin /persist/go/bin

# TRAMP (and anything else with TERM=dumb) wants a plain, quiet shell.
if status is-interactive; and test "$TERM" != dumb
    mise activate fish | source
    if not set -q ISOLATE_GREETED
        set -gx ISOLATE_GREETED 1
        test -d /workspace/.git; and cd /workspace
        echo "isolate: project is in /workspace. Run 'isolate-done' to save your work and shut down."
    end
end
