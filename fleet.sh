#!/bin/bash
# =============================================================================
#  Fleet Manager — Bootstrap Script
#  Run on a fresh Raspberry Pi OS (64-bit) with Node-RED already installed.
#  Usage: bash setup-fleet-manager.sh
# =============================================================================

set -e

GITHUB_USER="zhide-pds"
GITHUB_REPO="fleet"
GITHUB_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

FLEET_DIR="/home/pi/fleet-management"
NODERED_DIR="/home/pi/.node-red"
SETTINGS_JS="${NODERED_DIR}/settings.js"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}━━━ $1 ━━━${NC}"; }

# =============================================================================
section "Checking prerequisites"
# =============================================================================

[[ $(id -u) -ne 0 ]] || fail "Do not run as root. Run as the pi user: bash setup-fleet-manager.sh"
command -v node-red >/dev/null 2>&1 || fail "Node-RED not found. Install it first: bash <(curl -sL https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered)"
command -v ansible >/dev/null 2>&1 || { warn "Ansible not found — will install"; INSTALL_ANSIBLE=true; }
command -v docker >/dev/null 2>&1 || { warn "Docker not found — will install"; INSTALL_DOCKER=true; }

log "Prerequisites checked"

# =============================================================================
section "Installing system packages"
# =============================================================================

sudo apt-get update -qq

if [[ "$INSTALL_ANSIBLE" == true ]]; then
    sudo apt-get install -y -qq ansible
    log "Ansible installed: $(ansible --version | head -1)"
fi

if [[ "$INSTALL_DOCKER" == true ]]; then
    sudo apt-get install -y -qq docker.io docker-compose
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker pi
    log "Docker installed: $(docker --version)"
    warn "Docker group added — you may need to log out and back in if docker commands fail"
fi

sudo apt-get install -y -qq unzip curl
log "System packages ready"

# =============================================================================
section "Downloading fleet-management directory"
# =============================================================================

TMP_ZIP="/tmp/fleet-management.zip"
curl -fsSL "https://github.com/${GITHUB_USER}/${GITHUB_REPO}/raw/${GITHUB_BRANCH}/fleet-management.zip" \
    -o "$TMP_ZIP" || fail "Failed to download fleet-management.zip from GitHub"

if [[ -d "$FLEET_DIR" ]]; then
    warn "fleet-management directory already exists — backing up to ${FLEET_DIR}.bak"
    mv "$FLEET_DIR" "${FLEET_DIR}.bak"
fi

cd /home/pi
unzip -q "$TMP_ZIP"
rm "$TMP_ZIP"

sudo chown -R pi:pi "$FLEET_DIR"
sudo chmod -R 755 "$FLEET_DIR"
log "fleet-management directory extracted to ${FLEET_DIR}"

# =============================================================================
section "Creating required directories"
# =============================================================================

sudo mkdir -p /verdaccio/storage /verdaccio/conf
sudo mkdir -p /var/cache/apt-cacher-ng /var/log/apt-cacher-ng
sudo chown -R 10001:65533 /verdaccio/storage /verdaccio/conf 2>/dev/null || true
log "Storage directories created"

# =============================================================================
section "Writing docker-compose.yml"
# =============================================================================

cat > /home/pi/docker-compose.yml << 'DOCKEREOF'
version: '3'
services:
  verdaccio:
    image: verdaccio/verdaccio
    container_name: verdaccio
    ports:
      - "4873:4873"
    volumes:
      - /verdaccio/storage:/verdaccio/storage
    restart: unless-stopped

  apt-cacher-ng:
    image: sameersbn/apt-cacher-ng
    container_name: apt-cacher-ng
    ports:
      - "3142:3142"
    volumes:
      - /var/cache/apt-cacher-ng:/var/cache/apt-cacher-ng
      - /var/log/apt-cacher-ng:/var/log/apt-cacher-ng
    restart: unless-stopped
DOCKEREOF

log "docker-compose.yml written"

# =============================================================================
section "Starting Docker services"
# =============================================================================

cd /home/pi
docker-compose up -d 2>&1 | grep -E "(Creating|Starting|Up|error)" || true

# Wait for Verdaccio to be ready
echo "Waiting for Verdaccio to start..."
for i in $(seq 1 15); do
    if curl -s http://localhost:4873/ >/dev/null 2>&1; then
        log "Verdaccio is up"
        break
    fi
    sleep 2
    [[ $i -eq 15 ]] && warn "Verdaccio not responding yet — may still be starting"
