#!/bin/bash

# =============================================================================
# MinIO Installation Script for Internal Standalone Server
# =============================================================================
# This script sets up MinIO object storage on a dedicated internal server.
# No SSL/NPM needed — accessed via internal IP only.
# Supports both direct internet and cache server installation.
# Run with: sudo bash start.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Global variables
USE_CACHE_SERVER="no"
CACHE_SERVER_IP=""

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${BOLD}$1${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_step() { echo -e "${CYAN}▶ $1${NC}"; }

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-$1
}

# =============================================================================
# Cache Server Configuration
# =============================================================================

ask_cache_server() {
    print_header "🌐 Download Source Selection"
    
    echo ""
    echo "Where should Docker images and packages be downloaded from?"
    echo ""
    echo "  1) Direct Internet (requires internet connection)"
    echo "  2) Internal Cache Server (for offline environment)"
    echo ""
    
    while true; do
        read -p "Your choice (1 or 2): " choice
        case $choice in
            1)
                USE_CACHE_SERVER="no"
                print_info "Using direct internet"
                break
                ;;
            2)
                USE_CACHE_SERVER="yes"
                read -p "Cache server IP address [10.10.10.111]: " CACHE_SERVER_IP
                CACHE_SERVER_IP=${CACHE_SERVER_IP:-10.10.10.111}
                
                # Test cache server connectivity
                print_step "Testing cache server connectivity..."
                if ping -c 1 -W 2 "$CACHE_SERVER_IP" >/dev/null 2>&1; then
                    print_success "Cache server is reachable: $CACHE_SERVER_IP"
                else
                    print_warning "Cache server not responding, but continuing..."
                fi
                break
                ;;
            *)
                print_error "Please select 1 or 2"
                ;;
        esac
    done
}

configure_docker_for_cache() {
    if [ "$USE_CACHE_SERVER" != "yes" ]; then
        return
    fi
    
    print_header "Configuring Docker for Cache Server"
    
    local daemon_json="/etc/docker/daemon.json"
    
    print_step "Creating $daemon_json file..."
    
    cat > "$daemon_json" << EOF
{
  "registry-mirrors": [
    "http://${CACHE_SERVER_IP}:5001"
  ],
  "insecure-registries": [
    "${CACHE_SERVER_IP}:5001",
    "${CACHE_SERVER_IP}:5002",
    "${CACHE_SERVER_IP}:5003",
    "${CACHE_SERVER_IP}:5004",
    "${CACHE_SERVER_IP}:5005"
  ]
}
EOF
    
    print_success "daemon.json file created"
    
    # Restart Docker if it's already running
    if systemctl is-active --quiet docker; then
        print_step "Restarting Docker to apply settings..."
        systemctl restart docker
        sleep 3
        print_success "Docker restarted"
    fi
}

update_compose_images() {
    if [ "$USE_CACHE_SERVER" != "yes" ]; then
        return
    fi
    
    print_header "Updating Docker Images in docker-compose.yml"
    
    local compose_file="$SCRIPT_DIR/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        print_error "docker-compose.yml file not found!"
        return
    fi
    
    print_step "Changing images to cache server..."
    
    # Backup original
    cp "$compose_file" "$compose_file.backup"
    
    # Update images to use cache server (port 5003 - Quay.io mirror)
    sed -i "s|image: minio/minio:latest|image: ${CACHE_SERVER_IP}:5003/minio/minio:latest|g" "$compose_file"
    sed -i "s|image: minio/mc:latest|image: ${CACHE_SERVER_IP}:5003/minio/mc:latest|g" "$compose_file"
    sed -i "s|image: prom/node-exporter:latest|image: ${CACHE_SERVER_IP}:5003/prom/node-exporter:latest|g" "$compose_file"
    sed -i "s|image: zcube/cadvisor:latest|image: ${CACHE_SERVER_IP}:5003/zcube/cadvisor:latest|g" "$compose_file"
    sed -i "s|image: grafana/promtail:latest|image: ${CACHE_SERVER_IP}:5003/grafana/promtail:latest|g" "$compose_file"
    
    # Also update if images already have cache server IP (in case of re-run)
    sed -i "s|image: [0-9.]*:500[0-9]/minio/minio:latest|image: ${CACHE_SERVER_IP}:5003/minio/minio:latest|g" "$compose_file"
    sed -i "s|image: [0-9.]*:500[0-9]/minio/mc:latest|image: ${CACHE_SERVER_IP}:5003/minio/mc:latest|g" "$compose_file"
    sed -i "s|image: [0-9.]*:500[0-9]/prom/node-exporter:latest|image: ${CACHE_SERVER_IP}:5003/prom/node-exporter:latest|g" "$compose_file"
    sed -i "s|image: [0-9.]*:500[0-9]/zcube/cadvisor:latest|image: ${CACHE_SERVER_IP}:5003/zcube/cadvisor:latest|g" "$compose_file"
    sed -i "s|image: [0-9.]*:500[0-9]/grafana/promtail:latest|image: ${CACHE_SERVER_IP}:5003/grafana/promtail:latest|g" "$compose_file"
    
    print_success "Images updated (using ${CACHE_SERVER_IP}:5003)"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run with root access"
        echo "Please run with sudo: sudo bash $0"
        exit 1
    fi
}

