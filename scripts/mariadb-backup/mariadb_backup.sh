#!/bin/bash
set -euo pipefail
LOCK_FILE="/var/run/mariadb_backup.lock"

if [ -f "$LOCK_FILE" ]; then
    echo "Backup already running (lock: $LOCK_FILE). Exiting."
    exit 0
fi

trap "rm -f '$LOCK_FILE'" EXIT
touch "$LOCK_FILE"

CONTAINER_NAME="home-assistant-db"
BACKUP_DIR="/opt/backups/mariadb"
DB_NAME="homeassistant"
DB_USER="root"
DB_PASSWORD_FILE="${HOME}/.docker_mariadb_backup_pwd"
RETENTION_DAYS=7

# Logs
LOG_DIR="/var/log/mariadb-backup"
LOG_FILE="${LOG_DIR}/backup.log"
ENABLE_WEBHOOK=false
WEBHOOK_URL="http://WEBHOOK_URL"
WEBHOOK_SECRET="WEBHOOK_SECRET"
WEBHOOK_TIMEOUT=10

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

    # ===== DEBUG LOGGING =====
    log "DEBUG" "=== WEBHOOK PAYLOAD DEBUG ==="
    log "DEBUG" "Severity: $severity"
    log "DEBUG" "Title: $title"
    log "DEBUG" "Message: $message"
    log "DEBUG" "Description: $description"
    log "DEBUG" "Priority: $priority"
    log "DEBUG" "Full payload: $payload"
    log "DEBUG" "=== END WEBHOOK DEBUG ==="

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

# ============================================================================
# HELPER FUNCTIONS - GENERAL
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"  # To file
    echo "[${timestamp}] [${level}] ${message}" >&2               # To stderr

}

on_error() {
    local line_number=$1
    log "ERROR" "Error on line ${line_number}"
    send_webhook_notification "critical" "Backup database failed" \
        "Critical error during Home Assistant database backup" \
        "Backup error on line ${line_number}. Check logs: $LOG_FILE" || true
    exit 1
}

verify_config() {
    log "INFO" "Verifying configuration..."

    # backup directory
    if [ ! -d "${BACKUP_DIR}" ]; then
        log "WARN" "Directory ${BACKUP_DIR} does not exist, creating..."
        mkdir -p "${BACKUP_DIR}"
        chmod 700 "${BACKUP_DIR}"
    fi

    if [ ! -w "${BACKUP_DIR}" ]; then
        log "ERROR" "No write permission in ${BACKUP_DIR}"
        return 1
    fi

    # log directory
    if [ ! -d "${LOG_DIR}" ]; then
        mkdir -p "${LOG_DIR}"
        chmod 755 "${LOG_DIR}"
    fi

    # container
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
        log "ERROR" "Container '${CONTAINER_NAME}' is not running"
        return 1
    fi

    # password file
    if [ -n "${DB_PASSWORD_FILE}" ] && [ ! -f "${DB_PASSWORD_FILE}" ]; then
        log "ERROR" "Password file '${DB_PASSWORD_FILE}' does not exist"
        log "INFO" "Create it: echo 'your_password' > ${DB_PASSWORD_FILE} && chmod 600 ${DB_PASSWORD_FILE}"
        return 1
    fi

    # webhook - required tools
    if [ "$ENABLE_WEBHOOK" = "true" ]; then
        if ! command -v jq &> /dev/null; then
            log "ERROR" "jq not found (required for webhook). Install: sudo apt install jq"
            return 1
        fi
        if ! command -v openssl &> /dev/null; then
            log "ERROR" "openssl not found (required for HMAC). Install: sudo apt install openssl"
            return 1
        fi
        if ! command -v curl &> /dev/null; then
            log "ERROR" "curl not found (required for webhook). Install: sudo apt install curl"
            return 1
        fi
    fi

    log "INFO" "Configuration OK"
    return 0
}

# ============================================================================
# BACKUP
# ============================================================================

backup_full() {
    log "INFO" "========================================"
    log "INFO" "Starting full backup of database '${DB_NAME}'"
    log "INFO" "========================================"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/mariadb_${DB_NAME}_full_${timestamp}.sql.gz"
    local temp_file="${backup_file}.tmp"

    log "INFO" "Target file: ${backup_file}"

    local password=""
    if [ -f "${DB_PASSWORD_FILE}" ]; then
        password=$(cat "${DB_PASSWORD_FILE}")
    else
        password="${DB_PASSWORD:-}"
    fi

    if docker exec -i "${CONTAINER_NAME}" mariadb-dump \
        -u"${DB_USER}" \
        -p"${password}" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --default-character-set=utf8mb4 \
        "${DB_NAME}" 2>/dev/null | gzip > "${temp_file}"; then

        mv "${temp_file}" "${backup_file}"
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        log "INFO" "✓ Backup created (size: ${size})"
    else
        log "ERROR" "✗ mariadb-dump failed"
        rm -f "${temp_file}"
        return 1
    fi

    local checksum
    checksum=$(md5sum "${backup_file}" | awk '{print $1}')
    log "INFO" "MD5: ${checksum}"

    # IMPORTANT: only the file path goes to stdout; logs go to LOG_FILE and stderr
    echo "${backup_file}"
    return 0
}

