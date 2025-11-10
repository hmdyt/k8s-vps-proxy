#!/bin/bash
set -euo pipefail

# ================================
# K8s VPS Proxy Setup Script (frp)
# ================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Helper functions
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

# Banner
echo ""
echo "========================================="
echo "   K8s VPS Proxy Setup (frp)"
echo "========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run as root or with sudo"
fi

# Check required environment variables
if [ -z "${TOKEN:-}" ]; then
    log_error "TOKEN is required. Usage: TOKEN=yourtoken DOMAIN=example.com bash setup.sh"
fi

if [ -z "${DOMAIN:-}" ]; then
    log_error "DOMAIN is required. Usage: TOKEN=yourtoken DOMAIN=example.com bash setup.sh"
fi

log_info "Domain: $DOMAIN"
log_info "Token: ${TOKEN:0:8}..."

# Kill any process using port 80/443
log_info "Checking and killing processes on ports 80 and 443..."
for port in 80 443; do
    PIDs=$(lsof -ti :$port 2>/dev/null || true)
    if [ -n "$PIDs" ]; then
        log_info "Killing processes on port $port: $PIDs"
        echo "$PIDs" | xargs kill -9 2>/dev/null || true
    fi
done
log_success "Ports 80 and 443 are now available"

# Variables
FRP_VERSION="0.65.0"
INSTALL_DIR="/etc/frp"
LOG_DIR="/var/log/frp"

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        FRP_ARCH="amd64"
        ;;
    aarch64|arm64)
        FRP_ARCH="arm64"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        ;;
esac

log_info "Detected architecture: $ARCH ($FRP_ARCH)"

# Download and install frps
log_info "Downloading frp v${FRP_VERSION}..."
cd /tmp
FRP_PACKAGE="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
curl -sSL -o frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PACKAGE}.tar.gz" || log_error "Failed to download frp"

log_info "Extracting frp..."
tar xzf frp.tar.gz || log_error "Failed to extract frp"

log_info "Installing frps binary..."
install -m 755 ${FRP_PACKAGE}/frps /usr/local/bin/frps || log_error "Failed to install frps"
rm -rf frp.tar.gz ${FRP_PACKAGE}

log_success "frps binary installed to /usr/local/bin/frps"

# Create directories
log_info "Creating directories..."
mkdir -p $INSTALL_DIR
mkdir -p $LOG_DIR

# Get VPS public IP
log_info "Detecting VPS public IP..."
VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain || echo "")
if [ -z "$VPS_IP" ]; then
    log_error "Could not detect public IP"
fi
log_info "VPS IP: $VPS_IP"

# Generate frps.toml
log_info "Generating frps configuration..."
cat > $INSTALL_DIR/frps.toml <<EOF
# frps configuration file

bindPort = 7000
vhostHTTPPort = 80
vhostHTTPSPort = 443

# Authentication
auth.method = "token"
auth.token = "$TOKEN"

# Web dashboard
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "$TOKEN"

# Logging
log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 3

# Domain for vhost
subdomainHost = "$DOMAIN"
EOF

log_success "Configuration created at $INSTALL_DIR/frps.toml"

# Create systemd service
log_info "Creating systemd service..."
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c $INSTALL_DIR/frps.toml
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log_success "Systemd service created"

# Configure firewall
if command -v ufw >/dev/null 2>&1; then
    log_info "Configuring firewall..."
    ufw --force enable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 7000/tcp
    ufw allow 7500/tcp
    ufw reload
    log_success "Firewall configured"
fi

# Start and enable frps service
log_info "Starting frps service..."
systemctl daemon-reload
systemctl enable frps
systemctl restart frps
sleep 2

# Check service status
if systemctl is-active --quiet frps; then
    log_success "frps service is running"
else
    log_error "frps service failed to start. Check logs with: journalctl -u frps -n 50"
fi

# Generate K8s frpc configuration
K8S_FRPC_CONFIG="frpc.toml"
cat > ~/$K8S_FRPC_CONFIG <<EOF
# frpc configuration for Kubernetes

serverAddr = "$VPS_IP"
serverPort = 7000

auth.method = "token"
auth.token = "$TOKEN"

# HTTP proxy - forwards to K8s Ingress
[[proxies]]
name = "web"
type = "http"
localIP = "127.0.0.1"
localPort = 80
customDomains = ["*.${DOMAIN}"]

# HTTPS proxy - forwards to K8s Ingress
[[proxies]]
name = "web-https"
type = "https"
localIP = "127.0.0.1"
localPort = 443
customDomains = ["*.${DOMAIN}"]
EOF

# Display setup information
echo ""
echo "========================================="
log_success "VPS Setup Complete!"
echo "========================================="
echo ""
printf "${GREEN}VPS Configuration:${NC}\n"
echo "  Domain: $DOMAIN"
echo "  Public IP: $VPS_IP"
echo "  frp bind port: 7000"
echo "  frp dashboard: http://$VPS_IP:7500"
echo "  Dashboard user: admin"
echo "  Dashboard pass: $TOKEN"
echo ""
printf "${GREEN}Service Status:${NC}\n"
systemctl status frps --no-pager | head -5
echo ""
echo "========================================="
echo ""
printf "${YELLOW}Next Steps:${NC}\n"
echo ""
echo "1. Configure DNS:"
echo "   Add this DNS record to your domain:"
printf "   ${BLUE}A    *.${DOMAIN}    →  ${VPS_IP}${NC}\n"
echo ""
echo "2. Setup K8s frpc client:"
echo "   Configuration saved to: ~/$K8S_FRPC_CONFIG"
echo ""
printf "${GREEN}K8s frpc Configuration:${NC}\n"
echo "========================================="
cat ~/$K8S_FRPC_CONFIG
echo "========================================="
echo ""
printf "${YELLOW}To deploy frpc on K8s, create:${NC}\n"
echo ""
echo "1. ConfigMap with frpc.toml"
echo "2. Deployment with frp client image"
echo "3. Ensure frpc can reach your Ingress at 127.0.0.1:80/443"
echo ""
echo "========================================="
echo ""
printf "${GREEN}Useful Commands:${NC}\n"
echo "  systemctl status frps         # Check service status"
echo "  systemctl restart frps        # Restart service"
echo "  journalctl -u frps -f         # View logs"
echo "  cat $INSTALL_DIR/frps.toml    # View config"
echo ""
log_success "Installation completed successfully!"
echo ""
