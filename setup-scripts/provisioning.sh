#!/bin/bash
set -euo pipefail

# Arguments
USER_NAME="${1:?Usage: $0 <username> [port_for_ssh] [ssh_group]}"
SSH_PORT="${2:-22}"
SSH_GROUP="${3:-sshusers}"

# Logging setup
LOG_FILE="/var/log/provisioning-$(date +%Y%m%d-%H%M%S).log"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

trap 'log "ERROR: Script failed at line ${LINENO}"' ERR

# Adding non root user and group for ssh login

log "Starting provisioning..."
log "Target user: ${USER_NAME}, SSH group: ${SSH_GROUP}"

# Adding group for ssh access
log "Creating SSH group '${SSH_GROUP}'..."
if ! getent group "${SSH_GROUP}" &>/dev/null; then
    groupadd "${SSH_GROUP}"
    log "Group '${SSH_GROUP}' created"
else
    log "Group '${SSH_GROUP}' already exists"
fi

# Create user for ssh access
log "Creating user '${USER_NAME}'..."
if ! id "${USER_NAME}" &>/dev/null; then

    log "Reading password for user '${USER_NAME}'..."
    if [[ -t 0 && -e /dev/tty ]]; then
      # If script accessing directly from terminal
      echo -n "Enter password for user '${USER_NAME}': " > /dev/tty
      read -r -s USER_PWD < /dev/tty
      echo > /dev/tty
    else
      # If password received from pipe
      USER_PWD="$(cat)"
    fi
    if [[ -z "${USER_PWD}" ]]; then
      log "ERROR: Password cannot be empty"
      exit 1
    fi

    useradd -m -s /bin/bash "${USER_NAME}"
    log "User '${USER_NAME}' created"

    usermod -aG "${SSH_GROUP}" "${USER_NAME}"
    log "Group set for user '${USER_NAME}'"
    echo "${USER_NAME}:${USER_PWD}" | chpasswd
    log "Password set for user '${USER_NAME}'"
else
    log "User '${USER_NAME}' already exists"
fi

# Cleaning password from memory
unset USER_PWD

# Installing base packages
log "Upgrading system packages..."
dnf upgrade --refresh -y

log "Installing base packages..."
dnf install -y \
    dnf-plugins-core \
    nano \
    git \
    conntrack-tools \
    jq \
    policycoreutils-python-utils

# Swap configuration (4 GB for 2 GB RAM systems)
SWAP_FILE="/swapfile"
SWAP_SIZE="4G"

log "Configuring swap (${SWAP_SIZE})..."

if [[ -f "${SWAP_FILE}" ]]; then
    log "Swap file ${SWAP_FILE} already exists, skipping creation"
else
    # Creating swap file
    fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    log "Swap file created: ${SWAP_FILE} (${SWAP_SIZE})"
fi

# Activate swap file
if ! swapon --show | grep -q "^${SWAP_FILE} "; then
    swapon "${SWAP_FILE}"
    log "Swap activated"
else
    log "Swap already active"
fi

# Grant activation after restart through /etc/fstab
if ! grep -qF "${SWAP_FILE}" /etc/fstab; then
    echo "${SWAP_FILE} none swap defaults 0 0" >> /etc/fstab
    log "Swap entry added to /etc/fstab"
else
    log "Swap entry already present in /etc/fstab"
fi

# Tune vm.swappiness
log "--- Sysctl (memory) ---"
log "Configuring vm.swappiness..."
SWAPPINESS_CONF="/etc/sysctl.d/98-memory.conf"

if [[ ! -f "${SWAPPINESS_CONF}" ]]; then
    cat > "${SWAPPINESS_CONF}" <<'EOF'
# Memory management
# Prefer RAM over swap, but allow swap as safety net.
# Value 10: kernel avoids swapping unless memory pressure is high.
# Do NOT set to 0 on systems with Docker — OOM killer becomes too aggressive.
vm.swappiness=10
EOF
    log "Created ${SWAPPINESS_CONF}"
elif ! grep -q "^vm.swappiness" "${SWAPPINESS_CONF}"; then
    printf "\n# Prefer RAM over swap\nvm.swappiness=10\n" >> "${SWAPPINESS_CONF}"
    log "Added vm.swappiness to existing ${SWAPPINESS_CONF}"
fi

CURRENT_SWAPPINESS="$(sysctl -n vm.swappiness)" 
if [[ "${CURRENT_SWAPPINESS}" != "10" ]]; then
    sysctl -w vm.swappiness=10
    log "vm.swappiness changed from ${CURRENT_SWAPPINESS} to 10 (runtime)"
else
    log "vm.swappiness already set to 10"
fi

# Installing docker repo and packages
log "Adding Docker repository..."
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
else
    log "Docker repository already configured"
fi

log "Installing Docker packages..."
dnf install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Cleaning cached .rpm package files and metadata
dnf clean all -y

# SSH hardening
log "Configuring SSH (port: ${SSH_PORT})..."
mkdir -p /etc/ssh/sshd_config.d

HARDENING_DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"
PORT_DROPIN="/etc/ssh/sshd_config.d/01-port.conf"

