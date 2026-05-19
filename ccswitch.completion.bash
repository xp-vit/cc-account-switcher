# ccswitch.completion.bash - Bash tab completion for ccswitch
# Add to ~/.bashrc or ~/.bash_completion:
#   source /path/to/ccswitch.completion.bash

_ccswitch_accounts() {
    local seq_file="$HOME/.claude-switch-backup/sequence.json"
    if [[ -f "$seq_file" ]]; then
        jq -r '.accounts | to_entries[] | "\(.key) \(.value.email)"' "$seq_file" 2>/dev/null \
            | awk '{print $1; print $2}'
    fi
}

_ccswitch_completion() {
    local cur prev opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--add-account --remove-account --list --usage --switch-best --switch --switch-to --help --install-completion"

    case "$prev" in
        --switch-to|--remove-account)
            local accounts
            accounts=$(_ccswitch_accounts)
            COMPREPLY=($(compgen -W "$accounts" -- "$cur"))
            ;;
        *)
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
    esac
}

complete -F _ccswitch_completion ccswitch.sh
complete -F _ccswitch_completion ccswitch
