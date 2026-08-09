#!/usr/bin/env bash
set -euo pipefail

DEBUG="${DEBUG:-0}"  # Set DEBUG=1 to enable verbose output

# ============================================================
# CONFIGURATION — edit everything below
# ============================================================

PANEL_URL="http://YOUR_PUFFERPANEL_HOST:8080"  # PufferPanel panel base URL (no trailing slash)
CLIENT_ID="your-oauth2-client-id"
CLIENT_SECRET="your-oauth2-client-secret"
SERVER_ID="your-server-uuid"                # PufferPanel server UUID

REMOTE_HOST="your.remote.host.or.ip"        # IP or hostname of the daemon server
REMOTE_USER="puffbackup"                    # SSH user on the remote daemon host.
                                              # Root SSH login is disabled on this host, so this MUST
                                              # be a non-root user. Since PufferPanel runs in Docker
                                              # and its data dir is owned by root, this user needs
                                              # passwordless sudo for a few specific commands — see
                                              # "REMOTE SETUP REQUIRED" below.
REMOTE_SSH_KEY="$HOME/.ssh/pufferpanel_backup_key"  # Path to SSH private key for key auth.
                                              # This key must NOT have a passphrase (cron can't type one).
                                              # If it currently has one, strip it on the LOCAL machine with:
                                              #   ssh-keygen -p -f "$REMOTE_SSH_KEY" -N ""
REMOTE_SSH_PORT="22"                        # SSH port
REMOTE_BACKUP_DIR="/home/${REMOTE_USER}/backups"  # Remote dir for the single on-host backup
REMOTE_BACKUP_FILENAME="${SERVER_ID}.zip"   # Single backup filename (overwritten each run)
PUFFERPANEL_DATA_DIR="/var/lib/pufferpanel/servers"  # Remote path to server data (root-owned)

LOCAL_BACKUP_DIR="$HOME/backups"            # Where local timestamped backups are stored
LOCAL_BACKUP_KEEP="5"                       # Number of local backups to retain (prune oldest)

STOP_TIMEOUT="200"                          # Max seconds to wait for server stop (poll)
STOP_POLL_INTERVAL="5"                      # Seconds between status polls

STOP_WAIT_SECONDS="15"                      # Seconds to wait after stop request before compressing
ZIP_COMPRESSION_LEVEL="5"                   # zip compression level (0–9, 5 is default)

CALLMEBOT_ENABLED="true"                    # Set to "false" to disable WhatsApp alerts entirely
CALLMEBOT_PHONE=""                          # Your WhatsApp number with country code(without the +), e.g. 40712345678
CALLMEBOT_APIKEY=""                         # Your CallMeBot apikey — get one at:
                                              # https://www.callmebot.com/blog/free-api-whatsapp-messages/

SIMULATE_ZIP_CORRUPTION="${SIMULATE_ZIP_CORRUPTION:-false}"
                                              # TEST ONLY. If "true", the archive is deliberately
                                              # corrupted right after creation, before the zip -T check.
                                              # Never touches actual server data — only the disposable
                                              # zip file. Use it as a one-off env var, don't edit this
                                              # line: SIMULATE_ZIP_CORRUPTION=true ./puff-backup.sh

# ============================================================
# REMOTE SETUP REQUIRED (one-time, on the remote host as root)
# ============================================================
# Because PufferPanel's data dir is root-owned (Docker), REMOTE_USER needs
# passwordless sudo for exactly the commands this script runs remotely.
# Create /etc/sudoers.d/puff-backup on the remote host with (edit paths to match):
#
#   puffbackup ALL=(root) NOPASSWD: /usr/bin/zip, /usr/bin/chown
#
# (replace "puffbackup" with whatever REMOTE_USER you actually used)
#
# Only zip (reads root-owned server files) and chown (hands the resulting
# archive back to you) get sudo — the package manager is deliberately left
# out. zip is installed once by setup.sh; this script only ever checks for
# it at runtime and refuses to proceed if it's missing, rather than trying
# to install it (which would need package-manager sudo access we're not
# granting). Also note: sudo must NOT be invoked
# as `sudo bash -c ...` / `sudo bash -s` anywhere — a whitelist on
# individual binaries does not cover an arbitrary shell, so sudo would
# fall back to a password prompt (which fails over non-interactive SSH).
# Each privileged command below is run individually for this reason.
#
# Then `visudo -c -f /etc/sudoers.d/puff-backup` to validate syntax.
# Also make sure REMOTE_USER's SSH public key is in
# /home/<REMOTE_USER>/.ssh/authorized_keys on the remote host, and that
# REMOTE_BACKUP_DIR is writable by REMOTE_USER.
# ============================================================
#
# setup.sh (in this repo) automates all of the above interactively.

