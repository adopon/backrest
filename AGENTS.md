# AGENTS.md

Guidance for AI agents working in this repo.

## What this is

`backrest` is a single-purpose bash tool that runs backups defined in a JSON config file. It is an orchestrator: it shells out to `restic`, `rsync`, `rclone`, and `sqlite3` — it does not implement any backup logic itself.

## Entry point

- Executable: `./backrest` (a bash script, no extension by design — it is a command, not a library)
- Library (sourced by `backrest`): `lib.sh` — all backup functions, logging, helpers live here
- Config: `backup.json` (gitignored; template is `backup.example.json`)
- Schema: `backup.schema.json` (used for validation + editor autocomplete)

## Commands

```bash
./backrest                       # run all enabled profiles
./backrest <profile>             # run a single profile
./backrest --dry-run             # print what would run, do nothing
./backrest --validate            # validate config against schema, exit
./backrest --no-validate         # skip config schema validation
./backrest --config PATH         # use a different config file
./backrest --progress            # show rsync/rclone progress on terminal
./backrest --help                # usage
```

Exit codes: `0` all ok, `1` a profile failed, `2` is used internally for "skipped" (not a process exit).

## Config structure

`backup.json` has four sections:

- `paths` — named placeholders substituted anywhere via `${name}`
- `global` — shared settings: restic auth, default `check` mode, `healthchecks_url`
- `profiles` — each key is a profile name; each profile has a `type`
- `log_dir` / `log_retention_days` — logging

Path interpolation (`${name}`) is applied in `profile_val()` and to `restic_password_file`/`restic_password_command` via `resolve_paths()`. Other global fields are read raw via `conf`.

## Profile types

| type | tool | fields | notes |
|------|------|--------|-------|
| `restic` | restic | `src`, `repo`, `retention`, `exclude`, `check` | repo auto-initialized on first run |
| `rsync` | rsync | `src`, `dest`, optional `remote_dest`, `exclude` | local mirror; `remote_dest` = second rsync target |
| `s3` | rclone | `src`, `dest` (rclone remote path, e.g. `backup-bucket:path`), `exclude` | `rclone sync` — mirrors, deletes removed files |
| `sqlite` | sqlite3 + restic | `src` (.db file), `repo`, `retention` | consistent `.backup` snapshot streamed to restic via `--stdin` |

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

## Dependencies

- Required: `jq`, `check-jsonschema` (hard dependency for config validation — fails fast if missing unless `--no-validate` is passed)
- Per type: `restic`, `rsync`, `rclone`, `sqlite3`

## Verification workflow

```bash
./backrest --validate                          # config valid?
./backrest --dry-run                          # what would run?
./backrest <profile>                          # run one profile
```

`bash -n backrest lib.sh` checks syntax. No test suite exists.

## Conventions & gotchas

- Bash with `set -euo pipefail`. All functions in `lib.sh`. New backup types need: a `backup_*` function in `lib.sh`, a dispatch + dry-run case in `backrest`, an enum entry + conditional `required` in `backup.schema.json`, README + example updates.
- `sqlite` backups use restic `--stdin` with `--stdin-filename "$src"` so snapshot paths show the real source location (not a temp dir). Exception: restic 0.18.0 has a bug (#5324) where `--stdin-filename` with a directory path fails, so `restic_stdin_filename()` falls back to just the basename for that exact version.
- `check-jsonschema` requires the schema file; install via `uv tool install check-jsonschema` (preferred — no system Python needed; get `uv` itself via `curl -LsSf https://astral.sh/uv/install.sh | sh`), `pip install check-jsonschema`, or the apt package `python3-check-jsonschema` on Debian trixie+/Ubuntu 24.04+. Config validation can be skipped entirely with `--no-validate`.
- Hooks: optional `prehook`/`posthook` executable scripts per profile; they source `hooks/.env` for secrets (gitignored).