check_system() {
    print_header "Checking Prerequisites"
    
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$ram_gb" -lt 2 ]; then
        print_warning "RAM is less than 2GB. Minimum 4GB recommended."
    else
        print_success "RAM: ${ram_gb}GB"
    fi
    
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$disk_gb" -lt 20 ]; then
        print_error "Insufficient disk space. Minimum 20GB required."
        exit 1
    else
        print_success "Free disk space: ${disk_gb}GB"
    fi
    
    for port in 9000 9001; do
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            print_warning "Port $port is already in use"
        fi
    done
}

# =============================================================================
# Installation
# =============================================================================

install_docker() {
    print_header "Installing Docker"
    
    if command -v docker &> /dev/null; then
        print_info "Docker is already installed"
        docker --version
    else
        print_step "Installing Docker..."
        
        if [ "$USE_CACHE_SERVER" = "yes" ]; then
            # Configure apt to use cache server
            print_step "Configuring apt to use cache server..."
            echo "Acquire::http::Proxy \"http://${CACHE_SERVER_IP}:3142\";" > /etc/apt/apt.conf.d/00proxy
            echo "Acquire::https::Proxy \"http://${CACHE_SERVER_IP}:3142\";" >> /etc/apt/apt.conf.d/00proxy
        fi
        
        apt update -qq
        apt install -y -qq curl ca-certificates gnupg lsb-release
        
        if [ "$USE_CACHE_SERVER" = "yes" ]; then
            # Get Docker GPG key from cache server
            print_step "Getting Docker GPG key from cache server..."
            curl -fsSL "http://${CACHE_SERVER_IP}/keys/docker.gpg" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        else
            # Get Docker GPG key from internet
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        fi
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt update -qq
        apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl enable docker
        systemctl start docker
        
        print_success "Docker installed"
    fi
    
    # Configure Docker for cache server after installation
    configure_docker_for_cache
}

# =============================================================================
# Configuration
# =============================================================================

configure_env() {
    print_header "MinIO Configuration"
    
    local env_file="$SCRIPT_DIR/.env"
    
    # Check if .env already has real values
    if [ -f "$env_file" ] && ! grep -q "CHANGE_ME" "$env_file" 2>/dev/null; then
        print_info ".env file already configured"
        source "$env_file"
        return
    fi
    
    # Auto-generate root password
    ROOT_PASS=$(generate_password 32)
    
    # Generate service account credentials
    INGEST_ACCESS=$(generate_password 32)
    INGEST_SECRET=$(generate_password 43)
    CENTRAL_ACCESS=$(generate_password 32)
    CENTRAL_SECRET=$(generate_password 43)
    USERS_ACCESS=$(generate_password 32)
    USERS_SECRET=$(generate_password 43)
    
    # Ask for IPs
    echo ""
    read -p "Internal LAN IP of this server [192.168.100.105]: " LAN_IP
    LAN_IP=${LAN_IP:-192.168.100.105}
    
    read -p "DMZ IP of this server [10.10.10.50]: " DMZ_IP
    DMZ_IP=${DMZ_IP:-10.10.10.50}
    
    # Write .env
    cat > "$env_file" << EOF
# =============================================================================
# MinIO Server Configuration (Internal Network)
# Generated: $(date -Iseconds)
# =============================================================================

# Server IPs (internal network)
LAN_IP=${LAN_IP}
DMZ_IP=${DMZ_IP}

# MinIO Root Credentials (admin)
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=${ROOT_PASS}

# Bucket names
BUCKET_INGEST=ingest-system
BUCKET_TEMP=temp-userfile
BUCKET_USERS=users-system

# Service Account for Ingest System (access to ingest-system bucket only)
INGEST_ACCESS_KEY=${INGEST_ACCESS}
INGEST_SECRET_KEY=${INGEST_SECRET}

# Service Account for Central System (access to temp-userfile and users-system buckets)
CENTRAL_ACCESS_KEY=${CENTRAL_ACCESS}
CENTRAL_SECRET_KEY=${CENTRAL_SECRET}

# Service Account for Users System (access to temp-userfile and users-system buckets)
USERS_ACCESS_KEY=${USERS_ACCESS}
USERS_SECRET_KEY=${USERS_SECRET}
EOF
    
    chmod 600 "$env_file"
    
    # Source the new env
    source "$env_file"
    
    print_success "Configuration file created"
}