# ============================================================
# END CONFIGURATION
# ============================================================

# ---- Derived / Internal Variables ----
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOCAL_BACKUP_FILE="${LOCAL_BACKUP_DIR}/${SERVER_ID}_${TIMESTAMP}.zip"
REMOTE_SERVER_DATA_DIR="${PUFFERPANEL_DATA_DIR}/${SERVER_ID}"
REMOTE_ZIP_PATH="${REMOTE_BACKUP_DIR}/${REMOTE_BACKUP_FILENAME}"

API_BASE="${PANEL_URL}/api"

# ---- Global state ----
SERVER_STOPPED="false"
TOKEN=""
API_HTTP_STATUS=""
API_RESPONSE_BODY=""

# ============================================================
# FUNCTIONS
# ============================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] $*"
}

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [DEBUG] $*" >&2
    fi
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# Best-effort — a failed notification should never take down the script,
# so this never calls die() and any curl failure is just logged.
notify_whatsapp() {
    local message="$1"

    if [[ "$CALLMEBOT_ENABLED" != "true" ]]; then
        return 0
    fi
    if [[ -z "$CALLMEBOT_PHONE" || -z "$CALLMEBOT_APIKEY" ]]; then
        log "WARN: WhatsApp notification skipped — CALLMEBOT_PHONE/CALLMEBOT_APIKEY not set."
        return 0
    fi

    local response
    response="$(curl -s -G "https://api.callmebot.com/whatsapp.php" \
        --data-urlencode "phone=${CALLMEBOT_PHONE}" \
        --data-urlencode "apikey=${CALLMEBOT_APIKEY}" \
        --data-urlencode "text=${message}" 2>&1)" || true

    debug "CallMeBot response: $response"

    if echo "$response" | grep -qi "error\|invalid"; then
        log "WARN: WhatsApp notification may have failed: $response"
    else
        log "WhatsApp notification sent."
    fi
}

# ---- SSH helpers (arrays, not strings — avoids the "quoted multi-word
#      variable executed as a single command" bug) ----

ssh_run() {
    # Run a single remote command, connecting as REMOTE_USER (non-root).
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "$REMOTE_SSH_KEY" -p "$REMOTE_SSH_PORT" \
        "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

scp_get() {
    # scp_get <remote_path> <local_path>
    scp -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "$REMOTE_SSH_KEY" -P "$REMOTE_SSH_PORT" \
        "${REMOTE_USER}@${REMOTE_HOST}:$1" "$2"
}

validate_config() {
    local errors=0

    for var in PANEL_URL CLIENT_ID CLIENT_SECRET SERVER_ID \
               REMOTE_HOST REMOTE_USER REMOTE_SSH_KEY REMOTE_SSH_PORT \
               REMOTE_BACKUP_DIR PUFFERPANEL_DATA_DIR \
               LOCAL_BACKUP_DIR LOCAL_BACKUP_KEEP; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR: Config variable $var is empty"
            errors=$((errors + 1))
        fi
    done

    if [[ "$REMOTE_USER" == "root" ]]; then
        log "ERROR: REMOTE_USER is 'root' but root SSH login is disabled on this host. Use a non-root user with sudo instead."
        errors=$((errors + 1))
    fi

    if [[ "$CALLMEBOT_ENABLED" == "true" && ( -z "$CALLMEBOT_PHONE" || -z "$CALLMEBOT_APIKEY" ) ]]; then
        log "WARN: CALLMEBOT_ENABLED is true but CALLMEBOT_PHONE/CALLMEBOT_APIKEY is empty — WhatsApp alerts will be skipped."
    fi

    if [[ ! -f "$REMOTE_SSH_KEY" ]]; then
        log "ERROR: SSH key not found at $REMOTE_SSH_KEY"
        errors=$((errors + 1))
    fi

    mkdir -p "$LOCAL_BACKUP_DIR" 2>/dev/null || {
        log "ERROR: Cannot write to LOCAL_BACKUP_DIR ($LOCAL_BACKUP_DIR)"
        errors=$((errors + 1))
    }

    if [[ $errors -gt 0 ]]; then
        die "Configuration validation failed ($errors error(s))"
    fi
}

get_token() {
    local response
    response="$(curl -s -X POST "${PANEL_URL}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}")"

    debug "OAuth2 response: $response"

    if [[ -z "$response" ]]; then
        die "OAuth2 token request returned empty response. Check PANEL_URL and credentials."
    fi

    if echo "$response" | grep -q '"error"'; then
        die "OAuth2 token request failed: $response"
    fi

    local token
    if command -v jq &>/dev/null; then
        token="$(echo "$response" | jq -r '.access_token // empty')"
    else
        token="$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"
    fi

    if [[ -z "$token" ]]; then
        die "OAuth2 response did not contain access_token. Response: $response"
    fi

    debug "Token obtained successfully"
    echo "$token"
}

