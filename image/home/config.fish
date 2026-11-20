# Guest config.fish (your host one is host-specific, so it is not copied).
# Environment and mise activation come from /etc/fish/conf.d/isolate.fish.
set -gx EDITOR vim.tiny
set -gx VISUAL vim.tiny
set -g fish_greeting

if status is-interactive; and test "$TERM" != dumb
    set -gx GPG_TTY (tty)
    type -q starship; and starship init fish | source
end
