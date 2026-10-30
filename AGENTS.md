# AGENTS.md

Guidance for AI agents working in this repo.

## What this is

`backrest` is a single-purpose bash tool that runs backups defined in a JSON config file. It is an orchestrator: it shells out to `restic`, `rsync`, `rclone`, and `sqlite3` — it does not implement any backup logic itself.

## Entry point

- Executable: `./backrest` (a bash script, no extension by design — it is a command, not a library)
- Library (sourced by `backrest`): `lib.sh` — all backup functions, logging, helpers live here
- `bootstrap.sh` — disaster-recovery helper that also sources `lib.sh` (`check`, `list`, `restore <profile>`); pairs with `RESTORE.md`. Restores a snapshot into a target dir (non-destructive) reusing backrest's config + restic auth. Takes no `--config`; resolves via `$BACKREST_CONFIG`, `~/.config/backrest/backup.json`, or a sibling `backup.json`.
- Config: instance config lives at `~/.config/backrest/backup.json` (XDG-aware; template is `backup.example.json`). Resolution: `--config PATH` → `$BACKREST_CONFIG` → `~/.config/backrest/backup.json` → `backup.json` → the single `backup*.json` (e.g. `backup-laptop.json`; example/schema excluded). Multiple `backup*.json` candidates error out — never guess.
- Schema: `backup.schema.json` (used for validation + editor autocomplete)

## Commands

```bash
./backrest                       # run all enabled profiles
./backrest run <profile>         # run a single profile
./backrest snapshots <profile>   # list restic snapshots for a restic/sqlite profile
./backrest logs                  # follow current backup log (like docker logs -f)
./backrest --dry-run             # print what would run, do nothing
./backrest --validate            # validate config against schema, exit
./backrest --no-validate         # skip config schema validation
./backrest --config PATH         # use a different config file
./backrest --progress            # show rsync/rclone progress on terminal
./backrest --follow, -f # follow current backup log live (like docker logs -f)
./backrest --help                # usage
```

Exit codes: `0` all ok, `1` a profile failed, `2` is used internally for "skipped" (not a process exit).

A bare profile name is shorthand for `run <profile>` (backward compat). Auxiliary actions (`snapshots`, `logs`) skip `setup_logging`; they must not touch `$LOG_FILE` (`lib.sh` defaults it to `/dev/null` so `err`/`info` are safe anywhere).

## Config structure

The instance `backup.json` has four sections:

- `paths` — named placeholders substituted anywhere via `${name}`
- `global` — shared settings: restic auth, default `check` mode, `healthchecks_url`/`healthchecks_url_file`, optional `env_file`
- `profiles` — each key is a profile name; each profile has a `type`
- `log_dir` / `log_retention_days` — logging

Path interpolation (`${name}`) is applied in `profile_val()`, to
`restic_password_file`/`restic_password_command` via `resolve_paths()`, and to
`exclude` patterns for every backend (restic/rsync/rclone). Other global fields
are read raw via `conf`.

