# fish completion for runroot(1) -- run0-style delegation.
#
# runroot has almost no options of its own (-h/-H/--help, --check, --);
# everything else is COMMAND [ARGS...] to run as root, so we complete the
# target command and its arguments via __fish_complete_subcommand,
# like run0's `complete -c run0 -xa "(__fish_complete_subcommand)"` does.
#
# Install:
#   copy/symlink to ~/.config/fish/completions/runroot.fish
#   (or system-wide to /usr/share/fish/vendor_completions.d/).
#   No shell restart needed beyond loading the file once.

# Strip the `runroot' prefix (and one leading `--' separator, if present)
# and complete what remains as an independent command line. sbin dirs are
# added like sudo does, since the command runs as root.
function __fish_complete_runroot_subcommand
    set -l tokens (commandline -xpc | string escape) (commandline -ct)
    set -e tokens[1]
    if test "$tokens[1]" = '--'
        set -e tokens[1]
    end
    set -lx -a PATH /usr/local/sbin /sbin /usr/sbin
    __fish_complete_subcommand --commandline $tokens
end

# runroot's own flags are only valid as the first argument (anything else
# is already the command, cf. bin/runroot `_parse_arguments'), so offer
# them only while no non-option argument has been given yet. They are
# terminal: after -h/--help/--check there is nothing to complete, hence
# the subcommand completion below is suppressed once they are seen.
complete -c runroot -n __fish_no_arguments -s h -s H -l help -d "Show help and exit"
complete -c runroot -n __fish_no_arguments -l check -d "Check privilege escalation works"

# Delegate: `runroot <TAB>` lists commands, `runroot apt <TAB>` completes apt.
complete -c runroot -x -n 'not __fish_seen_argument -s h -s H -l help -l check' -a "(__fish_complete_runroot_subcommand)"