# Sets API_HTTP_STATUS and API_RESPONSE_BODY globals instead of relying on
# a captured $? — the previous version's status code never left the function.
api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local url="${API_BASE}${endpoint}"
    debug "API call: $method $url"

    local response
    response="$(curl -s -w '\n%{http_code}' \
        -X "$method" "$url" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "$@")"

    API_HTTP_STATUS="$(echo "$response" | tail -1)"
    API_RESPONSE_BODY="$(echo "$response" | sed '$d')"

    debug "API response status: $API_HTTP_STATUS"
    debug "API response body: $API_RESPONSE_BODY"
}

stop_server() {
    log "Sending stop request to server..."
    api_call POST "/servers/${SERVER_ID}/stop?skipRestart=true"

    if [[ "$API_HTTP_STATUS" != "202" && "$API_HTTP_STATUS" != "204" ]]; then
        log "WARN: stop_server returned HTTP $API_HTTP_STATUS (expected 202/204)"
    fi
}

get_status() {
    api_call GET "/servers/${SERVER_ID}/status"

    if [[ "$API_HTTP_STATUS" != "200" ]]; then
        log "WARN: get_status returned HTTP $API_HTTP_STATUS"
        return 1
    fi

    local running
    if command -v jq &>/dev/null; then
        running="$(echo "$API_RESPONSE_BODY" | jq -r '.running')"
    else
        running="$(echo "$API_RESPONSE_BODY" | grep -o '"running":[[:space:]]*[^,}]*' | grep -o 'true\|false')"
    fi

    debug "get_status running=$running"
    [[ "$running" == "true" ]]
}

wait_for_stop() {
    log "Polling server status (timeout: ${STOP_TIMEOUT}s)..."
    local elapsed=0

    while [[ $elapsed -lt $STOP_TIMEOUT ]]; do
        if ! get_status; then
            log "Server is stopped."
            return 0
        fi
        sleep "$STOP_POLL_INTERVAL"
        elapsed=$((elapsed + STOP_POLL_INTERVAL))
    done

    log "WARN: Server did not stop within ${STOP_TIMEOUT}s, continuing anyway..."
}

ensure_remote_deps() {
    log "Checking remote dependencies (zip)..."

    local has_zip
    has_zip="$(ssh_run 'command -v zip >/dev/null 2>&1 && echo yes || echo no')"

    if [[ "$has_zip" == "yes" ]]; then
        log "zip is already installed on remote."
        return 0
    fi

    die "zip is not installed on the remote host and this account has no sudo access to install it. Run setup.sh on the remote host again, or install zip manually as root."
}

