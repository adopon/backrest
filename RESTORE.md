# Restoring a host

Disaster recovery for a host that uses `backrest` (and typically `svcsh`).
`backrest` protects **only what git cannot**: the git-ignored instance config and
the data. Tracked code comes from git; everything git-ignored is in the restic
repos.

> **The restic password is not in any repo.** It can't be — reading a repo needs
> it, so storing it inside would be circular. Keep it **off-host**: password
> manager, printed copy, or another machine. Without it, every repo is
> unreadable. Same for the rclone remote config if it isn't snapshotted.

## What lives where

| Thing | Source of truth | Recovered by |
|-------|-----------------|--------------|
| dotfiles, scripts, svcsh/backrest code | git remotes | `git clone` |
| svcsh `global.env`, `ports.env`, `stacks/**` (compose + `.env`) | restic repo | `bootstrap.sh restore` |
| backrest `~/.config/backrest/{backup.json,hooks/.env,hooks/*.sh}` | restic repo | `bootstrap.sh restore` |
| rclone remotes (`~/.config/rclone/rclone.conf`) | restic repo **or** password manager | restore / paste |
| restic password | **off-host, never in a repo** | password manager / print |
| service data (uploads, DBs) | restic per-service repos | `bootstrap.sh restore` |

A restic snapshot is a **consistent bundle**: restoring it gives a mutually
consistent set of svcsh + backrest config at one timestamp.

## Order

1. **Base OS + tools**
   ```sh
   sudo apt install jq restic rsync rclone sqlite3
   # config validation (pick one)
   sudo apt install python3-check-jsonschema   # Debian trixie+/Ubuntu 24.04+
   # or: uv tool install check-jsonschema
   ```

2. **Clone the code** (same layout as before, e.g. `~/ops/`):
   ```sh
   git clone <svcsh-remote>    ~/ops/svcsh
   git clone <backrest-remote> ~/ops/backrest
   ```

3. **Place the restic password** (off-host copy) so restore can read the repos:
   ```sh
   install -d -m 700 ~/.config/backrest
   install -m 600 /media/usb/restic-password ~/.config/backrest/restic-password
   ```

4. **Check what's recoverable** before touching anything:
   ```sh
   cd ~/ops/backrest
   ./bootstrap.sh check   # tools, auth, per-profile repo status
   # Config resolves from ~/.config/backrest/backup.json (or BACKREST_CONFIG).
   ```

5. **Restore the config snapshots** (find exact profile names in your `backup.json`):
   ```sh
   ./bootstrap.sh restore configs --target /tmp/restore/configs
   # then copy the pieces back to where svcsh/backrest expect them:
   #   /tmp/restore/configs/.../svcsh/{global.env,ports.env,stacks/}    -> ~/.config/svcsh/
   #   /tmp/restore/configs/.../backrest/{backup.json,hooks/}            -> ~/.config/backrest/
   ```
   Restore is **non-destructive** — it writes into `--target`, you move files in.
   Verify with `./backrest --validate` and `./backrest --dry-run`.

6. **Restore the rclone config** if you didn't keep it elsewhere:
   ```sh
   ./bootstrap.sh restore credentials --target /tmp/restore/credentials
   # copy rclone.conf -> ~/.config/rclone/rclone.conf
   rclone listremotes
   ```

7. **Restore data**, one profile at a time:
   ```sh
   ./bootstrap.sh restore immich --target /srv/app-data   # or your ${app-data} root
   ```
   Restore into the bind-mount root, or into a staging dir and `mv` into place.
   For sqlite profiles the snapshot contains the consistent `.db` file.

8. **Verify, then start services**
   ```sh
   ./backrest check            # tools + auth + repo status
   ./backrest --dry-run        # what would run now
   svc up <stack>              # or docker compose up -d
   ```
   Re-run a backup once the host is healthy to confirm the whole chain end to end.

## Notes

- **Snapshots are grouped by host**; restore the host that matches the machine.
- `bootstrap.sh restore <profile> --snapshot <id>` restores a specific point in
  time; `--include <path>` limits it to one path inside the snapshot.
- **Never** copy the restic password into a repo, a `.env` that gets snapshotted,
  or git. If it may have leaked, rotate it (restic can change the repo password).
- A single-disk host keeps local repos on the same device as the data — useful
  for rollback, not for disk failure. Keep an **offsite** leg (rclone/S3 or
  another host) and test it.
