#!/usr/bin/env bash
#
# setup.sh — one-time interactive setup for puff-backup.sh
#
# Run this AS ROOT on the REMOTE PufferPanel host (the one running Docker).
# It does NOT touch the local machine or PufferPanel itself.
#
#   sudo ./setup.sh
#
# It will:
#   1. Create (or reuse) the backup SSH user
#   2. Install your SSH public key for that user
#   3. Create the remote backup directory
#   4. Install `zip` if it's missing
#   5. Write a scoped, passwordless sudoers rule for exactly the commands
#      puff-backup.sh needs (zip, chown, and the package manager)
#   6. Verify the sudoers rule actually works, without a password
#
set -euo pipefail

# ---------- helpers ----------

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ok]\033[0m $*"; }
die()   { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

ask() {
    # ask <prompt> <default> -> echoes the answer
    local prompt="$1" default="$2" answer
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

confirm() {
    # confirm <prompt> -> 0 if yes
    local prompt="$1" answer
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------- 0. sanity checks ----------

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (try: sudo ./setup.sh)"
fi

if [[ ! -d /var/lib/pufferpanel ]]; then
    warn "Could not find /var/lib/pufferpanel on this host. Are you running this on the correct server?"
    confirm "Continue anyway?" || exit 1
fi

echo
info "PufferPanel remote backup setup"
echo "This will create/configure a backup SSH user, install zip, and"
echo "grant it narrow, passwordless sudo for the backup script only."
echo

# ---------- 1. backup user ----------

BACKUP_USER="$(ask "Username for the backup account" "puffbackup")"

if id "$BACKUP_USER" &>/dev/null; then
    ok "User '$BACKUP_USER' already exists — reusing it."
else
    if confirm "User '$BACKUP_USER' does not exist. Create it?"; then
        useradd -m -s /bin/bash "$BACKUP_USER"
        ok "Created user '$BACKUP_USER'."
    else
        die "Cannot continue without the backup user."
    fi
fi

USER_HOME="$(getent passwd "$BACKUP_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "Could not resolve home directory for $BACKUP_USER"

# ---------- 2. SSH key ----------

echo
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if confirm "Add an SSH public key now? (skip if it's already in authorized_keys)"; then
    info "SSH public key setup"
    echo "On your LOCAL machine, if you don't already have a key, generate one with:"
    echo "    ssh-keygen -t ed25519 -f ~/.ssh/pufferpanel_backup_key -N \"\""
    echo "Then print the PUBLIC key with:"
    echo "    cat ~/.ssh/pufferpanel_backup_key.pub"
    echo

    mkdir -p "$SSH_DIR"

    PUB_KEY=""
    while [[ -z "$PUB_KEY" ]]; do
        read -r -p "Paste the public key contents here: " PUB_KEY
        if [[ -n "$PUB_KEY" && "$PUB_KEY" != ssh-* && "$PUB_KEY" != ecdsa-* ]]; then
            warn "That doesn't look like a public key (should start with ssh-ed25519, ssh-rsa, etc.)"
            PUB_KEY=""
        fi
    done

    touch "$AUTH_KEYS"
    if grep -qF "$PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
        ok "Key already present in authorized_keys."
    else
        echo "$PUB_KEY" >> "$AUTH_KEYS"
        ok "Key added to authorized_keys."
    fi

    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    chown -R "${BACKUP_USER}:${BACKUP_USER}" "$SSH_DIR"
else
    if [[ -s "$AUTH_KEYS" ]]; then
        ok "Skipping key setup — found an existing authorized_keys with content."
    else
        warn "Skipping key setup, but ${AUTH_KEYS} is missing or empty. SSH login will fail until a key is added."
    fi
fi

# ---------- 3. remote backup directory ----------

echo
REMOTE_BACKUP_DIR="$(ask "Remote directory to stage the zip in" "${USER_HOME}/backups")"
mkdir -p "$REMOTE_BACKUP_DIR"
chown "${BACKUP_USER}:${BACKUP_USER}" "$REMOTE_BACKUP_DIR"
ok "Backup staging directory ready: $REMOTE_BACKUP_DIR"

# ---------- 4. zip ----------

echo
info "Checking for zip..."
if command -v zip &>/dev/null; then
    ok "zip is already installed."
else
    warn "zip not found."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y zip
    elif command -v dnf &>/dev/null; then
        dnf install -y zip
    elif command -v yum &>/dev/null; then
        yum install -y zip
    else
        die "No supported package manager found (apt/dnf/yum). Install zip manually and re-run."
    fi
    ok "zip installed."
fi

# ---------- 5. sudoers rule ----------

echo
info "Configuring passwordless sudo for $BACKUP_USER"
echo "Only these exact binaries get NOPASSWD root access — nothing else:"
echo "  - zip     (to read root-owned/Docker-owned server files during backup)"
echo "  - chown   (to hand the finished archive back to $BACKUP_USER)"
echo "(zip itself was already installed above, so the package manager is"
echo " never handed to $BACKUP_USER — it has no ongoing reason to need it.)"
echo

ZIP_PATH="$(command -v zip)"
CHOWN_PATH="$(command -v chown)"

SUDOERS_FILE="/etc/sudoers.d/puff-backup"
SUDOERS_LINE="${BACKUP_USER} ALL=(root) NOPASSWD: ${ZIP_PATH}, ${CHOWN_PATH}"

echo "# Managed by puff-backup setup.sh — narrow NOPASSWD rule for remote backups" > "$SUDOERS_FILE"
echo "$SUDOERS_LINE" >> "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    ok "sudoers rule written and validated: $SUDOERS_FILE"
else
    rm -f "$SUDOERS_FILE"
    die "visudo validation failed — sudoers file removed. Nothing was left misconfigured."
fi

# ---------- 6. verify it actually works, passwordlessly ----------

echo
info "Verifying passwordless sudo works for $BACKUP_USER..."

if runuser -l "$BACKUP_USER" -c "sudo -n ${ZIP_PATH} -v" &>/dev/null; then
    ok "sudo zip works without a password prompt."
else
    warn "sudo -n test failed. Check 'sudo -l -U ${BACKUP_USER}' as root to see what sudo thinks is authorized."
fi

# ---------- summary ----------

echo
ok "Setup complete."
echo
echo "Use these values in puff-backup.sh's CONFIGURATION section:"
echo "  REMOTE_USER=\"${BACKUP_USER}\""
echo "  REMOTE_BACKUP_DIR=\"${REMOTE_BACKUP_DIR}\""
echo
echo "From your LOCAL machine, test the connection with:"
echo "  ssh -i ~/.ssh/pufferpanel_backup_key -p 22 ${BACKUP_USER}@$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
