#!/usr/bin/env bash
#
# Shared utilities for backrest

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/backup.json}"

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install: sudo apt install jq" >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
info() { log "${CYAN}[INFO]${NC} $*"; }
ok()   { log "${GREEN}[OK]${NC}   $*"; }
warn() { log "${YELLOW}[WARN]${NC} $*"; }
err()  { log "${RED}[ERR]${NC}  $*"; }

summary_ok=()
summary_err=()
summary_skip=()

conf() {
    jq -r "$@" "$CONFIG_FILE"
}

conf_raw() {
    jq "$@" "$CONFIG_FILE"
}

get_profiles() {
    conf '.profiles | keys[]'
}

get_enabled_profiles() {
    conf '.profiles | to_entries[] | select(.value.enabled != false) | .key'
}

profile_has() {
    local profile="$1" key="$2"
    conf ".profiles.\"$profile\" | has(\"$key\")"
}

profile_val() {
    local profile="$1" key="$2"
    local raw
    raw="$(conf ".profiles.\"$profile\".\"$key\" // empty")"
    resolve_paths "$raw"
}

resolve_paths() {
    local val="$1"
    local keys
    keys="$(conf '.paths | keys[]?')"
    if [[ -z "$keys" ]]; then
        echo "$val"
        return
    fi
    while IFS= read -r k; do
        local v
        v="$(conf ".paths.\"$k\"")"
        val="${val//\$\{${k}\}/$v}"
    done <<< "$keys"
    echo "$val"
}

is_mounted() {
    mountpoint --quiet "$1" 2>/dev/null
}

ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] && return 0
    mkdir -p "$dir" || { err "Cannot create $dir"; return 1; }
}

check_source() {
    local src="$1"
    [[ "$src" == *":"* ]] && return 0
    if [[ ! -e "$src" ]]; then
        warn "Source not found: $src — skipping"
        return 1
    fi
    return 0
}

check_dest_parent() {
    local dest="$1"
    [[ "$dest" == *":"* ]] && return 0
    local parent
    parent="$(dirname "$dest")"
    is_mounted "$parent" || is_mounted "$dest" || [[ -d "$parent" ]] && return 0
    warn "Destination parent not available: $parent — skipping"
    return 1
}

load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        local key="${line%%=*}"
        key="${key//[[:space:]]/}"
        [[ -z "$key" ]] && continue
        if [[ -z "${!key:-}" ]]; then
            local val="${line#*=}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            export "$key=$val"
        fi
    done < "$env_file"
}

load_hook_env() {
    load_env_file "$SCRIPT_DIR/hooks/.env"
}

run_hook() {
    local profile="$1" hook_type="$2"
    if [[ "$(profile_has "$profile" "${hook_type}hook")" != "true" ]]; then
        return 0
    fi
    local hook
    hook="$(profile_val "$profile" "${hook_type}hook")"
    if [[ -n "$hook" && -x "$hook" ]]; then
        info "[$profile] Running ${hook_type}-hook: $hook"
        load_hook_env
        local -a hook_env=()
        if [[ "$(profile_has "$profile" "hook_env")" == "true" ]]; then
            while IFS= read -r k; do
                [[ -n "$k" ]] && hook_env+=( "$k=$(conf ".profiles.\"$profile\".hook_env.\"$k\"")" )
            done < <(conf ".profiles.\"$profile\".hook_env | keys[]?")
        fi
        if ! env "${hook_env[@]}" "$hook" >> "$LOG_FILE" 2>&1; then
            err "[$profile] ${hook_type}-hook failed"
            return 1
        fi
    fi
    return 0
}

RESTIC_AUTH_ARGS=()

resolve_restic_auth() {
    local pw_file pw_cmd
    pw_file="$(conf '.global.restic_password_file // empty')"
    pw_cmd="$(conf '.global.restic_password_command // empty')"

    if [[ -n "$pw_file" ]]; then
        pw_file="${pw_file/#\~/$HOME}"
        if [[ -f "$pw_file" ]]; then
            RESTIC_AUTH_ARGS=(--password-file "$pw_file")
            return 0
        fi
        err "Password file not found: $pw_file"
        return 1
    fi
    if [[ -n "$pw_cmd" ]]; then
        RESTIC_AUTH_ARGS=(--password-command "$pw_cmd")
        return 0
    fi
    if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
        RESTIC_AUTH_ARGS=()
        return 0
    fi
    err "No restic password configured. Set restic_password_file in backup.json"
    return 1
}