done

# Wait for apt-cacher-ng
for i in $(seq 1 10); do
    if curl -s http://localhost:3142/ >/dev/null 2>&1; then
        log "apt-cacher-ng is up"
        break
    fi
    sleep 2
    [[ $i -eq 10 ]] && warn "apt-cacher-ng not responding yet — may still be starting"
done

# =============================================================================
section "Installing Node-RED settings.js"
# =============================================================================

[[ -d "$NODERED_DIR" ]] || fail "Node-RED user directory not found at ${NODERED_DIR}. Has Node-RED been run at least once?"

# Backup existing settings.js if present
if [[ -f "$SETTINGS_JS" ]]; then
    cp "$SETTINGS_JS" "${SETTINGS_JS}.bak"
    log "Existing settings.js backed up to ${SETTINGS_JS}.bak"
fi

# Download and replace with repo version
curl -fsSL "${BASE_URL}/settings.js" -o "$SETTINGS_JS" \
    || fail "Failed to download settings.js from GitHub"
sudo chown pi:pi "$SETTINGS_JS"
log "settings.js replaced from GitHub"

# =============================================================================
section "Configuring sudoers for Node-RED"
# =============================================================================

sudo tee /etc/sudoers.d/nodered-apt > /dev/null << 'SUDOEOF'
pi ALL=(ALL) NOPASSWD: /usr/bin/apt-get
pi ALL=(ALL) NOPASSWD: /bin/mv
pi ALL=(ALL) NOPASSWD: /bin/rm
SUDOEOF
sudo chmod 440 /etc/sudoers.d/nodered-apt
log "sudoers configured"

# =============================================================================
section "Generating SSH key for Ansible"
# =============================================================================

if [[ -f "/home/pi/.ssh/id_ed25519" ]]; then
    warn "SSH key already exists — skipping generation"
else
    ssh-keygen -t ed25519 -C "fleet-manager" -f /home/pi/.ssh/id_ed25519 -N ""
    log "SSH key generated: /home/pi/.ssh/id_ed25519"
fi

# =============================================================================
section "Importing Node-RED flow"
# =============================================================================

FLOW_FILE="/tmp/fleet-flows.json"
curl -fsSL "${BASE_URL}/flow.json" \
    -o "$FLOW_FILE" || fail "Failed to download flow.json from GitHub"

cp "$FLOW_FILE" "${NODERED_DIR}/flows.json"
sudo chown pi:pi "${NODERED_DIR}/flows.json"
log "Flow file copied to ${NODERED_DIR}/flows.json"

# =============================================================================
section "Restarting Node-RED"
# =============================================================================

sudo systemctl restart nodered
sleep 5

if sudo systemctl is-active --quiet nodered; then
    log "Node-RED restarted successfully"
else
    fail "Node-RED failed to start — check: sudo journalctl -u nodered -n 50"
fi

# =============================================================================
section "Setting up apt-cacher-ng permissions"
# =============================================================================

ACNG_UID=$(docker exec apt-cacher-ng id -u 2>/dev/null || echo "105")
ACNG_GID=$(docker exec apt-cacher-ng id -g 2>/dev/null || echo "65534")
sudo chown -R "${ACNG_UID}:${ACNG_GID}" /var/cache/apt-cacher-ng /var/log/apt-cacher-ng 2>/dev/null || \
    warn "Could not chown apt-cacher-ng dirs — may need manual fix after first run"

# =============================================================================
section "Final verification"
# =============================================================================

PI_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Fleet Manager setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Fleet Manager GUI:   ${YELLOW}http://${PI_IP}:1880/fleet${NC}"
echo -e "  Node-RED editor:     ${YELLOW}http://${PI_IP}:1880${NC}"
echo -e "  Verdaccio (NPM):     ${YELLOW}http://${PI_IP}:4873${NC}"
echo -e "  apt-cacher-ng (APT): ${YELLOW}http://${PI_IP}:3142${NC}"
echo ""
echo -e "  SSH public key (copy to fleet devices):"
echo -e "  ${YELLOW}$(cat /home/pi/.ssh/id_ed25519.pub)${NC}"
echo ""
echo -e "  To add a fleet device, run:"
echo -e "  ${YELLOW}ssh-copy-id pi@<device-ip>${NC}"
echo ""
echo -e "  Inventory file: ${YELLOW}${FLEET_DIR}/inventory.ini${NC}"
echo ""
