# MariaDB backup script

`mariadb_backup.sh` creates a full, compressed dump of the Home Assistant MariaDB database running in Docker, verifies it, rotates old backups and sends a signed webhook notification with the result.

## What it does

1. **Lock** – exits if another backup is already running (`/var/run/mariadb_backup.lock`).
2. **Config check** – creates the backup/log directories if needed, checks that the container is running, the password file exists and `jq`, `openssl`, `curl` are installed (when the webhook is enabled).
3. **Backup** – runs `mariadb-dump --single-transaction` inside the container and gzips the output to `mariadb_<db>_full_<YYYYmmdd_HHMMSS>.sql.gz`.
4. **Verification** – `gzip -t` integrity test and SQL line count.
5. **Rotation** – deletes backups older than `RETENTION_DAYS`.
6. **Notification** – POSTs a JSON payload to my custom notification app, signed with HMAC-SHA256 in the `X-Webhook-Signature` header.

## Requirements

- Docker with the MariaDB container running
- `gzip`, `md5sum`, `find` (GNU – uses `-printf`)
- For the webhook: `jq`, `openssl`, `curl`

```bash
sudo apt install jq openssl curl
```

## Configuration

Edit the variables at the top of the script:

| Variable | Default                        | Description |
|---|--------------------------------|---|
| `CONTAINER_NAME` | `home-assistant-db`            | MariaDB Docker container name |
| `BACKUP_DIR` | `/opt/backups/mariadb`         | Where backups are stored |
| `DB_NAME` | `homeassistant`                | Database to back up |
| `DB_USER` | `root`                         | Database user |
| `DB_PASSWORD_FILE` | `~/.docker_mariadb_backup_pwd` | File containing the DB password (falls back to `$DB_PASSWORD` env var) |
| `RETENTION_DAYS` | `7`                            | Days to keep backups |
| `LOG_DIR` | `/var/log/mariadb-backup`      | Log directory (`backup.log`) |
| `ENABLE_WEBHOOK` | `false`                        | Enable/disable notifications |
| `WEBHOOK_URL` | –                              | Webhook endpoint |
| `WEBHOOK_SECRET` | –                              | HMAC secret shared with the receiver |
| `WEBHOOK_TIMEOUT` | `10`                           | Max request time in seconds |

Create the password file:

```bash
echo 'your_password' > ~/.docker_mariadb_backup_pwd
chmod 600 ~/.docker_mariadb_backup_pwd
```

## Usage

The script writes to `/var/run`, `/var/log` and `/opt`, so run it as root:

```bash
sudo ./mariadb_backup.sh
```

### Cron (daily at 3:00)

```cron
0 3 * * * /path/to/backup-script.sh >/dev/null 2>&1
```

Logs are written to `/var/log/mariadb-backup/backup.log` (and to stderr).

## Webhook payload

> **Note:** The webhook targets my own custom notification app, not a standard Home Assistant webhook or any public service. The payload format and HMAC signature are specific to that app. If you use this script elsewhere, set `ENABLE_WEBHOOK=false` or adapt `send_webhook_notification()` to your own notification system.

```json
{
  "type": "backup",
  "title": "Backup database success",
  "message": "Home Assistant database backup completed successfully",
  "description": "Backup successful | File: ... | Size: ... | SQL lines: ... | MD5: ...",
  "severity": "info",
  "priority": "1"
}
```

`severity` / `priority`: `info`=1, `warning`=2, `critical`=3.
Signature: `X-Webhook-Signature: hex(HMAC-SHA256(secret, raw_body))`.

## Restore

Use `restore_mariadb.sh` – it checks the file and container, asks for confirmation (type `yes`), restores the dump, counts the tables and sends a webhook (success or `critical` failure, same config variables as the backup script):

```bash
sudo ./restore_mariadb.sh /opt/backups/mariadb/mariadb_homeassistant_full_<timestamp>.sql.gz
```

Manual equivalent:

```bash
gunzip -c /opt/backups/mariadb/mariadb_homeassistant_full_<timestamp>.sql.gz \
  | docker exec -i home-assistant-db mariadb -uroot -p'<password>' homeassistant
```

Stop Home Assistant before restoring.