# =============================================================================
# Deploy
# =============================================================================

deploy_services() {
    print_header "Deploying Services"
    
    cd "$SCRIPT_DIR"
    
    # Update docker-compose.yml if using cache server
    update_compose_images
    
    print_step "Pulling Docker images..."
    docker compose pull
    
    print_step "Starting MinIO..."
    docker compose up -d
    
    print_step "Waiting for MinIO to be ready..."
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T minio curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        print_error "MinIO failed to start. Check logs: docker compose logs minio"
        exit 1
    fi
    
    print_success "MinIO is ready"
    
    # Wait for minio-init to complete
    print_step "Running minio-init (creating buckets and service accounts)..."
    sleep 10
    docker compose logs minio-init 2>/dev/null || true
    
    print_success "Services deployed successfully"
}

configure_firewall() {
    print_header "Configuring Firewall"
    
    if ! command -v ufw >/dev/null 2>&1; then
        print_warning "UFW not installed. Installing..."
        apt install -y -qq ufw
    fi
    
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1
    
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow OpenSSH
    ufw allow 9000/tcp  # MinIO S3 API
    ufw allow 9001/tcp  # MinIO Console
    ufw allow 9100/tcp  # Node Exporter
    ufw allow 8080/tcp  # cAdvisor
    
    ufw --force enable
    
    print_success "Firewall configured"
    print_info "Open ports: 9000 (S3), 9001 (Console), 9100 (Node Exporter), 8080 (cAdvisor)"
}

setup_backup_cron() {
    print_header "Setting Up Automatic Backup"
    
    if [ -f "$SCRIPT_DIR/backup_minio.sh" ]; then
        chmod +x "$SCRIPT_DIR/backup_minio.sh"
        
        # Remove existing jobs
        crontab -l 2>/dev/null | grep -v "backup_minio.sh" | crontab - 2>/dev/null || true
        
        # Add new jobs (4AM and 4PM UTC)
        (crontab -l 2>/dev/null; cat << CRON_EOF
# MinIO Backup Cron Jobs
0 4 * * * $SCRIPT_DIR/backup_minio.sh --auto >> /var/log/minio_backup.log 2>&1
0 16 * * * $SCRIPT_DIR/backup_minio.sh --auto >> /var/log/minio_backup.log 2>&1
CRON_EOF
        ) | crontab -
        
        print_success "Cron jobs configured: 4:00 AM and 4:00 PM UTC"
    else
        print_warning "backup_minio.sh file not found. Automatic backup not configured."
    fi
}

# =============================================================================
# Post-Installation Guide
# =============================================================================

show_service_accounts() {
    print_header "🔑 Service Account Information"
    
    source "$SCRIPT_DIR/.env"
    
    echo ""
    echo -e "${BOLD}Three Service Accounts created with separate access:${NC}"
    echo ""
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}1️⃣  Ingest System (access to: ingest-system)${NC}"
    echo -e "   AWS_ACCESS_KEY_ID=${GREEN}${INGEST_ACCESS_KEY}${NC}"
    echo -e "   AWS_SECRET_ACCESS_KEY=${GREEN}${INGEST_SECRET_KEY}${NC}"
    echo -e "   AWS_STORAGE_BUCKET_NAME=${GREEN}${BUCKET_INGEST}${NC}"
    echo -e "   AWS_S3_ENDPOINT_URL=${GREEN}http://${DMZ_IP}:9000${NC}"
    echo ""
    echo -e "${CYAN}2️⃣  Central System (access to: temp-userfile, users-system)${NC}"
    echo -e "   AWS_ACCESS_KEY_ID=${GREEN}${CENTRAL_ACCESS_KEY}${NC}"
    echo -e "   AWS_SECRET_ACCESS_KEY=${GREEN}${CENTRAL_SECRET_KEY}${NC}"
    echo -e "   AWS_S3_ENDPOINT_URL=${GREEN}http://${DMZ_IP}:9000${NC}"
    echo ""
    echo -e "${CYAN}3️⃣  Users System (access to: temp-userfile, users-system)${NC}"
    echo -e "   AWS_ACCESS_KEY_ID=${GREEN}${USERS_ACCESS_KEY}${NC}"
    echo -e "   AWS_SECRET_ACCESS_KEY=${GREEN}${USERS_SECRET_KEY}${NC}"
    echo -e "   AWS_S3_ENDPOINT_URL=${GREEN}http://${DMZ_IP}:9000${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