`env_file` (global or per-profile) is a `KEY=VALUE` file for credentials of
remote repos (e.g. `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
`AWS_DEFAULT_REGION` for a restic S3/B2 repo). It is parsed by
`load_profile_env()` into `PROFILE_ENV` and passed to restic via `restic_run`
(`env "${PROFILE_ENV[@]}" restic ...`) and to hooks via `run_hook`. It is never
exported into the backrest process, so one profile's credentials cannot leak
into another. A profile-level env_file overrides `global.env_file`; relative
paths resolve against the config file's directory (`resolve_config_path`).

## Profile types

| type | tool | fields | notes |
|------|------|--------|-------|
| `restic` | restic | `src`, `repo`, `retention`, `exclude`, `flags`, `env_file`, `check`, `require_mount` | repo auto-initialized on first run; `repo` may be a local path or a backend URL (`s3:`, `b2:`, `rclone:`, `sftp:`, ...) |
| `rsync` | rsync | `src`, `dest`, optional `remote_dest`, `exclude`, `require_mount` | local mirror; `remote_dest` = second rsync target |
| `s3` | rclone | `src`, `dest` (rclone remote path, e.g. `backup-bucket:path`), `exclude`, `require_mount`, `flags` | `rclone sync` — mirrors, deletes removed files |
| `sqlite` | sqlite3 + restic | `src` (.db file), `repo`, `retention`, `flags`, `env_file`, `require_mount` | consistent `.backup` snapshot streamed to restic via `--stdin` |

Remote restic repos are detected by `is_remote_repo()` (scheme prefix).
`ensure_repo()` skips `mkdir` for them, and `repo_exists()` probes them with
`restic cat config` (exit 10 = not initialized; other non-zero = auth/network
error). Local repos keep the fast `-f "$repo/config"` check. `restic_run()`
wraps every restic invocation so `PROFILE_ENV` (from `env_file`) is applied.
`restic_backup()` appends profile `flags` to the backup command only (e.g.
`--limit-upload`).

## Retention semantics

`retention` is a restic `forget` policy string, e.g. `"keep-daily 7 keep-weekly 4"`. `lib.sh` converts these to restic `--keep-*` flags via `restic_retention_args()` — do NOT pass the string to restic verbatim.

Critical semantics:
- `keep-daily N` keeps **1 snapshot per day**, not the last N runs. Repeated same-day runs collapse to one snapshot.
- `--prune` is always applied, so freed data is reclaimed immediately.
- Snapshots are grouped by `--group-by host`.

## Restic auth resolution order

In `resolve_restic_auth()`:
1. `global.restic_password_file` (supports `${paths}` and leading `~`)
2. `global.restic_password_command`
3. `global.restic_password_autogen: true` — generates a random password into `~/.config/backrest/restic-password` on first run, reuses it after
4. `RESTIC_PASSWORD` env var

If no method applies and a restic/sqlite profile is being run, backrest errors out. restic/sqlite profiles are detected and auth is resolved only when needed (rsync/s3-only configs don't require it).

Credentials for remote repositories are **not** part of this: restic's S3
backend reads `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION`
from the environment. Point the profile (or `global`) `env_file` at a
`KEY=VALUE` file instead of exporting them in cron. `bootstrap.sh` uses the same
`env_file`, so restores from B2 work with the same config.

## Dependencies

- Required: `jq`, `check-jsonschema` (hard dependency for config validation — fails fast if missing unless `--no-validate` is passed)
- Per type: `restic`, `rsync`, `rclone`, `sqlite3`

## Verification workflow

```bash
./backrest --validate                          # config valid?
./backrest --dry-run                          # what would run?
./backrest <profile>                          # run one profile
```

`bash -n backrest lib.sh bootstrap.sh` checks syntax. No test suite exists.

## Conventions & gotchas

- Bash with `set -euo pipefail`. All functions in `lib.sh`. New backup types need: a `backup_*` function in `lib.sh`, a dispatch + dry-run case in `backrest`, an enum entry + conditional `required` in `backup.schema.json`, README + example updates.
- `sqlite` backups use restic `--stdin` with `--stdin-filename "$src"` so snapshot paths show the real source location (not a temp dir). Exception: restic 0.18.0 has a bug (#5324) where `--stdin-filename` with a directory path fails, so `restic_stdin_filename()` falls back to just the basename for that exact version.
- `check-jsonschema` requires the schema file; install via `uv tool install check-jsonschema` (preferred — no system Python needed; get `uv` itself via `curl -LsSf https://astral.sh/uv/install.sh | sh`), `pip install check-jsonschema`, or the apt package `python3-check-jsonschema` on Debian trixie+/Ubuntu 24.04+. Config validation can be skipped entirely with `--no-validate`.
- Hooks: optional `prehook`/`posthook` executable scripts per profile; they source `~/.config/backrest/hooks/.env` for secrets (gitignored), with the checkout's legacy `hooks/.env` as fallback. A prehook exit code of `2` means "skip this profile gracefully" (e.g. service down) — reported as SKIP, run stays healthy, no backup is taken; any other non-zero exit fails the profile and also skips the backup. Posthooks run only after a successful prehook (and still after a failed backup).
- `require_mount`: optional per-profile path checked by `check_require_mount()` in `lib.sh` at the top of every `backup_*`; if the path is not a mount point the profile refuses to run (rc 1) without touching source/destination. Guards an unmounted backup disk (empty dir) against a fresh restic init or a destructive `rclone sync`. Supports `${path}` placeholders.
- Shell completion: `completions/` mirrors the svcsh layout (`backrest.bash` shared bash/zsh via bashcompinit, `backrest.zsh` wrapper, `completions/fish/backrest.fish` with `@REPO_DIR@` substitution) and resolves the config like the script: `--config` from the command line → `$BACKREST_CONFIG` → `~/.config/backrest/backup.json` → `backup.json` → single `backup*.json` (ambiguous → no profiles). `install.sh` wires it into `~/.bashrc` / `~/.zshrc` / fish config with a managed marker block; `--remove` undoes it. New actions/options must be added to the completion word lists and `ACTIONS` in `backrest`.