# --- 00-hardening.conf: PermitRootLogin + AllowGroups ---
EXPECTED_HARDENING="PermitRootLogin no
AllowGroups ${SSH_GROUP}"

if [[ -f "${HARDENING_DROPIN}" ]] && \
   grep -qF "PermitRootLogin no" "${HARDENING_DROPIN}" && \
   grep -qF "AllowGroups ${SSH_GROUP}" "${HARDENING_DROPIN}"; then
    log "Drop-in ${HARDENING_DROPIN} already correct, skipping"
else
    cat > "${HARDENING_DROPIN}" <<EOF
${EXPECTED_HARDENING}
EOF
    log "Created/updated ${HARDENING_DROPIN}"
fi

# --- 01-port.conf: Port ---
DEFAULT_SSH_PORT="22"
EXPECTED_PORT="Port ${SSH_PORT}"

if [[ "${SSH_PORT}" != "${DEFAULT_SSH_PORT}" ]]; then
 # Check if specified port is not occupied yet
 if ss -tlnp | grep -qE ":${SSH_PORT}\b"; then
        OCCUPIED_BY="$(ss -tlnp | grep -E ":${SSH_PORT}\b" | head -1)"
        log "ERROR: Port ${SSH_PORT} is already in use:"
        log "  ${OCCUPIED_BY}"
        log "Choose a different port or stop the conflicting service."
        exit 1
  fi
  log "Port ${SSH_PORT}/tcp is free, proceeding with configuration"

  if [[ -f "${PORT_DROPIN}" ]] && grep -qF "${EXPECTED_PORT}" "${PORT_DROPIN}"; then
      log "Drop-in ${PORT_DROPIN} already correct, skipping"
  else
      log "Configuring SELinux..."
        # Adding port to ssh_port_t
        if ! semanage port -l | grep -qE "ssh_port_t.*\b${SSH_PORT}\b"; then
        semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" 2>/dev/null \
                    || semanage port -m -t ssh_port_t -p tcp "${SSH_PORT}"
          log "SELinux: added port ${SSH_PORT}/tcp to ssh_port_t"
      else
          log "SELinux: port ${SSH_PORT}/tcp already in ssh_port_t"
      fi
      log "SELinux configured"

      # Configuring firewall
      log "Configuring port $SSH_PORT in firewall"
      if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
            firewall-cmd --reload
            log "Firewall: opened port ${SSH_PORT}/tcp"
      else
          log "WARNING: firewall-cmd not found. Configure firewall manually"
      fi
      log "Port $SSH_PORT configured in firewall"

      cat > "${PORT_DROPIN}" <<EOF
${EXPECTED_PORT}
EOF
     log "Created/updated ${PORT_DROPIN}"
  fi
else
  log "Specified standard SSH port, skipping port configuration"
fi
log "SSH configuration written"

# Validate the SSH configuration, reload SSH daemon
sshd -t
systemctl reload sshd

# Get sshd config dump
SSHD_CONFIG_DUMP="$(sshd -T)"

#Verify ssh port
PORT_ACTUAL="$(echo "${SSHD_CONFIG_DUMP}" | awk '$1 == "port" {print $2; exit}')"
if [[ "${SSH_PORT}" != "${DEFAULT_SSH_PORT}" && "${PORT_ACTUAL}" != "${SSH_PORT}" ]]; then
    log "ERROR: SSH port is ${PORT_ACTUAL}, expected ${SSH_PORT}"
    exit 1
fi

# Verify PermitRootLogin param
PERMIT_LOGIN_ACTUAL="$(echo "${SSHD_CONFIG_DUMP}" | awk '$1 == "permitrootlogin" {print $2}')"
if [[ "${PERMIT_LOGIN_ACTUAL}" != "no" ]]; then
    log "ERROR: PermitRootLogin is not set to no"
    exit 1
fi

# Verify AllowGroups param
ALLOW_GROUPS_ACTUAL="$(echo "${SSHD_CONFIG_DUMP}" | awk '$1 == "allowgroups" {$1=""; print substr($0,2)}')"
if [[ "${ALLOW_GROUPS_ACTUAL}" != *"${SSH_GROUP}"* ]]; then
    log "ERROR: AllowGroups does not contain '${SSH_GROUP}'. Actual: ${ALLOW_GROUPS_ACTUAL}"
    exit 1
fi
log "SSH configuration verified (port=${PORT_ACTUAL}, root=no, groups=${SSH_GROUP})"

# --- Confirm sshd is actually LISTENING on the new port ---
if [[ "${SSH_PORT}" != "${DEFAULT_SSH_PORT}" ]]; then
    sleep 5

    if ! ss -tlnp | grep -qE ":${SSH_PORT}\b"; then
        log "ERROR: sshd is NOT listening on port ${SSH_PORT}. NOT closing port 22."
        log "Check: journalctl -u sshd --no-pager -n 50"
        exit 1
    fi
    log "sshd confirmed listening on port ${SSH_PORT}"

    # Close default ssh port in firewall
    if command -v firewall-cmd &>/dev/null; then
        log "Closing port '${DEFAULT_SSH_PORT}' in firewall"
        if firewall-cmd --list-ports | grep -qE "\b${DEFAULT_SSH_PORT}/tcp\b"; then
            firewall-cmd --permanent --remove-port=${DEFAULT_SSH_PORT}/tcp
            firewall-cmd --reload
            log "Firewall: closed port ${DEFAULT_SSH_PORT}/tcp"
        else
            log "Firewall: port ${DEFAULT_SSH_PORT}/tcp already closed"
        fi
    fi