compress_remote() {
    log "Compressing server data on remote host (zip/chown via sudo)..."

    # mkdir/rm act on REMOTE_USER's own home dir, no sudo needed.
    # zip needs to read root-owned server files; -T verifies the archive
    # isn't corrupt/truncated before we bother copying it anywhere; chown
    # hands the archive back to REMOTE_USER so scp can read it.
    if ! ssh_run "
        set -e
        mkdir -p '${REMOTE_BACKUP_DIR}'
        rm -f '${REMOTE_ZIP_PATH}'
        cd '${REMOTE_SERVER_DATA_DIR}'
        sudo zip -r -${ZIP_COMPRESSION_LEVEL} '${REMOTE_ZIP_PATH}' .
        if [[ '${SIMULATE_ZIP_CORRUPTION}' == 'true' ]]; then
            echo 'SIMULATE_ZIP_CORRUPTION=true — deliberately corrupting the archive for testing' >&2
            sudo dd if=/dev/urandom of='${REMOTE_ZIP_PATH}' bs=1 count=200 seek=100 conv=notrunc status=none
        fi
        sudo zip -T '${REMOTE_ZIP_PATH}'
        sudo chown '${REMOTE_USER}:${REMOTE_USER}' '${REMOTE_ZIP_PATH}'
    "; then
        notify_whatsapp "⚠️ PufferPanel backup FAILED: zip integrity check failed on ${REMOTE_HOST} for server ${SERVER_ID}. Archive was NOT copied down — remote server has been restarted."
        die "Remote compression or integrity check failed (see output above). The archive on the remote host may be incomplete or corrupt — not copying it down."
    fi

    log "Remote compression complete, archive integrity verified: ${REMOTE_ZIP_PATH}"
}

copy_backup_local() {
    log "Copying backup to local machine..."
    mkdir -p "$LOCAL_BACKUP_DIR"
    scp_get "${REMOTE_ZIP_PATH}" "$LOCAL_BACKUP_FILE"
    log "Backup copied to: $LOCAL_BACKUP_FILE"
}

prune_local_backups() {
    log "Pruning local backups (keeping newest ${LOCAL_BACKUP_KEEP})..."

    local backups
    # shellcheck disable=SC2012
    backups="$(ls -t "${LOCAL_BACKUP_DIR}"/"${SERVER_ID}"_*.zip 2>/dev/null || true)"

    if [[ -z "$backups" ]]; then
        log "No local backups found to prune."
        return 0
    fi

    local count
    count="$(echo "$backups" | wc -l)"

    if [[ $count -gt $LOCAL_BACKUP_KEEP ]]; then
        local to_delete
        to_delete="$(echo "$backups" | tail -n +$((LOCAL_BACKUP_KEEP + 1)))"
        echo "$to_delete" | while read -r f; do
            log "Deleting old backup: $f"
            rm -f "$f"
        done
    else
        log "No pruning needed ($count backup(s) found, limit is $LOCAL_BACKUP_KEEP)"
    fi
}

start_server() {
    log "Sending start request to server..."
    api_call POST "/servers/${SERVER_ID}/start"

    if [[ "$API_HTTP_STATUS" != "202" && "$API_HTTP_STATUS" != "204" ]]; then
        log "WARN: start_server returned HTTP $API_HTTP_STATUS (expected 202/204)"
    else
        log "Start request sent successfully."
    fi
}

# ============================================================
# TRAP-BASED SAFETY NET
# ============================================================

cleanup() {
    log "=== Cleanup: ensuring server is restarted ==="
    if [[ "$SERVER_STOPPED" == "true" ]]; then
        if [[ -z "$TOKEN" ]]; then
            log "No token available, re-authenticating..."
            TOKEN="$(get_token)" || log "ERROR: Could not re-authenticate!"
        fi
        start_server
    fi
    log "=== Backup script finished ==="
}

trap cleanup EXIT

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    log "=== PufferPanel Backup Script starting ==="

    validate_config
    debug "SIMULATE_ZIP_CORRUPTION=${SIMULATE_ZIP_CORRUPTION}"
    TOKEN="$(get_token)"

    log "Step 1/7: Stopping server..."
    stop_server
    SERVER_STOPPED="true"

    log "Step 2/7: Waiting for server to stop..."
    wait_for_stop

    log "Step 3/7: Waiting ${STOP_WAIT_SECONDS}s before compressing..."
    sleep "$STOP_WAIT_SECONDS"

    log "Step 4/7: Ensuring remote dependencies (zip)..."
    ensure_remote_deps

    log "Step 5/7: Compressing server data on remote..."
    compress_remote

    log "Step 6/7: Restarting server..."
    start_server
    SERVER_STOPPED="false"

    log "Step 7/7: Copying backup to local and pruning..."
    copy_backup_local
    prune_local_backups

    log "Backup complete: $LOCAL_BACKUP_FILE"
}

main
