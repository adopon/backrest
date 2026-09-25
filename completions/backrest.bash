# Bash completion for backrest.
# Source this file, or wire it up once with install.sh.
# zsh users: source backrest.zsh instead (it loads this file via bashcompinit).
# Profiles are derived live from the config — resolution order:
#   1. --config on the command line
#   2. $BACKREST_CONFIG
#   3. backup.json next to the script
#   4. the only backup*.json (e.g. backup-laptop.json; example/schema
#      excluded). Multiple candidates -> no profiles (ambiguous).

if [ -n "${ZSH_VERSION:-}" ]; then
    eval '_backrest_script="${(%):-%x}"'
else
    _backrest_script="${BASH_SOURCE[0]}"
fi
_backrest_dir="$(cd "$(dirname "$(readlink -f "$_backrest_script")")/.." && pwd)"

_backrest_config() {
    local i
    for ((i=1; i < ${#COMP_WORDS[@]}; i++)); do
        if [[ "${COMP_WORDS[$((i-1))]}" == "--config" ]] && [[ -n "${COMP_WORDS[$i]}" ]]; then
            printf '%s\n' "${COMP_WORDS[$i]}"
            return 0
        fi
    done
    if [[ -n "${BACKREST_CONFIG:-}" ]]; then
        printf '%s\n' "$BACKREST_CONFIG"
        return 0
    fi
    if [[ -f "$_backrest_dir/backup.json" ]]; then
        printf '%s\n' "$_backrest_dir/backup.json"
        return 0
    fi
    local f
    local -a found=()
    for f in "$_backrest_dir"/backup-*.json "$_backrest_dir"/backup*.json; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *example*|*schema*) continue ;;
        esac
        [[ " ${found[*]} " == *" $f "* ]] && continue
        found+=("$f")
    done
    if [[ ${#found[@]} -eq 1 ]]; then
        printf '%s\n' "${found[0]}"
    fi
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

# Non-flag words typed so far, excluding --config values and the current word.
_backrest_tokens() {
    local i w
    local -a toks=()
    local skip=false
    for ((i=1; i < COMP_CWORD; i++)); do
        w="${COMP_WORDS[$i]}"
        if [[ "$skip" == true ]]; then
            skip=false
            continue
        fi
        case "$w" in
            --config) skip=true ;;
            --dry-run|--validate|--no-validate|--progress|--follow|-f|-h|--help) ;;
            *) toks+=("$w") ;;
        esac
    done
    printf '%s\n' "${toks[@]}"
}

_backrest_completion() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[$((COMP_CWORD-1))]}"

    if [[ "$prev" == "--config" ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null
        return
    fi

    local flags="--help --dry-run --validate --no-validate --config --progress --follow"
    local -a toks
    mapfile -t toks < <(_backrest_tokens)
    case "${#toks[@]}" in
        0)
            COMPREPLY=( $(compgen -W "run snapshots logs $flags $(_backrest_profiles)" -- "$cur") ) ;;
        1)
            if [[ "${toks[0]}" == "snapshots" ]]; then
                COMPREPLY=( $(compgen -W "$(_backrest_profiles restic) $(_backrest_profiles sqlite) $flags" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "$(_backrest_profiles) $flags" -- "$cur") )
            fi ;;
    esac
}

complete -F _backrest_completion backrest
complete -F _backrest_completion ./backrest