rotate_backups() {
    log "INFO" "Rotating backups older than ${RETENTION_DAYS} days"

    local removed_count=0
    local removed_size=0

    while IFS= read -r file; do
        local size
        size=$(du -b "$file" | cut -f1)
        removed_size=$((removed_size + size))
        rm -f "$file"
        log "INFO" "Removed: $(basename "$file")"
        ((++removed_count))
    done < <(find "${BACKUP_DIR}" -name "mariadb_${DB_NAME}_*.sql.gz" -type f -mtime +${RETENTION_DAYS})

    if [ ${removed_count} -gt 0 ]; then
        local size_mb=$((removed_size / 1024 / 1024))
        log "INFO" "Removed ${removed_count} file(s), freed ~${size_mb}MB"
    else
        log "INFO" "No files to rotate"
    fi
}

verify_backup() {
    local backup_file="$1"

    log "INFO" "Verifying backup: $(basename "$backup_file")"

    if [ ! -f "${backup_file}" ]; then
        log "ERROR" "Backup file does not exist: ${backup_file}"
        return 1
    fi

    if gzip -t "${backup_file}" 2>/dev/null; then
        log "INFO" "✓ Gzip OK"
        local sql_lines
        sql_lines=$(gzip -dc "${backup_file}" 2>/dev/null | wc -l)
        log "INFO" "SQL line count: ${sql_lines}"
        # IMPORTANT: only the line count goes to stdout
        echo "$sql_lines"
        return 0
    else
        log "ERROR" "✗ Backup corrupted: $(basename "${backup_file}")"
        return 1
    fi
}

print_statistics() {
    log "INFO" "========================================"
    log "INFO" "BACKUP STATISTICS"
    log "INFO" "========================================"

    local total_count
    total_count=$(find "${BACKUP_DIR}" -name "mariadb_${DB_NAME}_*.sql.gz" -type f | wc -l)
    local total_size
    total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    local oldest
    oldest=$(find "${BACKUP_DIR}" -name "mariadb_${DB_NAME}_*.sql.gz" -type f -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2- | xargs -I {} basename {} 2>/dev/null || echo "none")
    local newest
    newest=$(find "${BACKUP_DIR}" -name "mariadb_${DB_NAME}_*.sql.gz" -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2- | xargs -I {} basename {} 2>/dev/null || echo "none")

    log "INFO" "Backup count: ${total_count}"
    log "INFO" "Disk usage: ${total_size}"
    log "INFO" "Oldest: ${oldest}"
    log "INFO" "Newest: ${newest}"
    log "INFO" "========================================"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    log "INFO" "MariaDB backup script - running as: $(whoami)"

    trap 'on_error ${LINENO}' ERR

    if ! verify_config; then
        exit 1
    fi

    local backup_success=false
    local backup_file=""
    local verification_success=false
    local sql_lines=0
    local backup_checksum=""

    # === STAGE 1: BACKUP ===
    # IMPORTANT: backup_full() prints ONLY the file path to stdout
    if backup_file=$(backup_full); then
        log "INFO" "✓ Backup stage: SUCCESS"
        backup_success=true
        backup_checksum=$(md5sum "$backup_file" | awk '{print $1}')
    else
        log "ERROR" "✗ Backup stage: FAILED"
        backup_success=false
    fi

    # === STAGE 2: VERIFICATION ===
    if [ "$backup_success" = true ]; then
        # IMPORTANT: verify_backup() prints ONLY the line count to stdout
        if sql_lines=$(verify_backup "$backup_file"); then
            log "INFO" "✓ Verification stage: SUCCESS"
            verification_success=true
        else
            log "ERROR" "✗ Verification stage: FAILED"
            verification_success=false
        fi
    fi

    # === STAGE 3: ROTATION ===
    rotate_backups
    print_statistics

    # === STAGE 4: WEBHOOK NOTIFICATION ===
    if [ "$backup_success" = true ] && [ "$verification_success" = true ]; then
        local description="Backup successful | File: $(basename "$backup_file") | Size: $(du -h "$backup_file" | cut -f1) | SQL lines: ${sql_lines} | MD5: ${backup_checksum:0:16}…"
        send_webhook_notification "info" \
            "Backup database success" \
            "Home Assistant database backup completed successfully" \
            "$description"
        log "INFO" "✓ Backup completed successfully"
    else
        local error_msg="Backup failed"
        [ "$backup_success" = false ] && error_msg="$error_msg (dump error)"
        [ "$verification_success" = false ] && error_msg="$error_msg (verification error)"

        send_webhook_notification "critical" \
            "Backup database failed" \
            "Home Assistant database backup failed" \
            "$error_msg. Check logs: $LOG_FILE"
        exit 1
    fi
}

main "$@"