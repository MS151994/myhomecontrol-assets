#!/bin/bash
set -euo pipefail

# Configuration
CONTAINER_NAME="home-assistant-db"
DB_NAME="homeassistant"
DB_USER="root"
DB_PASSWORD_FILE="/root/.docker_mariadb_backup_pwd"

# Webhook (custom notification app, same as mariadb_backup.sh)
ENABLE_WEBHOOK=false
WEBHOOK_URL="http://WEBHOOK_URL"
WEBHOOK_SECRET="WEBHOOK_SECRET"
WEBHOOK_TIMEOUT=10

log() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

json_escape() {
    local string="$1"
    string="${string//\\/\\\\}"
    string="${string//\"/\\\"}"
    string="${string//$'\n'/\\n}"
    string="${string//$'\r'/\\r}"
    string="${string//$'\t'/\\t}"
    echo "$string"
}

send_webhook_notification() {
    local severity="$1"
    local title="$2"
    local message="$3"
    local description="${4:-}"  # Optional parameter

    if [ "$ENABLE_WEBHOOK" != "true" ]; then
        log "DEBUG" "Webhook disabled (ENABLE_WEBHOOK=false)"
        return 0
    fi

    if [ -z "$WEBHOOK_SECRET" ] || [ "$WEBHOOK_SECRET" = "YOUR_SECRET_HERE" ]; then
        log "WARN" "Webhook secret not configured, skipping"
        return 0
    fi

    local priority
    case "$severity" in
        "info")       priority="1" ;;
        "warning")    priority="2" ;;
        "critical")   priority="3" ;;
        *)            priority="2" ;;
    esac

    # Escape JSON strings
    local escaped_title
    escaped_title=$(json_escape "$title")
    local escaped_message
    escaped_message=$(json_escape "$message")
    local escaped_description
    escaped_description=$(json_escape "$description")

    # Build JSON payload from escaped values
    local payload
    payload=$(cat <<EOF
{"type":"backup","title":"${escaped_title}","message":"${escaped_message}","description":"${escaped_description}","severity":"${severity}","priority":"${priority}"}
EOF
)

    # Verify the payload is valid JSON
    if ! echo "$payload" | jq empty 2>/dev/null; then
        log "ERROR" "Invalid JSON payload, skipping webhook"
        log "DEBUG" "Payload: $payload"
        return 1
    fi

    # Generate HMAC-SHA256 signature
    local signature
    signature=$(printf '%s' "$payload" \
        | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -hex \
        | awk '{print $2}')

    log "INFO" "Sending webhook ($severity): $title"

    # Send the webhook
    local http_code
    local response_file="/tmp/webhook_response_$$.txt"

    http_code=$(curl -sS \
        -o "$response_file" \
        -w "%{http_code}" \
        -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "X-Webhook-Signature: $signature" \
        --data "$payload" \
        --connect-timeout 5 \
        --max-time "$WEBHOOK_TIMEOUT" \
        2>/dev/null || echo "000")

    case "$http_code" in
        200|201|204)
            log "INFO" "✓ Webhook sent OK (HTTP $http_code)"
            ;;
        *)
            log "WARN" "⚠ Webhook returned HTTP $http_code"
            if [ -f "$response_file" ] && [ -s "$response_file" ]; then
                log "WARN" "Server response:"
                sed 's/^/  /' "$response_file" | while IFS= read -r line; do
                    log "WARN" "$line"
                done
            fi
            ;;
    esac

    rm -f "$response_file"
    return 0
}

on_error() {
  local line_number=$1
  log ERROR "Error on line ${line_number}"
  send_webhook_notification "critical" "Restore database failed" \
      "Home Assistant database restore failed" \
      "Restore error on line ${line_number}. File: ${BACKUP_FILE:-unknown}" || true
  exit 1
}

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/backup.sql.gz" >&2
  exit 1
fi

BACKUP_FILE="$1"

# File check
if [ ! -f "$BACKUP_FILE" ]; then
  log ERROR "Backup file does not exist: $BACKUP_FILE"
  exit 1
fi

# Confirmation
echo "WARNING: RESTORE WILL OVERWRITE data in database '${DB_NAME}' in container '${CONTAINER_NAME}'!"
read -r -p "Continue? Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  log INFO "Aborted by user."
  exit 0
fi

# Webhook - required tools
if [ "$ENABLE_WEBHOOK" = "true" ]; then
  for tool in jq openssl curl; do
    if ! command -v "$tool" &> /dev/null; then
      log ERROR "$tool not found (required for webhook). Install: sudo apt install $tool"
      exit 1
    fi
  done
fi

# Failures from here on trigger a critical webhook
trap 'on_error ${LINENO}' ERR

# Password
if [ ! -f "$DB_PASSWORD_FILE" ]; then
  log ERROR "Password file not found: $DB_PASSWORD_FILE"
  false
fi
PASS=$(cat "$DB_PASSWORD_FILE")

# Container check
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
  log ERROR "Container '${CONTAINER_NAME}' is not running"
  false
fi

log INFO "Verifying gzip..."
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
  log ERROR "Backup file corrupted (gzip test failed)"
  false
fi

log INFO "Restoring from: $BACKUP_FILE to database: $DB_NAME (container: $CONTAINER_NAME)"
START=$(date +%s)

# Actual restore:
# gzip -dc => SQL to STDOUT => docker exec runs the `mariadb` client inside the container
gzip -dc "$BACKUP_FILE" \
  | docker exec -i "$CONTAINER_NAME" mariadb \
      -u"$DB_USER" -p"$PASS" "$DB_NAME"

END=$(date +%s)
log INFO "Restore finished. Time: $((END-START)) s"

# Simple check - can we count the tables
log INFO "Verifying database after restore..."
TABLES_CNT=$(docker exec "$CONTAINER_NAME" mariadb -u"$DB_USER" -p"$PASS" "$DB_NAME" -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
log INFO "Tables in '${DB_NAME}': ${TABLES_CNT}"

send_webhook_notification "info" \
    "Restore database success" \
    "Home Assistant database restore completed successfully" \
    "Restore successful | File: $(basename "$BACKUP_FILE") | Time: $((END-START)) s | Tables: ${TABLES_CNT}"

log INFO "Done."
