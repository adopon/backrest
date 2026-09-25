#!/bin/bash
# Shell integration for this repo: `backrest` on PATH and tab-completion with
# profile names derived live from backup.json.
# Idempotent; undo with --remove.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MARK_BEGIN="# >>> backrest shell integration >>>"
MARK_END="# <<< backrest shell integration <<<"
FISH_MARKER="# managed by backrest shell integration"

usage() {
    cat <<EOF
usage: install.sh [shell] [--remove]

Adds (or removes) a managed block that:
  - puts \`backrest\` on PATH
  - loads completions for backrest (actions + profile names from backup.json)

Supported shells: bash, zsh, fish (default: detect from \$SHELL).

  ./install.sh              # detect shell and install
  ./install.sh bash         # block in ~/.bashrc
  ./install.sh zsh          # block in ~/.zshrc (or \$ZDOTDIR/.zshrc)
  ./install.sh fish         # files in ~/.config/fish/{completions,functions}
  ./install.sh --remove     # remove for the selected/detected shell
EOF
}

shell=""
remove=0
for arg in "$@"; do
    case "$arg" in
        --remove|-r) remove=1 ;;
        bash|zsh|fish) shell="$arg" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$shell" ]; then
    shell="$(basename "${SHELL:-bash}")"
fi

case "$shell" in
    bash) rc="$HOME/.bashrc";             source_file="$REPO_DIR/completions/backrest.bash" ;;
    zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc";  source_file="$REPO_DIR/completions/backrest.zsh" ;;
    fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    *)    echo "unsupported shell: $shell (supported: bash, zsh, fish)" >&2; exit 1 ;;
esac

install_fish() {
    local fish_config="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
    local files=(backrest.fish)
    local cfg="$rc"

    if [ "$remove" -eq 1 ]; then
        local removed=0 f
        for f in "${files[@]}"; do
            if [ -f "$fish_config/completions/$f" ] && grep -qF "$FISH_MARKER" "$fish_config/completions/$f"; then
                rm -f "$fish_config/completions/$f"
                removed=1
            fi
        done
        if [ -f "$cfg" ] && grep -qF "$MARK_BEGIN" "$cfg"; then
            sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$cfg"
            removed=1
        fi
        if [ "$removed" -eq 1 ]; then
            echo "Removed fish integration from $fish_config"
        else
            echo "No managed fish integration found in $fish_config"
        fi
        return 0
    fi

    mkdir -p "$fish_config/completions"
    local f
    for f in "${files[@]}"; do
        sed "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/completions/fish/$f" > "$fish_config/completions/$f"
    done

    # fish only autoloads completions for commands it can resolve, so source the
    # file explicitly to cover invocations like ./backrest.
    [ -f "$cfg" ] || : > "$cfg"
    if grep -qF "$MARK_BEGIN" "$cfg"; then
        sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$cfg"
    fi
    {
        echo "$MARK_BEGIN"
        echo "if not contains \"$REPO_DIR\" \$PATH"
        echo "    set -gx PATH \"$REPO_DIR\" \$PATH"
        echo "end"
        echo "source \"$fish_config/completions/backrest.fish\""
        echo "$MARK_END"
    } >> "$cfg"

    echo "Installed fish integration in $fish_config (PATH + completions)"
    command -v fish >/dev/null || echo "note: fish is not in PATH; files were installed anyway"
    echo "Open a new fish session to pick it up."
}

if [ "$shell" = "fish" ]; then
    install_fish
    exit 0
fi

if [ ! -f "$rc" ]; then
    read -r -p "$rc does not exist. Create it? [y/N] " answer || answer=""
    case "$answer" in
        [Yy]*) : > "$rc" ;;
        *)     echo "aborted."; exit 1 ;;
    esac
fi

# Remove an existing managed block (if any)
found=0
if grep -qF "$MARK_BEGIN" "$rc"; then
    sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$rc"
    found=1
fi

if [ "$remove" -eq 1 ]; then
    if [ "$found" -eq 1 ]; then
        echo "Removed managed integration block from $rc"
    else
        echo "No managed integration block found in $rc"
    fi
    exit 0
fi

cp -n "$rc" "$rc.backrest.bak" 2>/dev/null || true

path_line="case \":\$PATH:\" in *\":$REPO_DIR:\"*) ;; *) export PATH=\"$REPO_DIR:\$PATH\" ;; esac"

{
    echo "$MARK_BEGIN"
    echo "$path_line"
    echo "source \"$source_file\""
    echo "$MARK_END"
} >> "$rc"

echo "Installed shell integration for '$shell' in $rc (PATH + completions)"
echo "Reload with: source \"$rc\"  (or open a new shell)"