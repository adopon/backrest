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
install -d -m 700 ~/.config/backrest
cp backup.example.json ~/.config/backrest/backup.json
# edit ~/.config/backrest/backup.json with your paths and profiles
./backrest --validate    # check config syntax
./backrest --dry-run     # preview what will run
./backrest               # run all enabled profiles
```

The instance config lives outside the checkout at
`~/.config/backrest/backup.json` (XDG-aware), next to the restic password and
instance hooks. A `backup.json` inside the checkout still works as a legacy
fallback.

### Editor autocomplete

`backup.json` can contain a `$schema` key pointing to `backup.schema.json`. When
the config lives outside the repo, use the checkout's absolute path, e.g.
`"$schema": "/home/you/ops/backrest/backup.schema.json"`. This gives JSON
schema validation and autocomplete in editors with LSP support (e.g. Neovim's
jsonls, VSCode). The `$schema` field is ignored by `check-jsonschema`, so it's
safe to keep.

## Configuration

The instance `backup.json` has four sections:

### `paths`

Named placeholders substituted anywhere with `${name}`:

```json
"paths": {
  "fast": "/mnt/ssd",
  "storage": "/mnt/hdd",
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
| `restic_compression` | restic `--compression` mode (`auto`, `max`, `off`) |
| `env_file` | Default `KEY=VALUE` file loaded for every profile (e.g. cloud credentials); a profile-level `env_file` overrides it |
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
  "require_mount": "${storage}",
  "check": "quick",
  "prehook": "hooks/dump-db.sh"
}
```

After each backup, restic runs the configured retention policy (`forget --prune`) followed by an integrity `check`.

`repo` may also be a remote backend URL. Local repos are created with `mkdir`;
remote repos are initialized with `restic init` and checked with
`restic cat config`, so the profile works unchanged against S3/B2. See
[Cloud repositories and credentials](#cloud-repositories-and-credentials) below.

`require_mount` guards a profile against an **unmounted** directory. If `${storage}` isn't mounted, restic would otherwise initialize a fresh repo in the empty mount-point directory and back up there (and `rclone sync` would mirror that emptiness over the remote). With `require_mount` set, the profile refuses to run until the path is a real mount point. It works on every profile type (restic/rsync/s3/sqlite).

### Cloud repositories and credentials

A `restic` profile can target a remote repository instead of a local path. For
Backblaze B2, use the **S3-compatible API** — restic's own docs recommend it over
the native `b2:` backend because of error-handling issues:

```json
"photos-offsite": {
  "type": "restic",
  "src": "${fast}/media/photos",
  "repo": "s3:https://s3.eu-central-003.backblazeb2.com/my-bucket/photos",
  "retention": "keep-daily 7 keep-weekly 4 keep-monthly 12",
  "env_file": "~/.config/backrest/b2.env",
  "flags": ["--limit-upload", "8000"]
}
```

restic's S3 backend reads its credentials from standard AWS environment
variables, so `env_file` is how they reach it:

| Variable | Value |
|----------|-------|
| `AWS_ACCESS_KEY_ID` | B2 application key ID (S3-compatible key) |
| `AWS_SECRET_ACCESS_KEY` | B2 application key (secret) |
| `AWS_DEFAULT_REGION` | bucket region, e.g. `eu-central-003` |

The file is a plain `KEY=VALUE` list (same syntax as `hooks/.env`); keep it
`chmod 600`. It is parsed as data — like systemd's `EnvironmentFile=` or
Docker's `--env-file` — rather than `source`d, so it cannot execute shell code.
`env_file` can be set in `global` (applies to every profile) or per
profile (applied only to that profile's restic and hook subprocesses, so
credentials never leak into unrelated profiles). A profile-level `env_file`
overrides the global one. Relative paths resolve against the config file's
directory, so `env_file: "b2.env"` next to `backup.json` works.

Other notes:

- Create the bucket in the B2 UI first. A bucket-scoped key usually cannot
  create buckets, and restic will not adjust lifecycle settings for you.
- Add the lifecycle rule **“Keep only the last version of the file”** (e.g. 1
  day). restic's S3 backend hides deleted objects instead of deleting them; B2
  keeps billing for hidden versions without this rule.
- For the first upload, throttle with `flags`: `["--limit-upload", "8000"]`
  (KiB/s). Flags are passed to the `restic backup` command only.
- `--limit-upload` is a global restic flag, so it is also accepted on
  `init`/`forget`/`check`; only the backup command receives profile `flags`.
- The repo password is still the global restic password (`restic_password_file`),
  so keep an off-host copy of it — the B2 data is unreadable without it.
- `bootstrap.sh check` / `restore` load the same `env_file` and probe remote
  repos with `restic cat config`, so disaster recovery from B2 works from the
  same config.

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
  "dest": "backup-bucket:backups/photos",
  "exclude": ["thumbs/", "*.tmp"]
}
```

