# backrest

A JSON-driven backup runner wrapping [restic](https://restic.net) (incremental, deduplicated snapshots) and [rsync](https://rsync.samba.org) (mirror copies) under a single config file.

## Dependencies

- [`jq`](https://stedolan.github.io/jq/) — JSON parsing
- [`check-jsonschema`](https://github.com/python-jsonschema/check-jsonschema) — config validation
- `restic` — for `type: restic` profiles
- `rsync` — for `type: rsync` profiles
- `rclone` — for `type: s3` profiles
- `sqlite3` — for `type: sqlite` profiles

```bash
sudo apt install jq restic rsync rclone sqlite3
# config validation — pick one:
sudo apt install python3-check-jsonschema    # Debian trixie+/Ubuntu 24.04+
uv tool install check-jsonschema             # via uv (no system Python needed)
pip install check-jsonschema                 # via pip
```

If `check-jsonschema` is unavailable, backrest still runs — just add `--no-validate` to skip config validation (it only checks schema; the config is still parsed for paths, etc.).

If you don't have `uv` yet, install it once (single static binary, no system Python required):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env    # or restart your shell
```

## Quick start

```bash
cp backup.example.json backup.json
# edit backup.json with your paths and profiles
./backrest --validate    # check config syntax
./backrest --dry-run     # preview what will run
./backrest               # run all enabled profiles
```

### Editor autocomplete

`backup.json` contains a `$schema` key pointing to `backup.schema.json`. This gives JSON schema validation and autocomplete in editors with LSP support (e.g. Neovim's jsonls, VSCode). The `$schema` field is ignored by `check-jsonschema`, so it's safe to keep.

## Configuration

`backup.json` has four sections:

### `paths`

Named placeholders substituted anywhere with `${name}`:

```json
"paths": {
  "fast": "/mnt/cloud-drive",
  "storage": "/mnt/backup-drive",
  "home": "/home/you"
}
```

### `global`

Settings shared across all profiles:

| Key | Description |
|-----|-------------|
| `restic_password_file` | Path to file containing the restic repo password |
| `restic_password_command` | Command that prints the password (alternative) |
| `restic_password_autogen` | Generate a random password into `~/.config/backrest/restic-password` on first run |
| `check` | Default integrity check: `full`, `quick`, or `never` |
| `healthchecks_url` | Healthchecks.io ping URL (optional) |

### `profiles`

Each key is a profile name. Supported backends:

#### restic

Incremental, deduplicated snapshots. Requires a restic repository (auto-initialized on first run).

```json
"photos": {
  "type": "restic",
  "src": "${fast}/media/photos",
  "repo": "${storage}/backrest/photos",
  "retention": "keep-daily 7 keep-weekly 4 keep-monthly 6",
  "exclude": ["*.tmp", "cache/"],
  "check": "quick",
  "prehook": "hooks/dump-db.sh"
}
```

After each backup, restic runs the configured retention policy (`forget --prune`) followed by an integrity `check`.

#### rsync

A local mirror copy. Supports an optional `remote_dest` for off-site replication.

```json
"music": {
  "type": "rsync",
  "src": "${fast}/media/music",
  "dest": "${storage}/media/music",
  "remote_dest": "user@offsite:/backups/music"
}
```

#### s3

A mirror sync to a cloud bucket via `rclone sync`. The destination uses an rclone remote name (configured with `rclone config`), e.g. `myremote:bucket/path`.

```json
"photos-cloud": {
  "type": "s3",
  "src": "${fast}/media/photos",
  "dest": "backup-bucket:backups/photos"
}
```

Note: `rclone sync` mirrors the source — files removed locally are deleted remotely.

`flags` lets you pass extra `rclone` options. It's optional: `s3` profiles already default to `--checksum`, which compares files by checksum (ETag/SHA1) instead of size+mtime. Without a checksum comparison, rclone decides what to sync by size and modification time, so cloud-to-cloud syncs (e.g. MinIO→B2, or S3→S3) re-upload unchanged files every run when the destination's stored mtime doesn't exactly match the source's. Set `flags` only to override the default, e.g. `["--size-only"]`.

#### sqlite

Versioned snapshots of a SQLite database using `sqlite3`'s online backup API (safe while the DB is in use, handles WAL mode). The consistent snapshot is backed up into a restic repo, so you get restic's deduplication and battle-tested `forget` retention policies.

```json
"myapp-db": {
  "type": "sqlite",
  "src": "/srv/myapp/data.db",
  "repo": "${storage}/backrest/db/myapp",
  "retention": "keep-daily 7 keep-weekly 4 keep-monthly 6"
}
```

`retention` is a standard restic `forget` policy (`keep-last`, `keep-daily`, `keep-weekly`, `keep-monthly`, `keep-yearly`). Defaults to `keep-last 10`.

### Profile fields

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | When `false`, skipped during "run all". Can still be run explicitly. Defaults to `true`. |
| `type` | string | `restic`, `rsync`, `s3`, or `sqlite` |
| `src` | string | Source path. Supports `${path}` placeholders and `host:path` remote references. For sqlite, the path to the `.db` file. |
| `repo` | string | (restic/sqlite) Path to the restic repository. Created automatically. |
| `dest` | string | (rsync/s3) Local destination directory (rsync) or rclone remote path like `remote:bucket/path` (s3). |
| `remote_dest` | string | (rsync) Optional second destination, e.g. `user@host:/path`. |
| `retention` | string | (restic/sqlite) Restic `forget` policy. For sqlite: `keep-last`, `keep-daily`, `keep-weekly`, `keep-monthly`, `keep-yearly`. Defaults to `keep-last 10`. |
| `exclude` | array | Glob patterns to skip. |
| `flags` | array | (s3) Extra `rclone` flags. Defaults to `["--checksum"]`; set to override. |
| `prehook` | string | Script to run before backup (e.g. database dump, stop container). |
| `posthook` | string | Script to run after backup, even on failure (e.g. restart container). |
| `check` | string | Per-profile integrity check override (`full`, `quick`, `never`). |

## Usage

```
./backrest                     run all enabled profiles
./backrest photos              run a single profile
./backrest --dry-run           preview what would run
./backrest --validate          validate config against schema
./backrest --no-validate       skip config schema validation
./backrest --config /path/to/backup.json   use a different config
./backrest --progress          show rsync progress in terminal
```

## Hooks

Pre/post hooks are executable scripts that run around each profile. They source `hooks/.env` for secrets (git-ignored).

Copy `hooks/.env.example` to `hooks/.env` and fill in real values.

Example pre-hook that dumps a database before backup:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"
load_env_file "$SCRIPT_DIR/hooks/.env"

docker exec myapp pg_dump -U postgres > /tmp/backup.sql
```

## Scheduling

Add a crontab entry:

```
0 2 * * * /path/to/backrest >> /var/log/backrest.log 2>&1
```

Or see `SYSTEMD_TIMER.txt` for systemd timer setup.

## Logs

Logs are written to the directory set in `log_dir` (defaults to `~/.local/log/backrest`). Old logs are cleaned up based on `log_retention_days`.

## Password setup

restic needs a repository password. Either generate one manually:

```bash
mkdir -p ~/.config/backrest
chmod 700 ~/.config/backrest
openssl rand -base64 32 | tr -d '\n' > ~/.config/backrest/restic-password
chmod 600 ~/.config/backrest/restic-password
```

Then set `restic_password_file` in `global`.

Or set `"restic_password_autogen": true` in `global` and backrest generates the password into `~/.config/backrest/restic-password` on first run (reusing it on later runs). Note: existing restic repos can only be decrypted with the password they were created with, so don't switch methods on an existing repo.

## Healthchecks.io

Set `healthchecks_url` in `global` to your check URL. backrest pings:
- `<url>/start` at the beginning
- `<url>` on success
- `<url>/fail` on failure
