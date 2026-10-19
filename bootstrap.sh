#!/usr/bin/env bash
#
# bootstrap.sh — disaster-recovery companion to backrest.
#
# backrest only protects what git cannot: the git-ignored instance config
# (svcsh's global.env/ports.env/stacks, backrest's
# ~/.config/backrest/{backup.json,hooks/.env}) and the data. Tracked code comes
# from git — clone the repos. Everything else lives in the restic repos, and
# this script reads the same config + restic auth as backrest so recovery never
# depends on remembering paths.
#
# Full rebuild order: see RESTORE.md.
#
# Usage:
#   ./bootstrap.sh check
#   ./bootstrap.sh list
#   ./bootstrap.sh restore <profile> [--target DIR] [--snapshot latest|ID] [--include PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

config_rc=0
CONFIG_FILE="$(resolve_config_file)" || config_rc=$?
if [[ "$config_rc" -eq 1 ]]; then
    echo "Error: Config file not found." >&2
    echo "  Put it at ${XDG_CONFIG_HOME:-$HOME/.config}/backrest/backup.json," >&2
    echo "  or set BACKREST_CONFIG." >&2
    exit 1
elif [[ "$config_rc" -ne 0 ]]; then
    exit 1
fi

usage() {
    cat <<'EOF'
bootstrap.sh — restore a host from backrest snapshots

Usage:
  ./bootstrap.sh check
      Verify tools, restic auth, and show every profile with its repo status.

  ./bootstrap.sh list
      List profiles and their type.

  ./bootstrap.sh restore <profile> [options]
      Restore a snapshot into a target directory. Non-destructive: files land in
      --target, never overwritten in place.

Options:
  --target DIR           Where to restore (default: ./restore/<profile>)
  --snapshot latest|ID   Snapshot to restore (default: latest)
  --include PATH         Only restore this path from the snapshot (repeatable)
  -h, --help

Config is resolved like backrest (without --config): $BACKREST_CONFIG,
~/.config/backrest/backup.json, or the sibling backup.json.

See RESTORE.md for the full rebuild order.
EOF
}

profile_type() { profile_val "$1" type; }

has_restic_profiles() {
    local p
    while IFS= read -r p; do
        case "$(profile_type "$p")" in
            restic|sqlite) return 0 ;;
        esac
    done < <(get_profiles)
    return 1
}

require_restic_auth() {
    if ! resolve_restic_auth; then
        err "Cannot resolve the restic password."
        err "Place the off-host copy at ~/.config/backrest/restic-password (chmod 600), then retry."
        exit 1
    fi
}

cmd_list() {
    local p
    while IFS= read -r p; do
        printf '%-24s %s\n' "$p" "$(profile_type "$p")"
    done < <(get_profiles)
}

cmd_check() {
    local tool rc=0
    for tool in jq restic rsync rclone sqlite3 check-jsonschema; do
        if command -v "$tool" &>/dev/null; then
            printf '  %-16s %s\n' "$tool" "$(command -v "$tool")"
        else
            printf '  %-16s MISSING\n' "$tool"
            [[ "$tool" == restic || "$tool" == jq ]] && rc=1
        fi
    done

    if has_restic_profiles; then
        echo ""
        require_restic_auth
        info "restic auth resolved"
    fi

    echo ""
    local p type repo status n rc_repo
    while IFS= read -r p; do
        type="$(profile_type "$p")"
        case "$type" in
            restic|sqlite)
                repo="$(profile_val "$p" repo)"
                rc_repo=0
                if ! load_profile_env "$p"; then
                    status="env_file MISSING"
                    rc=1
                else
                    repo_exists "$repo" || rc_repo=$?
                    if [[ $rc_repo -eq 0 ]]; then
                        n="$(restic_run -r "$repo" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo '?')"
                        status="repo ok — ${n} snapshot(s)"
                    elif [[ $rc_repo -eq 1 ]]; then
                        status="repo MISSING: $repo"
                        rc=1
                    else
                        status="repo UNREACHABLE (restic exit ${rc_repo}) — check env_file/credentials"
                        rc=1
                    fi
                fi
                ;;
            rsync|s3)
                status="$(profile_val "$p" src) -> $(profile_val "$p" dest)"
                ;;
            *)
                status="unknown type"
                ;;
        esac
        printf '  %-24s %-7s %s\n' "$p" "$type" "$status"
    done < <(get_profiles)

    return "$rc"
}

cmd_restore() {
    if [[ $# -lt 1 ]]; then
        err "restore needs a profile name"
        usage
        exit 2
    fi
    local profile="$1"; shift
    local target="" snapshot="latest"
    local -a includes=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)   target="$2"; shift 2 ;;
            --snapshot) snapshot="$2"; shift 2 ;;
            --include)  includes+=("$2"); shift 2 ;;
            *) err "Unknown option: $1"; usage; exit 2 ;;
        esac
    done

    local found=false p
    while IFS= read -r p; do
        [[ "$p" == "$profile" ]] && found=true
    done < <(get_profiles)
    if [[ "$found" != true ]]; then
        err "Unknown profile: $profile"
        err "Known: $(get_profiles | paste -sd ' ' -)"
        exit 1
    fi

    local type; type="$(profile_type "$profile")"
    if [[ "$type" != restic && "$type" != sqlite ]]; then
        err "restore only works for restic/sqlite profiles (type: $type)"
        err "For rsync/s3 the remote is the copy — re-run the profile with the source present."
        exit 1
    fi

    [[ -n "$target" ]] || target="$PWD/restore/$profile"
    require_restic_auth
    load_profile_env "$profile" || exit 1

    local repo; repo="$(profile_val "$profile" repo)"
    repo_exists "$repo" || { err "Repo not found or unreachable: $repo"; exit 1; }

    mkdir -p "$target"
    local -a include_args=()
    for p in "${includes[@]}"; do include_args+=(--include "$p"); done

    info "[$profile] restoring '$snapshot' from $repo -> $target"
    restic_run -r "$repo" restore "$snapshot" --target "$target" "${include_args[@]}"
    ok "[$profile] restored to $target"
    echo ""
    echo "Review $target, then copy the pieces into place (see RESTORE.md)."
}

case "${1:-}" in
    check)   cmd_check ;;
    list)    cmd_list ;;
    restore) shift; cmd_restore "$@" ;;
    -h|--help|"") usage ;;
    *) err "Unknown command: $1"; usage; exit 2 ;;
esac