Note: `rclone sync` mirrors the source — files removed locally are deleted remotely.

`exclude` works here too (passed to `rclone --exclude`), as it does for `restic` and `rsync` profiles — useful for skipping caches or transient files.

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
| `repo` | string | (restic/sqlite) Path to the restic repository, or a backend URL (`s3:https://...`, `b2:bucket:path`, `rclone:remote:path`). Local repos are created automatically; remote repos are initialized with `restic init`. |
| `dest` | string | (rsync/s3) Local destination directory (rsync) or rclone remote path like `remote:bucket/path` (s3). |
| `remote_dest` | string | (rsync) Optional second destination, e.g. `user@host:/path`. |
| `require_mount` | string | Path that must be a mount point or the profile refuses to run. Guards destructive syncs/prunes against an unmounted (empty) directory. |
| `retention` | string | (restic/sqlite) Restic `forget` policy. For sqlite: `keep-last`, `keep-daily`, `keep-weekly`, `keep-monthly`, `keep-yearly`. Defaults to `keep-last 10`. |
| `exclude` | array | (restic/rsync/s3) Glob patterns to skip. |
| `flags` | array | (s3) Extra `rclone` flags; defaults to `["--checksum"]`. (restic/sqlite) Extra restic flags for the backup command, e.g. `["--limit-upload", "8000"]`. |
| `env_file` | string | `KEY=VALUE` file applied only to this profile (credentials for remote repos). Overrides `global.env_file`. |
| `prehook` | string | Script to run before backup (e.g. database dump, stop container). |
| `posthook` | string | Script to run after backup, even on failure (e.g. restart container). |
| `check` | string | Per-profile integrity check override (`full`, `quick`, `never`). |
| `require_mount` | string | Path that must be a mount point or the profile refuses to run. Guards destructive syncs/prunes against an unmounted (empty) directory. |

## Usage

```
./backrest                     run all enabled profiles
./backrest run photos          run a single profile
./backrest snapshots photos    list restic snapshots for a restic/sqlite profile
./backrest logs                follow the live backup log (like `docker logs -f`)
./backrest --dry-run           preview what would run
./backrest --validate          validate config against schema
./backrest --no-validate       skip config schema validation
./backrest --config /path/to/backup.json   use a different config
./backrest --progress          show rsync progress in terminal
./backrest --follow, -f  follow the live backup log (like `docker logs -f`)
```

The first positional argument may be an action (`run`, `snapshots`, `logs`); a bare profile name is treated as `run <profile>` for backwards compatibility.

The config file is resolved in this order: `--config PATH` (explicit), `$BACKREST_CONFIG`, `$XDG_CONFIG_HOME/backrest/backup.json` (default `~/.config/backrest/backup.json`), `backup.json` next to the script, then the single `backup*.json` (e.g. `backup-laptop.json`; `backup.example.json`/`backup.schema.json` excluded) so per-machine configs work without `--config`. If several `backup*.json` files exist, backrest refuses to guess and asks for `BACKREST_CONFIG` or `--config` — point `BACKREST_CONFIG` at the right one in your shell config per machine.

Each run's log is written to `log_dir/backup-<timestamp>.log`; `backup-current.log` is a symlink to the most recent one. `./backrest logs` tails it and follows across runs (`tail -F`).

### Shell completion

Tab-completion for bash, zsh, and fish, with profile names derived live from the config (the `snapshots` action only completes restic/sqlite profiles). The completion resolves the config the same way the script does: `--config` on the command line, `$BACKREST_CONFIG`, `~/.config/backrest/backup.json`, `backup.json`, then the first `backup*.json`. After `--config`, it completes config file paths. Install once with:

```bash
./install.sh              # detect shell and install
./install.sh fish         # or pick a shell explicitly
./install.sh --remove     # uninstall
```

This adds `backrest` to `PATH` and sources the completion (block in `~/.bashrc` / `~/.zshrc`, or files in `~/.config/fish/completions/`). Set `BACKREST_CONFIG` to make completions read a different config file.

## Hooks

