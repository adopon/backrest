# backrest

A JSON-driven backup runner wrapping [restic](https://restic.net) (incremental, deduplicated snapshots) and [rsync](https://rsync.samba.org) (mirror copies) under a single config file.

## Dependencies

- [`jq`](https://stedolan.github.io/jq/) — JSON parsing
- `restic` — for `type: restic` profiles
- `rsync` — for `type: rsync` profiles
- Optional: `check-jsonschema` or `ajv` — config validation

```bash
sudo apt install jq restic rsync
```

## Quick start

```bash
cp backup.example.json backup.json
# edit backup.json with your paths and profiles
./backrest --validate    # check config syntax
./backrest --dry-run     # preview what will run
./backrest               # run all enabled profiles
```

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

### Profile fields

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | When `false`, skipped during "run all". Can still be run explicitly. Defaults to `true`. |
| `type` | string | `restic` or `rsync` |
| `src` | string | Source path. Supports `${path}` placeholders and `host:path` remote references. |
| `repo` | string | (restic) Path to the restic repository. Created automatically. |
| `dest` | string | (rsync) Local destination directory. |
| `remote_dest` | string | (rsync) Optional second destination, e.g. `user@host:/path`. |
| `retention` | string | (restic) Restic `forget` policy. Defaults to `keep-last 10`. |
| `exclude` | array | Glob patterns to skip. |
| `prehook` | string | Script to run before backup (e.g. database dump, stop container). |
| `posthook` | string | Script to run after backup, even on failure (e.g. restart container). |
| `check` | string | Per-profile integrity check override (`full`, `quick`, `never`). |

## Usage

```
./backrest                     run all enabled profiles
./backrest photos              run a single profile
./backrest --dry-run           preview what would run
./backrest --validate          validate config against schema
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

restic needs a repository password. Generate one:

```bash
mkdir -p ~/.config/backrest
chmod 700 ~/.config/backrest
openssl rand -base64 32 | tr -d '\n' > ~/.config/backrest/restic-password
chmod 600 ~/.config/backrest/restic-password
```

Then set `restic_password_file` in `global`.

## Healthchecks.io

Set `healthchecks_url` in `global` to your check URL. backrest pings:
- `<url>/start` at the beginning
- `<url>` on success
- `<url>/fail` on failure
