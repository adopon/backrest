#!/usr/bin/env bash
#
# Shared utilities for backrest

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/backup.json}"
LOG_FILE="${LOG_FILE:-/dev/null}"

# Resolve the config file. Precedence:
#   1. explicit path (CLI --config)
#   2. $BACKREST_CONFIG
#   3. $XDG_CONFIG_HOME/backrest/backup.json (default ~/.config/backrest/)
#   4. backup.json next to the script (legacy)
#   5. the single backup*.json next to the script
# Prints the path; returns 1 when none is found, 2 when ambiguous.
resolve_config_file() {
    local explicit="${1:-}" xdg f
    local -a candidates=()

    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [[ -n "${BACKREST_CONFIG:-}" ]]; then
        printf '%s\n' "$BACKREST_CONFIG"
        return 0
    fi
    xdg="${XDG_CONFIG_HOME:-$HOME/.config}/backrest/backup.json"
    if [[ -f "$xdg" ]]; then
        printf '%s\n' "$xdg"
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/backup.json" ]]; then
        printf '%s\n' "$SCRIPT_DIR/backup.json"
        return 0
    fi
    for f in "$SCRIPT_DIR"/backup-*.json "$SCRIPT_DIR"/backup*.json; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *example*|*schema*) continue ;;
        esac
        [[ " ${candidates[*]-} " == *" $f "* ]] && continue
        candidates+=("$f")
    done
    if [[ ${#candidates[@]} -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
        echo "Error: multiple config files found:" >&2
        printf '  %s\n' "${candidates[@]}" >&2
        echo "  Set BACKREST_CONFIG or pass --config PATH to pick one" >&2
        return 2
    fi
    return 1
}

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

# After a failed command (output goes only to $LOG_FILE), print the most recent
# log lines plus the log path so the underlying tool error is visible.
show_tool_error() {
    local profile="$1" msg="$2"
    local tail_out
    tail_out="$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)"
    err "[$profile] $msg"
    err "[$profile] Full log: $LOG_FILE"
    [[ -n "$tail_out" ]] && printf '%s\n' "$tail_out" | sed 's/^/    /'
}

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
    keys="$(conf '.paths // {} | keys[]?')"
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

# Resolve a path from the config: expands ${path} placeholders and a leading
# ~. Relative paths are resolved against the config file's directory, so the
# instance config (e.g. ~/.config/backrest/) can keep secrets beside itself.
resolve_config_path() {
    local path="$1"
    path="$(resolve_paths "$path")"
    path="${path/#\~/$HOME}"
    if [[ "$path" != /* ]]; then
        path="$(dirname "$CONFIG_FILE")/$path"
    fi
    printf '%s\n' "$path"
}

# A restic repository is either a local path or a backend URL. Only local
# paths may be created with mkdir and probed with -f.
is_remote_repo() {
    case "$1" in
        s3:*|b2:*|rclone:*|sftp:*|rest:*|azure:*|gs:*|swift:*|http:*|https:*) return 0 ;;
    esac
    return 1
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

# A profile may declare `require_mount`: a path that must be a mount point
# before the profile runs. Guards against destructive operations (rclone sync,
# restic prune) hitting an unmounted directory — a failed mount leaves an empty
# dir behind, and a sync would then mirror that emptiness over the backup.
check_require_mount() {
    local profile="$1"
    [[ "$(profile_has "$profile" "require_mount")" == "true" ]] || return 0
    local path
    path="$(profile_val "$profile" require_mount)"
    [[ -n "$path" ]] || return 0
    if ! is_mounted "$path"; then
        err "[$profile] require_mount: '$path' is not a mount point — refusing to run"
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

# Read KEY=VALUE pairs into ENV_FILE_VARS without exporting them. This is a
# data format (like systemd's EnvironmentFile= / Docker's --env-file), not
# shell source: values are never executed, comments are lines starting with #,
# and an optional leading "export " is accepted.
ENV_FILE_VARS=()
read_env_file() {
    local env_file="$1" line key val
    ENV_FILE_VARS=()
    [[ -f "$env_file" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            val="${BASH_REMATCH[3]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            ENV_FILE_VARS+=("$key=$val")
        fi
    done < "$env_file"
}

load_env_file() {
    local env_file="$1" kv key val
    [[ -f "$env_file" ]] || return 0
    read_env_file "$env_file"
    for kv in "${ENV_FILE_VARS[@]}"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -n "${!key:-}" ]] && continue
        export "$key=$val"
    done
}

load_hook_env() {
    local env_file
    # Instance hooks live next to the config; fall back to the checkout's
    # legacy hooks/ directory for older layouts.
    env_file="$(dirname "$CONFIG_FILE")/hooks/.env"
    [[ -f "$env_file" ]] || env_file="$SCRIPT_DIR/hooks/.env"
    load_env_file "$env_file"
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
        if ! env "${PROFILE_ENV[@]}" "${hook_env[@]}" "$hook" >> "$LOG_FILE" 2>&1; then
            err "[$profile] ${hook_type}-hook failed"
            return 1
        fi
    fi
    return 0
}

RESTIC_AUTH_ARGS=()
RESTIC_GLOBAL_ARGS=()
PROFILE_ENV=()

# Load a profile's env_file (KEY=VALUE) into PROFILE_ENV. Credentials are passed
# explicitly to each tool invocation instead of being exported globally, so a
# profile with cloud credentials cannot leak them into unrelated profiles.
load_profile_env() {
    local profile="$1" env_file
    PROFILE_ENV=()
    if [[ "$(profile_has "$profile" "env_file")" == "true" ]]; then
        env_file="$(profile_val "$profile" env_file)"
    else
        env_file="$(conf '.global.env_file // empty')"
        [[ -n "$env_file" ]] && env_file="$(resolve_paths "$env_file")"
    fi
    [[ -n "$env_file" ]] || return 0
    env_file="$(resolve_config_path "$env_file")"
    if [[ ! -f "$env_file" ]]; then
        err "[$profile] env_file not found: $env_file"
        return 1
    fi
    read_env_file "$env_file"
    PROFILE_ENV=("${ENV_FILE_VARS[@]}")
    return 0
}

# Run restic with the current profile's env (e.g. AWS_* for an S3/B2 repo).
restic_run() {
    env "${PROFILE_ENV[@]}" restic "${RESTIC_GLOBAL_ARGS[@]}" "${RESTIC_AUTH_ARGS[@]}" "$@"
}

# True when a restic repository exists. Local repos are probed on disk; remote
# repos (s3:, b2:, rclone:, ...) are probed with `restic cat config`, which
# exits 10 when the repo is absent.
repo_exists() {
    local repo="$1"
    if is_remote_repo "$repo"; then
        restic_run -r "$repo" cat config >/dev/null 2>&1
        return $?
    fi
    [[ -f "$repo/config" ]]
}

# Create a local repo directory; remote repos are created by `restic init`.
ensure_repo() {
    local repo="$1"
    is_remote_repo "$repo" && return 0
    ensure_dir "$repo"
}

autogen_restic_password() {
    local pw_file="${1:-${HOME}/.config/backrest/restic-password}"
    if [[ -f "$pw_file" ]]; then
        info "Using existing autogenerated restic password: $pw_file"
        RESTIC_AUTH_ARGS=(--password-file "$pw_file")
        return 0
    fi
    if ! command -v openssl &>/dev/null; then
        err "openssl not found — cannot autogenerate restic password"
        return 1
    fi
    mkdir -p "$(dirname "$pw_file")" || { err "Cannot create $(dirname "$pw_file")"; return 1; }
    chmod 700 "$(dirname "$pw_file")"
    openssl rand -base64 32 | tr -d '\n' > "$pw_file" || { err "Failed to generate password"; return 1; }
    chmod 600 "$pw_file"
    info "Generated restic password: $pw_file"
    RESTIC_AUTH_ARGS=(--password-file "$pw_file")
    return 0
}

resolve_restic_auth() {
    local pw_file pw_cmd autogen compression
    compression="$(conf '.global.restic_compression // empty')"
    RESTIC_GLOBAL_ARGS=()
    [[ -n "$compression" ]] && RESTIC_GLOBAL_ARGS=(--compression "$compression")
    pw_file="$(conf '.global.restic_password_file // empty')"
    pw_cmd="$(conf '.global.restic_password_command // empty')"
    autogen="$(conf '.global.restic_password_autogen // empty')"

    if [[ -n "$pw_file" ]]; then
        pw_file="$(resolve_paths "$pw_file")"
        pw_file="${pw_file/#\~/$HOME}"
        if [[ -f "$pw_file" ]]; then
            RESTIC_AUTH_ARGS=(--password-file "$pw_file")
            return 0
        fi
        if [[ "$autogen" == "true" ]]; then
            autogen_restic_password "$pw_file"
            return $?
        fi
        err "Password file not found: $pw_file"
        return 1
    fi
    if [[ -n "$pw_cmd" ]]; then
        pw_cmd="$(resolve_paths "$pw_cmd")"
        RESTIC_AUTH_ARGS=(--password-command "$pw_cmd")
        return 0
    fi
    if [[ "$autogen" == "true" ]]; then
        autogen_restic_password
        return $?
    fi
    if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
        RESTIC_AUTH_ARGS=()
        return 0
    fi
    err "No restic password configured. Set restic_password_file in backup.json"
    return 1
}

restic_repo_init() {
    local profile="$1" repo="$2" rc=0
    repo_exists "$repo" || rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    if is_remote_repo "$repo" && [[ $rc -ne 10 ]]; then
        err "[$profile] Cannot access repository $repo (restic exit $rc)"
        err "[$profile] Check env_file credentials, the repo URL and network access"
        return 1
    fi
    info "[$profile] Initializing restic repo at $repo"
    restic_run -r "$repo" init >> "$LOG_FILE" 2>&1 || {
        show_tool_error "$profile" "Failed to init repo"; return 1
    }
}

# restic 0.18.0 breaks on --stdin-filename with directory components (#5324);
# every other version (<=0.17.x and >=0.18.1) handles the full path fine.
restic_stdin_filename() {
    local v
    v="$(restic version 2>/dev/null | awk '{print $2}')"
    if [[ "$v" == "0.18.0" ]]; then
        basename "$1"
    else
        printf '%s\n' "$1"
    fi
}

restic_backup() {
    local profile="$1" src="$2" repo="$3" retention="$4"

    local -a exclude_args_arr=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args_arr+=(--exclude "$(resolve_paths "$pattern")")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    # Optional extra restic flags, e.g. ["--limit-upload", "8000"].
    local -a extra_flags=()
    if [[ "$(profile_has "$profile" "flags")" == "true" ]]; then
        while IFS= read -r flag; do
            [[ -n "$flag" ]] && extra_flags+=("$flag")
        done < <(conf ".profiles.\"$profile\".flags[]?")
    fi

    info "[$profile] Starting restic backup: $src → $repo"
    if restic_run -r "$repo" backup "$src" \
        --exclude-caches \
        "${exclude_args_arr[@]}" \
        "${extra_flags[@]}" \
        --verbose \
        >> "$LOG_FILE" 2>&1; then
        ok "[$profile] Backup completed"
        return 0
    else
        show_tool_error "$profile" "Backup failed"
        return 1
    fi
}

restic_retention_args() {
    local retention="$1" policy count
    local -a words=() args=()
    read -r -a words <<< "$retention"
    local i=0
    while [[ $i -lt ${#words[@]} ]]; do
        policy="${words[$i]}"
        count="${words[$((i+1))]:-}"
        i=$((i+2))
        case "$policy" in
            keep-last)          args+=(--keep-last "$count") ;;
            keep-hourly)        args+=(--keep-hourly "$count") ;;
            keep-daily)         args+=(--keep-daily "$count") ;;
            keep-weekly)        args+=(--keep-weekly "$count") ;;
            keep-monthly)       args+=(--keep-monthly "$count") ;;
            keep-yearly)        args+=(--keep-yearly "$count") ;;
            keep-tag)           args+=(--keep-tag "$count") ;;
            keep-within)        args+=(--keep-within "$count") ;;
            keep-within-daily)  args+=(--keep-within-daily "$count") ;;
            keep-within-weekly) args+=(--keep-within-weekly "$count") ;;
            keep-within-monthly) args+=(--keep-within-monthly "$count") ;;
            keep-within-yearly) args+=(--keep-within-yearly "$count") ;;
            *) warn "Unknown retention policy: $policy" ;;
        esac
    done
    printf '%s\n' "${args[@]}"
}

restic_retention() {
    local profile="$1" repo="$2" retention="$3"
    local -a keep_args=()
    while IFS= read -r a; do keep_args+=("$a"); done < <(restic_retention_args "$retention")
    info "[$profile] Applying retention: $retention"
    restic_run -r "$repo" forget --group-by host --prune \
        "${keep_args[@]}" >> "$LOG_FILE" 2>&1 \
        || warn "[$profile] Retention/prune had issues"
}

restic_check() {
    local profile="$1" repo="$2"
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
        if restic_run -r "$repo" "${check_args[@]}" >> "$LOG_FILE" 2>&1; then
            ok "[$profile] Integrity check passed"
        else
            warn "[$profile] Integrity check found issues — see log"
        fi
    fi
}

backup_restic() {
    local profile="$1"
    local src repo retention

    src="$(profile_val "$profile" src)"
    repo="$(profile_val "$profile" repo)"
    retention="$(profile_val "$profile" retention)"
    retention="${retention:-keep-last 10}"

    check_require_mount "$profile" || return 1
    check_source "$src" || return 2
    load_profile_env "$profile" || return 1
    ensure_repo "$repo" || return 1

    restic_repo_init "$profile" "$repo" || return 1
    restic_backup "$profile" "$src" "$repo" "$retention" || return 1
    restic_retention "$profile" "$repo" "$retention"
    restic_check "$profile" "$repo"
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

    check_require_mount "$profile" || return 1
    check_source "$src" || return 2
    check_dest_parent "$dest" || return 2
    ensure_dir "$dest" || return 1

    local -a exclude_args=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=(--exclude "$(resolve_paths "$pattern")")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    info "[$profile] Starting rsync: $src → $dest"
    if _rsync_pipe -ah --delete --info=progress2 --stats \
        "${exclude_args[@]}" \
        "$src/" "$dest/"; then
        ok "[$profile] Rsync completed"
        return 0
    else
        show_tool_error "$profile" "Rsync failed"
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
            [[ -n "$pattern" ]] && exclude_args+=(--exclude "$(resolve_paths "$pattern")")
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

_rclone_pipe() {
    if [[ "${SHOW_PROGRESS:-false}" == "true" ]]; then
        rclone "$@" --progress 2>&1 | tee >(sed -u 's/\r/\n/g; s/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
    else
        rclone "$@" >> "$LOG_FILE" 2>&1
    fi
}

backup_s3() {
    local profile="$1"
    local src dest

    src="$(profile_val "$profile" src)"
    dest="$(profile_val "$profile" dest)"

    check_require_mount "$profile" || return 1

    if ! command -v rclone &>/dev/null; then
        err "[$profile] rclone not found. Install: sudo apt install rclone"
        return 1
    fi

    check_source "$src" || return 2

    local -a exclude_args=()
    if [[ "$(profile_has "$profile" "exclude")" == "true" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=(--exclude "$(resolve_paths "$pattern")")
        done < <(conf ".profiles.\"$profile\".exclude[]?")
    fi

    local -a extra_flags=()
    if [[ "$(profile_has "$profile" "flags")" == "true" ]]; then
        while IFS= read -r flag; do
            [[ -n "$flag" ]] && extra_flags+=("$flag")
        done < <(conf ".profiles.\"$profile\".flags[]?")
    else
        extra_flags=(--checksum)
    fi

    info "[$profile] Starting rclone sync: $src → $dest"
    if _rclone_pipe sync "$src" "$dest" "${exclude_args[@]}" "${extra_flags[@]}"; then
        ok "[$profile] S3 sync completed"
        return 0
    else
        show_tool_error "$profile" "S3 sync failed"
        return 1
    fi
}

backup_sqlite() {
    local profile="$1"
    local src repo retention base snap tmpdir rc

    src="$(profile_val "$profile" src)"
    repo="$(profile_val "$profile" repo)"
    retention="$(profile_val "$profile" retention)"
    retention="${retention:-keep-last 10}"

    check_require_mount "$profile" || return 1

    if ! command -v sqlite3 &>/dev/null; then
        err "[$profile] sqlite3 not found. Install: sudo apt install sqlite3"
        return 1
    fi

    check_source "$src" || return 2
    load_profile_env "$profile" || return 1
    ensure_repo "$repo" || return 1

    tmpdir="$(mktemp -d)"
    base="$(basename "$src")"
    snap="$tmpdir/$base"

    info "[$profile] Taking consistent sqlite snapshot: $src"
    if ! sqlite3 "$src" ".backup '$snap'" >> "$LOG_FILE" 2>&1; then
        show_tool_error "$profile" "sqlite snapshot failed"
        rm -rf "$tmpdir"
        return 1
    fi

    rc=0
    restic_repo_init "$profile" "$repo" || rc=1

    local -a extra_flags=()
    if [[ "$(profile_has "$profile" "flags")" == "true" ]]; then
        while IFS= read -r flag; do
            [[ -n "$flag" ]] && extra_flags+=("$flag")
        done < <(conf ".profiles.\"$profile\".flags[]?")
    fi

    if [[ $rc -eq 0 ]]; then
        info "[$profile] Starting restic backup: $src → $repo"
        if cat "$snap" | restic_run -r "$repo" backup --stdin \
            --stdin-filename "$(restic_stdin_filename "$src")" \
            "${extra_flags[@]}" --verbose >> "$LOG_FILE" 2>&1; then
            ok "[$profile] Backup completed"
        else
            show_tool_error "$profile" "Backup failed"
            rc=1
        fi
    fi
    if [[ $rc -eq 0 ]]; then
        restic_retention "$profile" "$repo" "$retention"
        restic_check "$profile" "$repo"
    fi

    rm -rf "$tmpdir"
    return $rc
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

get_log_dir() {
    local log_dir
    log_dir="$(conf '.log_dir // "$HOME/.local/log/backup"' | envsubst)"
    eval "log_dir=\"$log_dir\""
    LOG_DIR="$log_dir"
}

setup_logging() {
    get_log_dir
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"
    :> "$LOG_FILE"
    ln -sfn "$LOG_FILE" "$LOG_DIR/backup-current.log"
    info "Backup started — $(date)"
}

cleanup_old_logs() {
    local retention
    retention="$(conf '.log_retention_days // 30')"
    find "$LOG_DIR" -type f -name "backup-*.log" -mtime "+$retention" -delete 2>/dev/null || true
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