backup_restic() {
    local profile="$1"
    local src repo retention exclude_args

    src="$(profile_val "$profile" src)"
    repo="$(profile_val "$profile" repo)"
    retention="$(profile_val "$profile" retention)"
    retention="${retention:-keep-last 10}"

    check_source "$src" || return 2
    ensure_dir "$repo" || return 1

    if ! restic "${RESTIC_AUTH_ARGS[@]}" -r "$repo" snapshots --no-lock &>/dev/null; then
        info "[$profile] Initializing restic repo at $repo"
        restic "${RESTIC_AUTH_ARGS[@]}" -r "$repo" init >> "$LOG_FILE" 2>&1 || {
            err "[$profile] Failed to init repo"; return 1
        }
    fi

    info "[$profile] Starting restic backup: $src → $repo"

    local -a exclude_args_arr=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args_arr+=(--exclude "$pattern")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    if restic "${RESTIC_AUTH_ARGS[@]}" -r "$repo" backup "$src" \
        --exclude-caches \
        "${exclude_args_arr[@]}" \
        --verbose \
        >> "$LOG_FILE" 2>&1; then
        ok "[$profile] Backup completed"

        info "[$profile] Applying retention: $retention"
        restic "${RESTIC_AUTH_ARGS[@]}" -r "$repo" forget --group-by host --prune \
            $retention >> "$LOG_FILE" 2>&1 || warn "[$profile] Retention/prune had issues"

        local check_mode
        check_mode="$(profile_val "$profile" check)"
        [[ -z "$check_mode" ]] && check_mode="$(conf '.global.check // "full"')"

        local -a check_args=()
        case "$check_mode" in
            never|false|0) : ;;
            quick) check_args=(check) ;;
            *)     check_args=(check --read-data) ;;
        esac

        if [[ ${#check_args[@]} -gt 0 ]]; then
            info "[$profile] Running integrity check ($check_mode)"
            if restic "${RESTIC_AUTH_ARGS[@]}" -r "$repo" "${check_args[@]}" >> "$LOG_FILE" 2>&1; then
                ok "[$profile] Integrity check passed"
            else
                warn "[$profile] Integrity check found issues — see log"
            fi
        fi
        return 0
    else
        err "[$profile] Backup failed"
        return 1
    fi
}

_rsync_pipe() {
    if [[ "${SHOW_PROGRESS:-false}" == "true" ]]; then
        rsync "$@" 2>&1 | tee >(sed -u 's/\r/\n/g; s/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
    else
        rsync "$@" >> "$LOG_FILE" 2>&1
    fi
}

backup_rsync() {
    local profile="$1"
    local src dest

    src="$(profile_val "$profile" src)"
    dest="$(profile_val "$profile" dest)"

    check_source "$src" || return 2
    check_dest_parent "$dest" || return 2
    ensure_dir "$dest" || return 1

    local -a exclude_args=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=(--exclude "$pattern")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    info "[$profile] Starting rsync: $src → $dest"
    if _rsync_pipe -ah --delete --info=progress2 --stats \
        "${exclude_args[@]}" \
        "$src/" "$dest/"; then
        ok "[$profile] Rsync completed"
        return 0
    else
        err "[$profile] Rsync failed"
        return 1
    fi
}

backup_rsync_remote() {
    local profile="$1"

    if [[ "$(profile_has "$profile" "remote_dest")" != "true" ]]; then
        return 0
    fi

    local src remote
    src="$(profile_val "$profile" src)"
    remote="$(profile_val "$profile" remote_dest)"

    [[ -z "$remote" ]] && return 0
    check_source "$src" || return 0

    local -a exclude_args=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=(--exclude "$pattern")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    info "[$profile] Starting remote rsync: $src → $remote"
    if _rsync_pipe -ah --delete --info=progress2 --stats \
        "${exclude_args[@]}" \
        "$src/" "$remote"; then
        ok "[$profile] Remote rsync completed"
        return 0
    else
        warn "[$profile] Remote rsync failed"
        return 1
    fi
}

print_summary() {
    echo ""
    echo "========== Backup Summary =========="
    printf "  ${GREEN}OK:${NC}     %d\n" "${#summary_ok[@]}"
    for p in "${summary_ok[@]}"; do echo "    - $p"; done
    printf "  ${RED}FAIL:${NC}   %d\n" "${#summary_err[@]}"
    for p in "${summary_err[@]}"; do echo "    - $p"; done
    printf "  ${YELLOW}SKIP:${NC}   %d\n" "${#summary_skip[@]}"
    for p in "${summary_skip[@]}"; do echo "    - $p"; done
    echo "===================================="
    echo "Log: $LOG_FILE"
}

setup_logging() {
    local log_dir log_retention
    log_dir="$(conf '.log_dir // "$HOME/.local/log/backup"' | envsubst)"
    eval "log_dir=\"$log_dir\""

    LOG_DIR="$log_dir"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"
    :> "$LOG_FILE"
    info "Backup started — $(date)"
}

cleanup_old_logs() {
    local retention
    retention="$(conf '.log_retention_days // 30')"
    find "$LOG_DIR" -name "backup-*.log" -mtime "+$retention" -delete 2>/dev/null || true
}

HEALTHCHECK_URL=""

ping_healthcheck() {
    local status="${1:-ok}"
    [[ -z "$HEALTHCHECK_URL" ]] && return 0
    local url="$HEALTHCHECK_URL"
    case "$status" in
        start) url+="/start" ;;
        fail)  url+="/fail" ;;
    esac
    if command -v curl &>/dev/null; then
        curl -fsS -m 10 -o /dev/null "$url" 2>/dev/null \
            || warn "Healthcheck ping (${status}) failed"
    else
        warn "curl not found — skipping healthcheck ping"
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [[ $rc -eq 0 ]]; then
        ping_healthcheck ok
    else
        ping_healthcheck fail
    fi
    exit "$rc"
}
