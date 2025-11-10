#!/bin/sh
set -e

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

# Check for existing installation
if [ -f ".env" ]; then
    log_info "Existing installation found at $INSTALL_DIR"
    printf "${YELLOW}Do you want to update the existing installation? (y/N): ${NC}"
    read UPDATE_CHOICE
    if [ "$UPDATE_CHOICE" != "y" ] && [ "$UPDATE_CHOICE" != "Y" ]; then
        log_info "Keeping existing configuration. Exiting."
        exit 0
    fi
    # Load existing configuration
    . ./.env
    log_info "Loaded existing configuration for domain: $DOMAIN"

    # Backup existing configs
    BACKUP_DIR="backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup in $BACKUP_DIR"
    mkdir -p $BACKUP_DIR
    [ -f ".env" ] && cp .env $BACKUP_DIR/
    [ -f "wireguard/wg0.conf" ] && cp wireguard/wg0.conf $BACKUP_DIR/
    [ -f "caddy/Caddyfile" ] && cp caddy/Caddyfile $BACKUP_DIR/
    [ -f "wireguard/privatekey" ] && cp wireguard/privatekey $BACKUP_DIR/
    [ -f "wireguard/publickey" ] && cp wireguard/publickey $BACKUP_DIR/
fi

# Step 3: Get domain name from user (if not already set)
if [ -z "$DOMAIN" ]; then
    echo ""
    read -p "Enter your domain name (e.g., example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        log_error "Domain name is required"
    fi
    log_info "Using domain: $DOMAIN"
else
    log_info "Using existing domain: $DOMAIN"
    printf "${YELLOW}Do you want to change the domain? (y/N): ${NC}"
    read CHANGE_DOMAIN
    if [ "$CHANGE_DOMAIN" = "y" ] || [ "$CHANGE_DOMAIN" = "Y" ]; then
        read -p "Enter new domain name: " NEW_DOMAIN
        if [ -n "$NEW_DOMAIN" ]; then
            DOMAIN=$NEW_DOMAIN
            log_info "Updated domain to: $DOMAIN"
        fi
    fi
fi

# Step 4: Download or update configuration files
# Create configs directory
mkdir -p configs wireguard caddy

if [ -f "docker-compose.yml" ]; then
    log_info "Configuration files already exist"
    printf "${YELLOW}Do you want to update configuration templates? (y/N): ${NC}"
    read UPDATE_CONFIGS
    if [ "$UPDATE_CONFIGS" = "y" ] || [ "$UPDATE_CONFIGS" = "Y" ]; then
        log_info "Downloading latest configuration files..."

        # Download docker-compose.yml
        curl -sSL -o docker-compose.yml "$GITHUB_REPO/docker-compose.yml" || {
            log_error "Failed to download docker-compose.yml"
        }

        # Download config templates
        curl -sSL -o configs/wg0.conf.template "$GITHUB_REPO/configs/wg0.conf.template" || {
            log_error "Failed to download wg0.conf.template"
        }

        curl -sSL -o configs/Caddyfile.template "$GITHUB_REPO/configs/Caddyfile.template" || {
            log_error "Failed to download Caddyfile.template"
        }

        log_success "Configuration templates updated"
    else
        log_info "Using existing configuration templates"
    fi
else
    log_info "Downloading configuration files..."

    # Download docker-compose.yml
    curl -sSL -o docker-compose.yml "$GITHUB_REPO/docker-compose.yml" || {
        log_error "Failed to download docker-compose.yml"
    }

    # Download config templates
    curl -sSL -o configs/wg0.conf.template "$GITHUB_REPO/configs/wg0.conf.template" || {
        log_error "Failed to download wg0.conf.template"
    }

    curl -sSL -o configs/Caddyfile.template "$GITHUB_REPO/configs/Caddyfile.template" || {
        log_error "Failed to download Caddyfile.template"
    }

    log_success "Configuration files downloaded"
fi

# Step 5: Generate or load WireGuard keys
if [ -f "wireguard/privatekey" ] && [ -f "wireguard/publickey" ]; then
    log_info "Using existing WireGuard keys"
    VPS_PRIVATE_KEY=$(cat wireguard/privatekey)
    VPS_PUBLIC_KEY=$(cat wireguard/publickey)
    log_success "Loaded existing WireGuard keys"
else
    log_info "Generating new WireGuard keys..."

    # Use docker to generate keys for consistency
    log_info "Using Docker to generate WireGuard keys..."
    docker run --rm --entrypoint sh linuxserver/wireguard:latest -c "wg genkey" > wireguard/privatekey 2>/dev/null
    VPS_PRIVATE_KEY=$(cat wireguard/privatekey)
    VPS_PUBLIC_KEY=$(docker run --rm --entrypoint sh linuxserver/wireguard:latest -c "cat | wg pubkey" < wireguard/privatekey 2>/dev/null)
    echo "$VPS_PUBLIC_KEY" > wireguard/publickey

    # Save keys securely
    chmod 600 wireguard/privatekey
    log_success "WireGuard keys generated"
fi

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

# Step 10: Start or restart services with Docker Compose
# Check if services are already running
SERVICE_STATUS=$(docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null)

if echo "$SERVICE_STATUS" | grep -q "Up"; then
    log_info "Services are already running"
    printf "${YELLOW}Do you want to restart the services? (y/N): ${NC}"
    read RESTART_CHOICE
    if [ "$RESTART_CHOICE" = "y" ] || [ "$RESTART_CHOICE" = "Y" ]; then
        log_info "Restarting services..."
        docker compose restart || docker-compose restart
        sleep 5
        log_success "Services restarted"
    else
        log_info "Services kept running without restart"
    fi
else
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
fi

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
echo "   Add these DNS records to your domain:"
printf "   ${BLUE}A    *.${DOMAIN}    →  ${VPS_IP}${NC}\n"
printf "   ${BLUE}A    ${DOMAIN}       →  ${VPS_IP}${NC}\n"
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
printf "   ${BLUE}cd ${INSTALL_DIR}${NC}\n"
printf "   ${BLUE}# Edit wireguard/wg0.conf and add [Peer] section${NC}\n"
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