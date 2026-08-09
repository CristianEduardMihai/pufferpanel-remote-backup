# PufferPanel Remote Backup

A self-contained bash script that backs up a game server hosted on a
**remote** [PufferPanel](https://www.pufferpanel.com/) node from a
**local** machine, via cron. It stops the server through the PufferPanel
API, compresses the server's data on the remote host, verifies the archive
isn't corrupt, restarts the server immediately, then pulls the backup down
and rotates old copies — with a trap-based safety net that restarts the
server even if the script fails partway through.

Includes an interactive `setup.sh` for the one-time remote-side
configuration (backup user, sudo rule, `zip`), and optional WhatsApp
failure alerts via [CallMeBot](https://www.callmebot.com/blog/free-api-whatsapp-messages/).

## Why

PufferPanel has an API to control servers (stop/start/status) but no
built-in *remote* backup feature. This bridges that gap for a setup where
the panel/daemon runs on one machine and you want backups pulled onto a
separate machine (e.g. your NAS or home server) on a schedule.

## How it works

1. Authenticate to the PufferPanel API (OAuth2 `client_credentials`)
2. Stop the server, poll until it's confirmed stopped, then wait a bit
   longer to let file locks release
3. On the remote host: compress the server's data directory with `zip`,
   then run `zip -T` to verify the archive isn't truncated or corrupt
4. **Restart the server immediately** — it does not stay down for the
   file transfer
5. Copy the verified archive to the local machine, timestamped
6. Delete old local backups beyond the configured retention count
7. If anything fails, a trap ensures the server gets a start request
   regardless — and optionally sends a WhatsApp alert

Only one archive is ever kept on the remote host (overwritten each run,
to save space there); local copies are timestamped and rotated.

## Prerequisites

**Local machine** (where `puff-backup.sh` runs, e.g. via cron):
- `bash`, `curl`, `ssh`, `scp`
- `jq` recommended (there's a `grep` fallback if it's missing)

**Remote host** (running PufferPanel):
- `bash`, `sudo`
- `zip` (installed automatically by `setup.sh`)

**PufferPanel:**
- An OAuth2 client (create one in the panel's admin settings)

## Quick start

### 1. Generate an SSH key (local machine)

The key must have **no passphrase** — cron can't type one in.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pufferpanel_backup_key -N ""
```

### 2. Run the remote setup (on the PufferPanel host, as root)

Copy `setup.sh` to the remote host and run it there:

```bash
sudo ./setup.sh
```

It will interactively:
- Create (or reuse) a dedicated, non-root backup user
- Install your SSH public key for that user (or let you skip this if
  it's already in `authorized_keys`)
- Create the remote staging directory for the backup archive
- Install `zip` if it isn't already present
- Write a **narrow, passwordless sudo rule** scoped to exactly two
  binaries (`zip` and `chown`) resolved to their real paths on that
  host — nothing else, and specifically *not* the package manager
- Validate the sudoers file with `visudo -c` before activating it, and
  remove it again if validation fails
- Verify passwordless sudo actually works before finishing

Root SSH login is assumed to be disabled (the common case), and PufferPanel
running in Docker means its data directory is root-owned — that's why a
dedicated user with a couple of narrowly scoped `sudo` rights is used
instead of either enabling root login or giving the backup user broad sudo.

### 3. Configure `puff-backup.sh` (local machine)

Open `puff-backup.sh` and fill in the `CONFIGURATION` block at the top:

| Variable | Description |
|---|---|
| `PANEL_URL` | PufferPanel base URL, no trailing slash |
| `CLIENT_ID` / `CLIENT_SECRET` | OAuth2 client credentials |
| `SERVER_ID` | PufferPanel server UUID |
| `REMOTE_HOST` | Remote daemon IP/hostname |
| `REMOTE_USER` | The backup user created by `setup.sh` |
| `REMOTE_SSH_KEY` | Path to the private key from step 1 |
| `REMOTE_SSH_PORT` | SSH port (default `22`) |
| `REMOTE_BACKUP_DIR` | Remote staging dir (matches what `setup.sh` created) |
| `PUFFERPANEL_DATA_DIR` | Remote path to PufferPanel's `servers` dir |
| `LOCAL_BACKUP_DIR` | Where local timestamped backups are stored |
| `LOCAL_BACKUP_KEEP` | How many local backups to retain |
| `STOP_TIMEOUT` / `STOP_POLL_INTERVAL` | Polling behavior while waiting for stop |
| `STOP_WAIT_SECONDS` | Extra wait after stop, before compressing |
| `ZIP_COMPRESSION_LEVEL` | `zip` compression level, 0–9 |
| `CALLMEBOT_ENABLED` / `CALLMEBOT_PHONE` / `CALLMEBOT_APIKEY` | Optional WhatsApp alerts, see below |

### 4. Test it

```bash
chmod +x puff-backup.sh
DEBUG=1 ./puff-backup.sh
```

`DEBUG=1` prints every API call, response, and status code so you can see
exactly where things stand if something doesn't work.

### 5. Add it to cron

```cron
0 3 * * * /path/to/puff-backup.sh >> /path/to/puff-backup.log 2>&1
```

## WhatsApp failure alerts (optional)

If the zip integrity check fails on the remote host, the script can send
you a WhatsApp message via the free [CallMeBot API](https://www.callmebot.com/blog/free-api-whatsapp-messages/):

1. Add the CallMeBot contact (`+34 644 20 47 56`) in WhatsApp
2. Send it the message: `I allow callmebot to send me messages`
3. Within ~2 minutes it replies with an API key
4. Set `CALLMEBOT_PHONE` (with country code(without the +), e.g. `15551234567`) and
   `CALLMEBOT_APIKEY` in `puff-backup.sh`

Set `CALLMEBOT_ENABLED="false"` to disable this entirely. It's best-effort
— if CallMeBot is unreachable or unconfigured, the script logs a warning
and continues normally rather than failing the backup over it.

Currently wired to only the zip-integrity-failure case. `notify_whatsapp()`
is a standalone function, so it's easy to call from other failure points
(e.g. from `cleanup()`) if you want broader alerting.

## Debug options

Both are set as environment variables prefixed on the command, without
editing the script:

```bash
# Verbose logging: every API call, HTTP status, and response body
DEBUG=1 ./puff-backup.sh

# Deliberately corrupt the archive right after creation, to test the
# integrity-check failure path (including the WhatsApp alert and the
# server-restart safety net). Only ever touches the disposable zip file
# on the remote host — never your actual server data.
SIMULATE_ZIP_CORRUPTION=true ./puff-backup.sh

# Combine both for a full end-to-end failure test:
SIMULATE_ZIP_CORRUPTION=true DEBUG=1 ./puff-backup.sh
```

With `DEBUG=1`, the very first debug line printed is
`SIMULATE_ZIP_CORRUPTION=...` — a quick way to confirm the flag actually
reached the script (e.g. it won't if you accidentally run the script via
`sudo` without `sudo -E`, since `sudo` strips environment variables by
default).

## Security notes

- The backup user's sudo access is limited to the exact resolved paths of
  `zip` and `chown` — never a shell (`sudo bash -c ...` is deliberately
  avoided everywhere, since a binary whitelist doesn't cover an arbitrary
  shell and would just fall back to a password prompt over SSH, which
  fails non-interactively anyway)
- The package manager is never included in the sudo rule; `zip` is
  installed once during `setup.sh` and the backup script simply refuses
  to run if it's ever missing afterward
- `PANEL_URL`, `CLIENT_ID`, and `CLIENT_SECRET` are stored in plaintext in
  the config — keep the script's permissions restrictive
  (`chmod 600 puff-backup.sh`) and don't commit a filled-in copy to a
  public repo

## Troubleshooting

**`sudo: a password is required`** — the sudoers rule doesn't cover the
exact command being run, or was written as `sudo bash -s`/`sudo bash -c`
instead of the individual binary. Re-run `setup.sh`, or check
`sudo -l -U <backup_user>` as root on the remote host to see what's
actually authorized.

**`Permission denied (publickey)`** — either the wrong private key path in
`REMOTE_SSH_KEY`, or the public key isn't in that user's
`authorized_keys` on the remote host. `setup.sh` can add it for you.

**`REMOTE_USER is 'root'` config error** — root SSH login is assumed
disabled; use a non-root user with the sudo rule from `setup.sh` instead.

**Server never comes back up after a failure** — shouldn't happen; the
`trap cleanup EXIT` sends a start request on any exit path where the
server was left stopped. If it does happen, check the log for whether
`get_token` inside `cleanup()` also failed (e.g. panel unreachable).
