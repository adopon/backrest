# zsh entry point: load compinit + bashcompinit, then the shared bash completion.
# Source this file, or wire it up once with install.sh.

if ! type compdef >/dev/null 2>&1; then
    autoload -U +X compinit && compinit
fi
autoload -U +X bashcompinit && bashcompinit

_backrest_zsh_script="${(%):-%x}"
source "$(cd "$(dirname "$_backrest_zsh_script")" && pwd)/backrest.bash"