# Bash completion for backrest.
# Source this file, or wire it up once with install.sh.
# zsh users: source backrest.zsh instead (it loads this file via bashcompinit).
# Profile names are derived live from backup.json (set BACKREST_CONFIG to override).

if [ -n "${ZSH_VERSION:-}" ]; then
    eval '_backrest_script="${(%):-%x}"'
else
    _backrest_script="${BASH_SOURCE[0]}"
fi
_backrest_dir="$(cd "$(dirname "$(readlink -f "$_backrest_script")")/.." && pwd)"

_backrest_config() {
    echo "${BACKREST_CONFIG:-$_backrest_dir/backup.json}"
}

_backrest_profiles() {
    local cfg filter="$1"
    cfg="$(_backrest_config)"
    [ -f "$cfg" ] || return 0
    if [ -n "$filter" ]; then
        jq -r --arg filter "$filter" \
            '.profiles | to_entries[] | select(.value.type == $filter) | .key' "$cfg" 2>/dev/null
    else
        jq -r '.profiles | keys[]' "$cfg" 2>/dev/null
    fi
}

_backrest_completion() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    case "$COMP_CWORD" in
        1) COMPREPLY=( $(compgen -W "run snapshots logs --help --dry-run --validate --no-validate --config --progress --follow" -- "$cur") ) ;;
        2)
            case "${COMP_WORDS[1]}" in
                snapshots)
                    COMPREPLY=( $(compgen -W "$(_backrest_profiles restic) $(_backrest_profiles sqlite)" -- "$cur") ) ;;
                *)
                    COMPREPLY=( $(compgen -W "$(_backrest_profiles)" -- "$cur") ) ;;
            esac ;;
    esac
}

complete -F _backrest_completion backrest
complete -F _backrest_completion ./backrest