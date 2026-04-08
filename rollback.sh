#!/bin/bash
# =============================================================================
#  Fleet Manager — Rollback Script
#  Undoes every change made by fleet.sh
#  Usage: bash fleet-rollback.sh
# =============================================================================

set -e

FLEET_DIR="/home/pi/fleet-management"
NODERED_DIR="/home/pi/.node-red"
SETTINGS_JS="${NODERED_DIR}/settings.js"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
skipped() { echo -e "${YELLOW}[-]${NC} $1 (not found — skipping)"; }
section() { echo -e "\n${YELLOW}━━━ $1 ━━━${NC}"; }

[[ $(id -u) -ne 0 ]] || { echo "Do not run as root. Run as the pi user."; exit 1; }

echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Fleet Manager Rollback${NC}"
echo -e "${RED}  This will remove all changes made by fleet.sh${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "Are you sure you want to continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================================
section "Stopping and removing Docker containers"
# =============================================================================

if command -v docker-compose >/dev/null 2>&1 && [[ -f /home/pi/docker-compose.yml ]]; then
    cd /home/pi
    docker-compose down --volumes --remove-orphans 2>/dev/null || true
    log "Docker containers stopped and removed"
else
    skipped "docker-compose or docker-compose.yml"
fi

# Remove containers individually as fallback
for container in verdaccio apt-cacher-ng; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        log "Container removed: $container"
    fi
done

# =============================================================================
section "Removing Docker images"
# =============================================================================

for image in verdaccio/verdaccio sameersbn/apt-cacher-ng; do
    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "^${image%:*}$"; then
        docker rmi "$image" 2>/dev/null || true
        log "Docker image removed: $image"
    else
        skipped "Docker image: $image"
    fi
done

docker image prune -f 2>/dev/null || true

# =============================================================================
section "Uninstalling Docker"
# =============================================================================

if dpkg -l docker.io >/dev/null 2>&1; then
    sudo apt-get remove -y --purge docker.io docker-compose 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
    sudo groupdel docker 2>/dev/null || true
    log "Docker uninstalled"
else
    skipped "docker.io (not installed via apt — skipping uninstall)"
    warn "If Docker was installed before fleet.sh ran it has been left in place"
fi

# =============================================================================
section "Removing Docker volumes and data"
# =============================================================================

if [[ -d /verdaccio ]]; then
    sudo rm -rf /verdaccio
    log "Removed /verdaccio"
else
    skipped "/verdaccio directory"
fi

if [[ -d /var/cache/apt-cacher-ng ]]; then
    sudo rm -rf /var/cache/apt-cacher-ng
    log "Removed /var/cache/apt-cacher-ng"
else
    skipped "/var/cache/apt-cacher-ng"
fi

if [[ -d /var/log/apt-cacher-ng ]]; then
    sudo rm -rf /var/log/apt-cacher-ng
    log "Removed /var/log/apt-cacher-ng"
else
    skipped "/var/log/apt-cacher-ng"
fi

# =============================================================================
section "Removing docker-compose.yml"
# =============================================================================

if [[ -f /home/pi/docker-compose.yml ]]; then
    rm /home/pi/docker-compose.yml
    log "Removed /home/pi/docker-compose.yml"
else
    skipped "/home/pi/docker-compose.yml"
fi

# =============================================================================
section "Removing fleet-management directory"
# =============================================================================

if [[ -d "$FLEET_DIR" ]]; then
    rm -rf "$FLEET_DIR"
    log "Removed $FLEET_DIR"
else
    skipped "$FLEET_DIR"
fi

# Also remove backup if it exists
if [[ -d "${FLEET_DIR}.bak" ]]; then
    rm -rf "${FLEET_DIR}.bak"
    log "Removed ${FLEET_DIR}.bak"
fi

# =============================================================================
section "Restoring Node-RED settings.js"
# =============================================================================

if [[ -f "${SETTINGS_JS}.bak" ]]; then
    cp "${SETTINGS_JS}.bak" "$SETTINGS_JS"
    sudo chown pi:pi "$SETTINGS_JS"
    rm "${SETTINGS_JS}.bak"
    log "settings.js restored from backup"
else
    skipped "settings.js backup (${SETTINGS_JS}.bak not found)"
    warn "settings.js was not restored — you may need to manually reset it"
fi

# =============================================================================
section "Removing Node-RED flow"
# =============================================================================

if [[ -f "${NODERED_DIR}/flows.json" ]]; then
    rm "${NODERED_DIR}/flows.json"
    log "Removed ${NODERED_DIR}/flows.json"
else
    skipped "${NODERED_DIR}/flows.json"
fi

# Also remove credential and context files created by the fleet flow
for f in flows_cred.json .config.runtime.json .config.nodes.json; do
    [[ -f "${NODERED_DIR}/${f}" ]] && rm "${NODERED_DIR}/${f}" && log "Removed ${NODERED_DIR}/${f}" || true
done

# =============================================================================
section "Removing sudoers entry"
# =============================================================================

if [[ -f /etc/sudoers.d/nodered-apt ]]; then
    sudo rm /etc/sudoers.d/nodered-apt
    log "Removed /etc/sudoers.d/nodered-apt"
else
    skipped "/etc/sudoers.d/nodered-apt"
fi

# =============================================================================
section "Removing SSH key"
# =============================================================================

echo ""
read -rp "Remove SSH key (/home/pi/.ssh/id_ed25519)? This will break Ansible access to fleet devices. [y/N] " remove_key
if [[ "$remove_key" =~ ^[Yy]$ ]]; then
    if [[ -f /home/pi/.ssh/id_ed25519 ]]; then
        rm /home/pi/.ssh/id_ed25519
        rm -f /home/pi/.ssh/id_ed25519.pub
        log "SSH key removed"
    else
        skipped "SSH key (not found)"
    fi
else
    warn "SSH key kept at /home/pi/.ssh/id_ed25519"
fi

# =============================================================================
section "Restarting Node-RED"
# =============================================================================

sudo systemctl restart nodered
sleep 3

if sudo systemctl is-active --quiet nodered; then
    log "Node-RED restarted"
else
    warn "Node-RED failed to restart — check: sudo journalctl -u nodered -n 50"
fi

# =============================================================================
section "Rollback complete"
# =============================================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Rollback complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Removed:"
echo -e "   - Docker containers (verdaccio, apt-cacher-ng)"
echo -e "   - Docker images"
echo -e "   - Docker package (if installed by fleet.sh)"
echo -e "   - /verdaccio, /var/cache/apt-cacher-ng, /var/log/apt-cacher-ng"
echo -e "   - /home/pi/fleet-management"
echo -e "   - /home/pi/docker-compose.yml"
echo -e "   - /etc/sudoers.d/nodered-apt"
echo -e "   - Node-RED flow (flows.json)"
echo -e "   - Node-RED settings.js (restored from backup if available)"
echo ""
echo -e "${YELLOW}  Note: Ansible was not uninstalled.${NC}"
echo -e "${YELLOW}  To remove it: sudo apt-get remove --purge ansible${NC}"
echo ""