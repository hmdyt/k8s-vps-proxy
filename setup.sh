#!/bin/bash
set -euo pipefail

# ================================
# K8s VPS Proxy Setup Script
# ================================

# Color definitions (POSIX compatible)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions (POSIX compatible)
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

# Banner
echo ""
echo "========================================="
echo "   K8s VPS Proxy Setup"
echo "   WireGuard + Caddy Auto Configuration"
echo "========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run as root or with sudo"
fi

# Variables
INSTALL_DIR="/opt/k8s-vps-proxy"
GITHUB_REPO="https://raw.githubusercontent.com/hmdyt/k8s-vps-proxy/main"
VPS_WG_IP="10.0.0.1"
K8S_WG_IP="10.0.0.2"
WG_PORT="51820"

# Initialize optional environment variables
VPS_IP="${VPS_IP:-}"
DOMAIN="${DOMAIN:-}"

# Step 1: Install Docker if needed (using snap for simplicity)
log_info "Checking Docker installation..."
if ! command -v docker >/dev/null 2>&1; then
    log_info "Installing Docker via snap..."
    snap install docker
    log_success "Docker installed"
    # For snap Docker, we might need to use snap run docker
    if [ -x "/snap/bin/docker" ]; then
        alias docker="/snap/bin/docker"
    fi
else
    log_success "Docker already installed"
fi

# Verify Docker is working
docker version >/dev/null 2>&1 || log_error "Docker is not working properly"

# Step 2: Get domain name from environment variable
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "" ]; then
    log_error "Domain name is required. Set DOMAIN environment variable: DOMAIN=example.com curl ... | bash"
