#!/bin/bash
set -euo pipefail

# Logging setup
LOG_FILE="/var/log/3xui_warp_deploy-$(date +%Y%m%d-%H%M%S).log"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
    printf "[%s] %b\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

trap 'log "ERROR: Script failed at line ${LINENO}"' ERR

#Arguments
USER_NAME="${1:?Usage: $0 <username> [port_for_ssh] [ssh_group]}"
SSH_PORT="${2:-22}"
SSH_GROUP="${3:-sshusers}"

#Constants
PANEL_PORT=2087
HTTPS_OUT_PORT=2083

XUI_NETWORK_NAME="3xui-net"

HOME_DIR="/root"
UPPER_DIR="$(dirname "$0")"/..

GIT_XUI_SOURCES_URL="https://github.com/georgiyCJDEV/3x-ui_warp-cli_docker.git"
XUI_SOURCES_GIT="${HOME_DIR}/packages/3x-ui"
XUI_COMPOSE_FILE="${XUI_SOURCES_GIT}/docker-compose.yml"
DOCKER_ENV="${XUI_SOURCES_GIT}/.env"

WARP_VOLUME="${HOME_DIR}/docker_volumes/3x-ui/warp-data"
XUI_VOLUME="${HOME_DIR}/docker_volumes/3x-ui/3x-ui-data"

XUI_CERT_DIR="${XUI_VOLUME}/cert"
XUI_DB_DIR="${XUI_VOLUME}/db"
XUI_DB="${XUI_DB_DIR}/x-ui.db"
PANEL_CERT="${XUI_CERT_DIR}/panel.crt"
PANEL_KEY="${XUI_CERT_DIR}/panel.key"

log "--- Running provisioning script... ---"
# Running overprovisioning system setup script
"${UPPER_DIR}/provisioning.sh" "${USER_NAME}" "${SSH_PORT}" "${SSH_GROUP}" || {
    echo "ERROR: ${UPPER_DIR}/provisioning.sh failed, aborting deploy"
    exit 1
}
log "--- Provisioning script finished ---"

log "--- Installing sqlite package ---"
# For managing x-ui.db
dnf install sqlite -y

log "--- Preparing volume directories ---"
# Making directories for 3x-ui volumes
mkdir -p "${WARP_VOLUME}"
mkdir -p "${XUI_VOLUME}"
mkdir -p "${XUI_SOURCES_GIT}"
mkdir -p "${XUI_CERT_DIR}"
mkdir -p "${XUI_DB_DIR}"
log "--- Directories for volumes created ---"

log "--- Downloading 3xui + warp_cli containers sources to ${XUI_SOURCES_GIT} ---"
# Cloning 3x-ui + warp container sources
if [[ -d "${XUI_SOURCES_GIT}/.git" ]]; then
    git -C "${XUI_SOURCES_GIT}" pull origin master
else
    git clone -b master --single-branch "${GIT_XUI_SOURCES_URL}" "${XUI_SOURCES_GIT}"
fi
log "--- 3xui + warp_cli containers sources cloned to ${XUI_SOURCES_GIT} ---"

# Backing up .env file in 3x-ui sources directory and setting .env
log "Preparing .env file with params DB=${XUI_DB_DIR} CERT=${XUI_CERT_DIR} PANEL_PORT=${PANEL_PORT} HTTPS_OUT_PORT=${HTTPS_OUT_PORT}"
if [[ -f "$DOCKER_ENV" ]]; then
    cp -a "$DOCKER_ENV" "${DOCKER_ENV}.bak.$(date +%Y%m%d%H%M%S)"
fi
cat << EOF > "$DOCKER_ENV"
# 3x-ui volumes
DB=${XUI_DB_DIR}
CERT=${XUI_CERT_DIR}
PANEL_PORT=${PANEL_PORT}
HTTPS_OUT_PORT=${HTTPS_OUT_PORT}

# Warp volume
WARP_DATA=${WARP_VOLUME}/warp-data/
EOF
log ".env file created in ${XUI_SOURCES_GIT}"

# Creating network for 3x-ui containers
if ! docker network inspect "${XUI_NETWORK_NAME}" &>/dev/null; then
    log "Creating Docker network '${XUI_NETWORK_NAME}'..."
    docker network create "${XUI_NETWORK_NAME}"
    log "Docker network '${XUI_NETWORK_NAME}' created"
else
    log "Docker network '${XUI_NETWORK_NAME}' already exists"
fi

log "Running docker compose for 3xui and warp-cli containers"
# Building and starting containers
docker compose -f "${XUI_COMPOSE_FILE}" up -d
log "Containers started"

# Generating tls cert and key
if [[ ! -f "${PANEL_CERT}" || ! -f "${PANEL_KEY}" ]]; then
    log "Generating self-signed TLS certificate for 3x-ui panel..."
    mkdir -p "${XUI_CERT_DIR}"
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${PANEL_KEY}" \
        -out "${PANEL_CERT}" \
        -subj "/CN=3x-ui-panel/O=SelfSigned/C=US" \
        2>/dev/null
    chmod 600 "${PANEL_KEY}"
    chmod 644 "${PANEL_CERT}"
    log "Certificate generated: ${PANEL_CERT}"
else
    log "TLS certificate already exists, skipping generation"
fi

# Waiting for x-ui.db
WAIT_DB=0
while [[ ! -f "${XUI_DB}" ]]; do
    sleep 1
    WAIT_DB=$((WAIT_DB + 1))
    if [[ ${WAIT_DB} -ge 30 ]]; then
        log "ERROR: x-ui.db not found at ${XUI_DB} after 30s"
        exit 1
    fi
done
log "Found x-ui.db at ${XUI_DB}"

# Путь к SQL-файлу (рядом с deploy.sh)
SQL_UPDATE_FILE="$(dirname "$0")/update-xui-settings.sql"

log "Configuring 3x-ui panel settings via SQLite transaction..."
if ! sqlite3 "${XUI_DB}" \
    -cmd ".param set :webPort ${PANEL_PORT}" \
    -cmd ".param set :certFile /root/cert/panel.crt" \
    -cmd ".param set :keyFile /root/cert/panel.key" \
    < "${SQL_UPDATE_FILE}"; then
        log "ERROR: Failed to update 3x-ui settings in SQLite"
        exit 1
fi
log "3x-ui panel settings updated successfully"

# Restarting containers to apply changes
log "Restarting 3x-ui container to apply new settings..."
docker compose -f "${XUI_COMPOSE_FILE}" restart
log "3x-ui container restarted"

log "3x-ui with warp-cli containers deployment finished!\n\n3x-ui running with outer 2083 https port, 2087 panel port\n"