show_credentials() {
    print_header "🔐 Root Access Credentials"
    
    source "$SCRIPT_DIR/.env"
    
    echo ""
    echo -e "${BOLD}MinIO Root Credentials (Console Admin):${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${CYAN}Username:${NC}  ${GREEN}minioadmin${NC}"
    echo -e "  ${CYAN}Password:${NC}  ${GREEN}${MINIO_ROOT_PASSWORD}${NC}"
    echo ""
    echo -e "  ${CYAN}Console:${NC}   ${GREEN}http://${DMZ_IP}:9001${NC}"
    echo -e "  ${CYAN}S3 API:${NC}    ${GREEN}http://${DMZ_IP}:9000${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Save to file
    cat > "$SCRIPT_DIR/CREDENTIALS.txt" << EOF
# MinIO Server Credentials
# Generated: $(date)
# ⚠️ Save this file in a secure location and then delete it!

MinIO Root (Console Admin):
  Username: minioadmin
  Password: ${MINIO_ROOT_PASSWORD}

Buckets:
  - ingest-system
  - temp-userfile
  - users-system

Service Accounts:

1. Ingest System (access: ingest-system):
   Access Key: ${INGEST_ACCESS_KEY}
   Secret Key: ${INGEST_SECRET_KEY}

2. Central System (access: temp-userfile, users-system):
   Access Key: ${CENTRAL_ACCESS_KEY}
   Secret Key: ${CENTRAL_SECRET_KEY}

3. Users System (access: temp-userfile, users-system):
   Access Key: ${USERS_ACCESS_KEY}
   Secret Key: ${USERS_SECRET_KEY}

Addresses:
  S3 API: http://${DMZ_IP}:9000
  Console: http://${DMZ_IP}:9001

Cache Server Configuration:
  Using Cache: ${USE_CACHE_SERVER}
  Cache IP: ${CACHE_SERVER_IP}
EOF
    chmod 600 "$SCRIPT_DIR/CREDENTIALS.txt"
    print_warning "Credentials saved to CREDENTIALS.txt. Keep it in a secure location!"
}

show_useful_commands() {
    print_header "🔧 Useful Commands"
    
    echo ""
    echo -e "${BOLD}Service Management:${NC}"
    echo -e "  ${CYAN}docker compose ps${NC}                    # Service status"
    echo -e "  ${CYAN}docker compose logs -f minio${NC}         # MinIO logs"
    echo -e "  ${CYAN}docker compose restart minio${NC}         # Restart MinIO"
    echo -e "  ${CYAN}docker compose down${NC}                  # Stop all"
    echo -e "  ${CYAN}docker compose up -d${NC}                 # Start all"
    echo ""
    echo -e "${BOLD}Backup:${NC}"
    echo -e "  ${CYAN}./backup_minio.sh backup${NC}             # Manual backup"
    echo -e "  ${CYAN}./backup_minio.sh list${NC}               # List backups"
    echo -e "  ${CYAN}./backup_minio.sh restore <file>${NC}     # Restore"
    echo ""
    
    if [ "$USE_CACHE_SERVER" = "yes" ]; then
        echo -e "${BOLD}Cache Server:${NC}"
        echo -e "  ${CYAN}Cache IP:${NC} ${GREEN}${CACHE_SERVER_IP}${NC}"
        echo -e "  ${CYAN}Status:${NC} http://${CACHE_SERVER_IP}/"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    clear
    print_header "🗄️  MinIO Installation (Internal Server)"
    
    echo ""
    echo "This script installs and configures a standalone MinIO server for internal network."
    echo ""
    echo "The following will be installed and configured:"
    echo "  • Docker and Docker Compose"
    echo "  • MinIO (Object Storage)"
    echo "  • Monitoring Stack (Node Exporter, cAdvisor, Promtail)"
    echo "  • Buckets and Service Accounts"
    echo "  • Automatic Backup"
    echo ""
    read -p "Do you want to continue? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Pre-flight
    check_root
    
    # Ask about cache server FIRST
    ask_cache_server
    
    check_system
    
    # Install
    install_docker
    
    # Configure
    configure_env
    
    # Deploy
    deploy_services
    configure_firewall
    setup_backup_cron
    
    # Post-installation
    echo ""
    echo ""
    print_header "✅ Installation Completed Successfully!"
    
    show_credentials
    show_service_accounts
    show_useful_commands
    
    echo ""
    print_success "🎉 MinIO Server is ready to use!"
    echo ""
    print_warning "Next Steps:"
    echo "  1. Add Service Account credentials to .env files of respective systems"
    echo "  2. Restart the respective services"
    echo ""
}

main "$@"
