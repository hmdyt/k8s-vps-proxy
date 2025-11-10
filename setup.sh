#!/bin/bash
set -e

# ================================
# K8s VPS Proxy Setup Script
# ================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Banner
echo ""
echo "========================================="
echo "   K8s VPS Proxy Setup"
echo "   WireGuard + Caddy Auto Configuration"
echo "========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root or with sudo"
fi

# Variables
INSTALL_DIR="/opt/k8s-vps-proxy"
GITHUB_REPO="https://raw.githubusercontent.com/hmdyt/k8s-vps-proxy/main"
VPS_WG_IP="10.0.0.1"
K8S_WG_IP="10.0.0.2"
WG_PORT="51820"

# Step 1: Check and install Docker if needed
log_info "Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    log_warning "Docker not found. Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    log_success "Docker installed successfully"
else
    log_success "Docker is already installed"
fi

# Check Docker Compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    log_warning "Docker Compose not found. Installing..."
    apt-get update
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose
    log_success "Docker Compose installed"
else
    log_success "Docker Compose is already installed"
fi

# Step 2: Create installation directory
log_info "Creating installation directory..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Step 3: Get domain name from user
echo ""
read -p "Enter your domain name (e.g., example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    log_error "Domain name is required"
fi

log_info "Using domain: $DOMAIN"

# Step 4: Download configuration files
log_info "Downloading configuration files..."

# Download docker-compose.yml
curl -sSL -o docker-compose.yml "$GITHUB_REPO/docker-compose.yml" || {
    log_error "Failed to download docker-compose.yml"
}

# Create configs directory
mkdir -p configs wireguard caddy

# Download config templates
curl -sSL -o configs/wg0.conf.template "$GITHUB_REPO/configs/wg0.conf.template" || {
    log_error "Failed to download wg0.conf.template"
}

curl -sSL -o configs/Caddyfile.template "$GITHUB_REPO/configs/Caddyfile.template" || {
    log_error "Failed to download Caddyfile.template"
}

# Step 5: Generate WireGuard keys
log_info "Generating WireGuard keys..."

# Check if wg command exists, if not use docker
if command -v wg &> /dev/null; then
    VPS_PRIVATE_KEY=$(wg genkey)
    VPS_PUBLIC_KEY=$(echo $VPS_PRIVATE_KEY | wg pubkey)
else
    # Use docker to generate keys
    docker run --rm -i --entrypoint sh linuxserver/wireguard:latest -c "wg genkey" > wireguard/privatekey
    docker run --rm -i --entrypoint sh linuxserver/wireguard:latest -c "cat | wg pubkey" < wireguard/privatekey > wireguard/publickey
    VPS_PRIVATE_KEY=$(cat wireguard/privatekey)
    VPS_PUBLIC_KEY=$(cat wireguard/publickey)
fi

# Save keys securely
echo "$VPS_PRIVATE_KEY" > wireguard/privatekey
echo "$VPS_PUBLIC_KEY" > wireguard/publickey
chmod 600 wireguard/privatekey

log_success "WireGuard keys generated"

# Step 6: Get VPS public IP
log_info "Detecting VPS public IP..."
VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)
if [ -z "$VPS_IP" ]; then
    read -p "Could not detect public IP. Please enter VPS IP manually: " VPS_IP
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

# Step 8: Generate actual config files from templates
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

# Wildcard subdomain routing
*.${DOMAIN} {
    reverse_proxy http://${K8S_WG_IP}:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}

# Root domain
${DOMAIN} {
    reverse_proxy http://${K8S_WG_IP}:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

# Step 9: Configure UFW firewall if available
if command -v ufw &> /dev/null; then
    log_info "Configuring firewall..."
    ufw --force enable
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    ufw allow ${WG_PORT}/udp comment "WireGuard"
    log_success "Firewall configured"
fi

# Step 10: Start services with Docker Compose
log_info "Starting services..."
docker compose up -d || docker-compose up -d

# Wait for services to start
sleep 5

# Check if services are running
if docker compose ps | grep -q "Up" || docker-compose ps | grep -q "Up"; then
    log_success "Services started successfully"
else
    log_error "Failed to start services. Check logs with: docker-compose logs"
fi

# Step 11: Display setup information
echo ""
echo "========================================="
log_success "VPS Setup Complete!"
echo "========================================="
echo ""
echo -e "${GREEN}VPS Configuration:${NC}"
echo "  Domain: $DOMAIN"
echo "  Public IP: $VPS_IP"
echo "  WireGuard Port: $WG_PORT"
echo "  WireGuard IP: ${VPS_WG_IP}/24"
echo ""
echo -e "${GREEN}VPS WireGuard Public Key:${NC}"
echo "  $VPS_PUBLIC_KEY"
echo ""
echo "========================================="
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Configure DNS:"
echo "   Add these DNS records to your domain:"
echo "   ${BLUE}A    *.${DOMAIN}    →  ${VPS_IP}${NC}"
echo "   ${BLUE}A    ${DOMAIN}       →  ${VPS_IP}${NC}"
echo ""
echo "2. Setup K8s WireGuard client with this configuration:"
echo ""
echo "   [Interface]"
echo "   Address = ${K8S_WG_IP}/24"
echo "   PrivateKey = <YOUR_K8S_PRIVATE_KEY>"
echo ""
echo "   [Peer]"
echo "   PublicKey = ${VPS_PUBLIC_KEY}"
echo "   Endpoint = ${VPS_IP}:${WG_PORT}"
echo "   AllowedIPs = ${VPS_WG_IP}/32"
echo "   PersistentKeepalive = 25"
echo ""
echo "3. After K8s setup, add K8s peer to VPS:"
echo "   ${BLUE}cd ${INSTALL_DIR}${NC}"
echo "   ${BLUE}# Edit wireguard/wg0.conf and add [Peer] section${NC}"
echo "   ${BLUE}docker-compose restart wireguard${NC}"
echo ""
echo "========================================="
echo ""
echo -e "${GREEN}Useful Commands:${NC}"
echo "  cd ${INSTALL_DIR}"
echo "  docker-compose logs -f        # View logs"
echo "  docker exec wireguard wg show # Check WireGuard status"
echo "  docker-compose restart        # Restart services"
echo ""

# Save setup info to file
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

log_success "Setup information saved to ${INSTALL_DIR}/setup-info.txt"
echo ""
echo "Installation completed successfully!"