fi

# sysctl Kernel / TCP / Conntrack configuration
log "--- Sysctl (network) ---"
cat > /etc/sysctl.d/99-server-limits.conf <<'EOF' 
# Queue + congestion control
#
## Traffic flow queue scheduling
net.core.default_qdisc=fq
## Congestion control algorithm based on RTT instead of packet loss
net.ipv4.tcp_congestion_control=bbr

# Conntrack
#
## Exceeding connections count limit
net.netfilter.nf_conntrack_max=524288
## Reduction of the hold time for dead TCP connections
net.netfilter.nf_conntrack_tcp_timeout_established=300
## Reduces the TIME_WAIT connection tracking duration. 
## Speeds up the freeing of conntrack slots after sessions close.
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# TCP
#
## Allows the kernel to safely reuse sockets in the TIME_WAIT state for new outgoing connections. 
## Prevents port exhaustion during frequent requests to external resources.
net.ipv4.tcp_tw_reuse=1
## Expands the range of local ports for outbound traffic. 
## Increases the limit on the number of simultaneous connections opened by the server.
net.ipv4.ip_local_port_range=1024 65000

# SYN-flood protection
#
## Increases the queue size for half-open connections (where the client has sent a SYN but has not yet completed the handshake).
## Helps prevent the server from crashing during a surge of new requests.
net.ipv4.tcp_max_syn_backlog=4096
## Reduces the number of SYN-ACK retransmission attempts to the client from 5 to 3. 
## Prevents the server from wasting resources processing responses to non-existent or malicious addresses. 
net.ipv4.tcp_synack_retries=3
## Enables the SYN Cookies mechanism. 
## If the connection queue overflows, the server stops allocating memory for connections and instead encodes the data within the network packet itself. 
## Makes the classic SYN flood DDoS attack ineffective.
net.ipv4.tcp_syncookies=1
EOF

# Load conntrack module if it is not built in kernel. Apply all sysctl configuration files
modprobe nf_conntrack 2>/dev/null \
    || log "WARNING: Could not load nf_conntrack module (may be built-in)"
sysctl --system
log "Sysctl configuration applied"

# Docker systemd limits
log "Configuring Docker systemd limits..."
mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/99-limits.conf <<'EOF'
[Service]

# Increase the maximum number of open file descriptors
# available to the Docker daemon and its service process.
#
# This prevents the daemon from hitting the default NOFILE limit
# under a large number of network connections.
#
# Container-level NOFILE limits are configured separately
# via /etc/docker/daemon.json.
LimitNOFILE=1048576
EOF

# Make systemd recognize the new Docker daemon drop-in
systemctl daemon-reload
log "Docker systemd limits configured"

# Docker container limits
log "Configuring Docker daemon.json..."
mkdir -p /etc/docker

# If daemon.json already exists, create a timestamped backup
# before modifying it.
if [[ -f /etc/docker/daemon.json ]]; then
    cp -a /etc/docker/daemon.json \
        "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"

    # Preserve existing Docker configuration and add/update
    # the default NOFILE limits for newly created containers.
    #
    # Existing Docker configuration is NOT overwritten.
    jq '
      .["default-ulimits"] = (.["default-ulimits"] // {}) |
      .["default-ulimits"]["nofile"] = {
        "Name": "nofile",
        "Soft": 1048576,
        "Hard": 1048576
      }
    ' /etc/docker/daemon.json > /etc/docker/daemon.json.tmp

    # Replace the original file only after jq successfully
    # generated valid JSON.
    mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Soft": 1048576,
      "Hard": 1048576
    }
  }
}
EOF
fi

# Validate the resulting Docker configuration before
# starting/restarting Docker.
jq empty /etc/docker/daemon.json
log "Docker daemon.json configured"

log "Enabling and restarting Docker..."
systemctl enable --now docker
systemctl restart docker
log "Docker enabled and restarted"

log "===== Verification ====="
log "--- Docker service ---"
systemctl is-active docker
systemctl show docker --property=LimitNOFILE

log "--- Docker daemon.json ---"
jq . /etc/docker/daemon.json

log "--- Docker plugins ---"
docker buildx version
docker compose version

log "--- Sysctl ---"
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control
sysctl net.netfilter.nf_conntrack_max
sysctl net.netfilter.nf_conntrack_tcp_timeout_established
sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait

log "--- SSH ---"
sshd -T | grep -E '^(permitrootlogin|allowgroups) '

log "Provisioning completed successfully."
log "Full log available at: ${LOG_FILE}"