fi
# Additional validation for empty string
if [ ${#DOMAIN} -eq 0 ]; then
    log_error "Domain cannot be empty string"
fi
log_info "Using domain: $DOMAIN"

# Step 3: Clean and create installation directory
log_info "Setting up installation directory..."
rm -rf $INSTALL_DIR
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Step 4: Download configuration files
log_info "Downloading configuration files..."
mkdir -p configs wireguard caddy

curl -sSL -o docker-compose.yml "$GITHUB_REPO/docker-compose.yml" || {
    log_error "Failed to download docker-compose.yml"
}

curl -sSL -o configs/wg0.conf.template "$GITHUB_REPO/configs/wg0.conf.template" || {
    log_error "Failed to download wg0.conf.template"
}

curl -sSL -o configs/Caddyfile.template "$GITHUB_REPO/configs/Caddyfile.template" || {
    log_error "Failed to download Caddyfile.template"
}

# Step 5: Generate WireGuard keys
log_info "Generating WireGuard keys..."

# Generate private key
log_info "Generating private key..."
docker run --rm --entrypoint sh linuxserver/wireguard:latest -c "wg genkey" > wireguard/privatekey 2>/dev/null || log_error "Failed to generate private key"

if [ ! -f wireguard/privatekey ] || [ ! -s wireguard/privatekey ]; then
    log_error "Private key file is empty or doesn't exist"
fi

VPS_PRIVATE_KEY=$(cat wireguard/privatekey)
log_info "Private key generated successfully"

# Generate public key using echo instead of pipe
log_info "Generating public key..."
VPS_PUBLIC_KEY=$(echo "$VPS_PRIVATE_KEY" | docker run --rm -i --entrypoint sh linuxserver/wireguard:latest -c "wg pubkey") || log_error "Failed to generate public key"

if [ -z "$VPS_PUBLIC_KEY" ]; then
    log_error "Failed to generate public key - output is empty"
fi

# Save keys
echo "$VPS_PUBLIC_KEY" > wireguard/publickey
chmod 600 wireguard/privatekey

log_success "WireGuard keys generated"

# Step 6: Get VPS public IP (from env or auto-detect)
if [ -z "$VPS_IP" ]; then
    log_info "Detecting VPS public IP..."
    VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)
    if [ -z "$VPS_IP" ]; then
        log_error "Could not detect public IP. Set VPS_IP environment variable: VPS_IP=x.x.x.x DOMAIN=... curl ... | bash"
    fi
fi
log_info "VPS IP: $VPS_IP"

# Step 7: Create .env file
log_info "Creating environment configuration..."
cat > .env <<EOF
# Domain Configuration
DOMAIN=$DOMAIN

# Network Configuration
VPS_WG_IP=$VPS_WG_IP
K8S_WG_IP=$K8S_WG_IP
WG_PORT=$WG_PORT
VPS_IP=$VPS_IP

# Timezone
TZ=Asia/Tokyo
EOF

# Step 8: Generate actual config files
log_info "Generating configuration files..."

# Generate wg0.conf
cat > wireguard/wg0.conf <<EOF
[Interface]
Address = ${VPS_WG_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# K8s peer will be added here later
# Example:
# [Peer]
# PublicKey = <K8S_PUBLIC_KEY>
# AllowedIPs = ${K8S_WG_IP}/32
EOF

# Generate Caddyfile
cat > caddy/Caddyfile <<EOF
# Global options
{
    email admin@${DOMAIN}
}

# Wildcard subdomain routing to K8s Ingress
*.${DOMAIN} {
    reverse_proxy http://${K8S_WG_IP}:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

# Step 9: Configure firewall (if ufw exists)
if command -v ufw >/dev/null 2>&1; then
    log_info "Configuring firewall..."
    ufw --force enable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow ${WG_PORT}/udp
    log_success "Firewall configured"
fi

# Step 10: Start services
log_info "Starting services..."
docker compose down 2>/dev/null || true
docker compose up -d || docker-compose up -d

# Wait for services
sleep 5

# Step 11: Display setup information
echo ""
echo "========================================="
log_success "VPS Setup Complete!"
echo "========================================="
echo ""
printf "${GREEN}VPS Configuration:${NC}\n"
echo "  Domain: $DOMAIN"
echo "  Public IP: $VPS_IP"
echo "  WireGuard Port: $WG_PORT"
echo "  WireGuard IP: ${VPS_WG_IP}/24"
echo ""
printf "${GREEN}VPS WireGuard Public Key:${NC}\n"
echo "  $VPS_PUBLIC_KEY"
echo ""
echo "========================================="
echo ""
printf "${YELLOW}Next Steps:${NC}\n"
echo ""
echo "1. Configure DNS:"
echo "   Add this DNS record to your domain:"
printf "   ${BLUE}A    *.${DOMAIN}    →  ${VPS_IP}${NC}\n"
echo ""
echo "2. Setup K8s WireGuard client:"
echo ""
printf "${GREEN}K8s WireGuard Configuration (wg0.conf):${NC}\n"
echo "========================================="
cat <<WGCONFIG
[Interface]
Address = ${K8S_WG_IP}/24
PrivateKey = <YOUR_K8S_PRIVATE_KEY>
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${VPS_PUBLIC_KEY}
Endpoint = ${VPS_IP}:${WG_PORT}
AllowedIPs = ${VPS_WG_IP}/32
PersistentKeepalive = 25
WGCONFIG
echo "========================================="
echo ""
printf "${YELLOW}Note:${NC} Generate K8s private key with:\n"
printf "  ${BLUE}docker run --rm linuxserver/wireguard:latest wg genkey${NC}\n"
echo ""
echo "3. After K8s setup, add K8s peer to VPS:"
printf "   ${BLUE}cd ${INSTALL_DIR}${NC}\n"
printf "   ${BLUE}# Edit wireguard/wg0.conf and add [Peer] section:${NC}\n"
echo "   [Peer]"
echo "   PublicKey = <K8S_PUBLIC_KEY>"
echo "   AllowedIPs = ${K8S_WG_IP}/32"
echo ""
printf "   ${BLUE}docker-compose restart wireguard${NC}\n"
echo ""
echo "========================================="
echo ""
printf "${GREEN}Useful Commands:${NC}\n"
echo "  cd ${INSTALL_DIR}"
echo "  docker-compose logs -f        # View logs"
echo "  docker exec wireguard wg show # Check WireGuard status"
echo "  docker-compose restart        # Restart services"
echo ""

# Save setup info
cat > setup-info.txt <<EOF
VPS Setup Information
=====================
Date: $(date)
Domain: ${DOMAIN}
VPS IP: ${VPS_IP}
WireGuard Port: ${WG_PORT}
VPS WireGuard IP: ${VPS_WG_IP}

VPS WireGuard Public Key:
${VPS_PUBLIC_KEY}

Installation Directory: ${INSTALL_DIR}
EOF

# Save K8s WireGuard config template
cat > k8s-wg0.conf <<EOF
[Interface]
Address = ${K8S_WG_IP}/24
PrivateKey = <YOUR_K8S_PRIVATE_KEY>
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${VPS_PUBLIC_KEY}
Endpoint = ${VPS_IP}:${WG_PORT}
AllowedIPs = ${VPS_WG_IP}/32
PersistentKeepalive = 25
EOF

log_success "Setup information saved to ${INSTALL_DIR}/setup-info.txt"
log_success "K8s WireGuard config saved to ${INSTALL_DIR}/k8s-wg0.conf"
echo ""
printf "${GREEN}To use the K8s config:${NC}\n"
printf "  ${BLUE}cat ${INSTALL_DIR}/k8s-wg0.conf${NC}\n"
echo ""
echo "Installation completed successfully!"