Pre/post hooks are executable scripts that run around each profile. They source
`~/.config/backrest/hooks/.env` for secrets (git-ignored). The checkout's legacy
`hooks/.env` is still read as a fallback.

Copy `hooks/.env.example` to `~/.config/backrest/hooks/.env` and fill in real
values. Point profile `prehook`/`posthook` paths at
`${home}/.config/backrest/hooks/...`.

Example pre-hook that dumps a database before backup:

```bash
#!/usr/bin/env bash
set -euo pipefail
BACKREST_HOME="${BACKREST_HOME:-$HOME/ops/backrest}"
source "$BACKREST_HOME/lib.sh"
load_env_file "$HOME/.config/backrest/hooks/.env"

docker exec myapp pg_dump -U postgres > /tmp/backup.sql
```

### Consistent SQLite snapshots

Copying a live SQLite file can capture a torn WAL/database state. The tracked
example `hooks/sqlite-backup.sh.example` (install to
`~/.config/backrest/hooks/sqlite-backup.sh`, chmod 700) dumps databases with
SQLite's online backup API — safe while the database is in use, WAL included —
and verifies each dump with `PRAGMA quick_check`. It only **reads** live
databases: no live file is overwritten and no service is stopped.

`~/.config/backrest/sqlite-dbs.conf` accepts, one per line:

- a **directory** — scanned recursively for `*.db` / `*.sqlite` / `*.sqlite3`;
  dumps go to `<directory>/_sqlite-dumps/<same relative path>`
- a **file or glob** — dumped to `~/.local/share/backrest/sqlite-dumps/`
- `!pattern` — fnmatch exclusion (e.g. `!*/syncthing/index-v2/*`, `!*.bak*`)

Because dumps land inside the tree they belong to, the ordinary profile for
that tree (`homelab-data`, `web-data`) contains configuration **and** consistent
databases in one snapshot — restore one thing, get everything. Attach the hook
as the prehook of that profile:

```json
"homelab-data": {
  "type": "restic",
  "src": "${fast}/services/homelab",
  "repo": "${storage}/backup/restic/homelab-data",
  "exclude": [
    "${fast}/services/homelab/forgejo",
    "${fast}/services/homelab/prowlarr/asp",
    "${fast}/services/homelab/paperless"
  ],
  "prehook": "${home}/.config/backrest/hooks/sqlite-backup.sh"
}
```

Exclude patterns are matched against the full path, so a leading `/` means an
**absolute filesystem path** — not "relative to the backup root". Use absolute
paths (as above) when the excluded live tree has a sidecar under
`_sqlite-dumps/<name>/` that must stay included. A bare basename pattern such
as `forgejo` would also drop `_sqlite-dumps/forgejo/...`.

Every candidate is checked against the `SQLite format 3` file header, so
non-database `.db` files, WAL/SHM files and shelve files are skipped
automatically; `_sqlite-dumps` itself is never rescanned. New services are
picked up without touching the config. Databases owned by another service user
are retried with passwordless `sudo` when available — opening a WAL database
read-write needs write access. `sqlite-backup.sh --list` prints exactly which
databases would be dumped, and each `_sqlite-dumps/_status.txt` records
ok/FAIL per database.

Restore: after restoring the snapshot tree, copy each dump over its live path
with the service stopped, e.g.

```sh
cp _sqlite-dumps/vaultwarden/db.sqlite3 vaultwarden/db.sqlite3
```

`VACUUM` is a maintenance operation, not a consistency mechanism — `.backup` is
what makes the copy safe.

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

Keep an **off-host copy** of that password: it is the one secret no repo can contain (reading a repo needs it), so without it every snapshot is unreadable.

## Disaster recovery

`backrest` only protects what git cannot — the git-ignored instance config and the data. To rebuild a host, restore the tracked code from git and everything else from the restic repos. `bootstrap.sh` reads the same `~/.config/backrest/backup.json` and restic auth as backrest so recovery doesn't depend on remembering paths:

```bash
./bootstrap.sh check                                  # tools + auth + repo status
./bootstrap.sh restore <profile> --target DIR         # latest snapshot into DIR (non-destructive)
./bootstrap.sh restore <profile> --snapshot <id>      # a specific point in time
```

The full rebuild order (base OS, git clones, password placement, config then data, verification) is in [RESTORE.md](RESTORE.md).

## Healthchecks.io

Set `healthchecks_url` in `global` to your check URL. backrest pings:
- `<url>/start` at the beginning
- `<url>` on success
- `<url>/fail` on failure
