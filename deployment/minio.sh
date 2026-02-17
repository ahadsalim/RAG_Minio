#!/bin/bash

# =============================================================================
# MinIO Installation Script for Internal Standalone Server
# =============================================================================
# This script sets up MinIO object storage on a dedicated internal server.
# No SSL/NPM needed — accessed via internal IP only.
# Run with: sudo bash minio.sh
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
# Pre-flight Checks
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "این اسکریپت باید با دسترسی root اجرا شود"
        echo "لطفاً با sudo اجرا کنید: sudo bash $0"
        exit 1
    fi
}

check_system() {
    print_header "بررسی پیش‌نیازها"
    
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$ram_gb" -lt 2 ]; then
        print_warning "RAM کمتر از 2GB است. حداقل 4GB توصیه می‌شود."
    else
        print_success "RAM: ${ram_gb}GB"
    fi
    
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$disk_gb" -lt 20 ]; then
        print_error "فضای دیسک کافی نیست. حداقل 20GB نیاز است."
        exit 1
    else
        print_success "فضای دیسک آزاد: ${disk_gb}GB"
    fi
    
    for port in 9000 9001; do
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            print_warning "پورت $port در حال استفاده است"
        fi
    done
}

# =============================================================================
# Installation
# =============================================================================

install_docker() {
    print_header "نصب Docker"
    
    if command -v docker &> /dev/null; then
        print_info "Docker قبلاً نصب شده است"
        docker --version
    else
        print_step "نصب Docker..."
        
        apt update -qq
        apt install -y -qq curl ca-certificates gnupg lsb-release
        
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt update -qq
        apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl enable docker
        systemctl start docker
        
        print_success "Docker نصب شد"
    fi
}

# =============================================================================
# Configuration
# =============================================================================

configure_env() {
    print_header "تنظیمات MinIO"
    
    local env_file="$SCRIPT_DIR/.env"
    
    # Check if .env already has real values
    if [ -f "$env_file" ] && ! grep -q "CHANGE_ME" "$env_file"; then
        print_info "فایل .env قبلاً تنظیم شده است"
        source "$env_file"
        return
    fi
    
    # Auto-generate root password
    ROOT_PASS=$(generate_password 32)
    
    # Hardcoded service account (same as ingest server)
    SA_ACCESS="gxMvuQSlEu4QJbk2RUI7"
    SA_SECRET="FyUiX289RLCKE4YLoWgRCLiJecG6x5jprPWycXNd"
    
    # Hardcoded bucket name
    BUCKET="ingest-system"
    
    # Only ask for IPs
    echo ""
    read -p "IP داخلی (LAN) این سرور [192.168.100.105]: " LAN_IP
    LAN_IP=${LAN_IP:-192.168.100.105}
    
    read -p "IP منطقه DMZ این سرور [10.10.10.50]: " DMZ_IP
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

# Bucket name for ingest system
BUCKET_NAME=${BUCKET}

# Service Account for ingest application (will be created by minio-init)
# These are the credentials that the ingest server will use to connect
SERVICE_ACCESS_KEY=${SA_ACCESS}
SERVICE_SECRET_KEY=${SA_SECRET}
EOF
    
    chmod 600 "$env_file"
    
    # Source the new env
    source "$env_file"
    
    print_success "فایل تنظیمات ایجاد شد"
}

# =============================================================================
# Deploy
# =============================================================================

deploy_services() {
    print_header "اجرای سرویس‌ها"
    
    cd "$SCRIPT_DIR"
    
    print_step "اجرای MinIO..."
    docker compose up -d
    
    print_step "انتظار برای آماده شدن MinIO..."
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
        print_error "MinIO آماده نشد. لاگ‌ها را بررسی کنید: docker compose logs minio"
        exit 1
    fi
    
    print_success "MinIO آماده است"
    
    # Wait for minio-init to complete
    print_step "اجرای minio-init (ساخت bucket و service account)..."
    sleep 10
    docker compose logs minio-init 2>/dev/null || true
    
    print_success "سرویس‌ها اجرا شدند"
}

configure_firewall() {
    print_header "تنظیم فایروال"
    
    if ! command -v ufw >/dev/null 2>&1; then
        print_warning "UFW نصب نیست. نصب می‌شود..."
        apt install -y -qq ufw
    fi
    
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1
    
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow OpenSSH
    ufw allow 9000/tcp  # MinIO S3 API
    ufw allow 9001/tcp  # MinIO Console
    
    ufw --force enable
    
    print_success "فایروال تنظیم شد"
    print_info "پورت‌های 9000 (S3 API) و 9001 (Console) باز هستند"
}

setup_backup_cron() {
    print_header "تنظیم Backup خودکار"
    
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
        
        print_success "Cron Jobs تنظیم شد: 4:00 AM و 4:00 PM UTC"
    else
        print_warning "فایل backup_minio.sh یافت نشد. Backup خودکار تنظیم نشد."
    fi
}

# =============================================================================
# Post-Installation Guide
# =============================================================================


show_ingest_config() {
    print_header "🔗 تنظیمات اتصال سرور Ingest"
    
    source "$SCRIPT_DIR/.env"
    
    echo ""
    echo -e "${BOLD}این مقادیر را در فایل .env سرور Ingest وارد کنید:${NC}"
    echo ""
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}# MinIO Storage (Internal Server)"
    echo -e "AWS_ACCESS_KEY_ID=${GREEN}${SERVICE_ACCESS_KEY}${NC}"
    echo -e "${CYAN}AWS_SECRET_ACCESS_KEY=${GREEN}${SERVICE_SECRET_KEY}${NC}"
    echo -e "${CYAN}AWS_STORAGE_BUCKET_NAME=${GREEN}${BUCKET_NAME}${NC}"
    echo -e "${CYAN}AWS_S3_ENDPOINT_URL=${GREEN}http://${DMZ_IP}:9000${NC}"
    echo -e "${CYAN}AWS_S3_REGION_NAME=${GREEN}us-east-1${NC}"
    echo -e "${CYAN}AWS_S3_USE_SSL=${GREEN}false${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${BOLD}⚠️  بعد از تنظیم .env در سرور Ingest:${NC}"
    echo -e "   ${CYAN}cd /srv && sudo docker compose -f deployment/docker-compose.ingest.yml up -d web worker beat${NC}"
    echo ""
}

show_credentials() {
    print_header "🔐 اطلاعات دسترسی"
    
    source "$SCRIPT_DIR/.env"
    
    echo ""
    echo -e "${BOLD}اطلاعات زیر را در جای امن ذخیره کنید:${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${CYAN}MinIO Root:${NC}"
    echo -e "    User:     ${GREEN}minioadmin${NC}"
    echo -e "    Password: ${GREEN}${MINIO_ROOT_PASSWORD}${NC}"
    echo ""
    echo -e "  ${CYAN}Service Account (for Ingest):${NC}"
    echo -e "    Access Key: ${GREEN}${SERVICE_ACCESS_KEY}${NC}"
    echo -e "    Secret Key: ${GREEN}${SERVICE_SECRET_KEY}${NC}"
    echo ""
    echo -e "  ${CYAN}Addresses:${NC}"
    echo -e "    S3 API:   ${GREEN}http://${DMZ_IP}:9000${NC}"
    echo -e "    Console:  ${GREEN}http://${DMZ_IP}:9001${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Save to file
    cat > "$SCRIPT_DIR/CREDENTIALS.txt" << EOF
# MinIO Server Credentials
# Generated: $(date)
# ⚠️ این فایل را در جای امن ذخیره کنید و سپس حذف کنید!

MinIO Root:
  User: minioadmin
  Password: ${MINIO_ROOT_PASSWORD}

Service Account (for Ingest server):
  Access Key: ${SERVICE_ACCESS_KEY}
  Secret Key: ${SERVICE_SECRET_KEY}

Addresses:
  S3 API: http://${DMZ_IP}:9000
  Console: http://${DMZ_IP}:9001

Bucket: ${BUCKET_NAME}
EOF
    chmod 600 "$SCRIPT_DIR/CREDENTIALS.txt"
    print_warning "اطلاعات در فایل CREDENTIALS.txt ذخیره شد. آن را در جای امن نگه دارید!"
}

show_useful_commands() {
    print_header "🔧 دستورات مفید"
    
    echo ""
    echo -e "${BOLD}مدیریت سرویس‌ها:${NC}"
    echo -e "  ${CYAN}docker compose ps${NC}                    # وضعیت سرویس‌ها"
    echo -e "  ${CYAN}docker compose logs -f minio${NC}         # لاگ MinIO"
    echo -e "  ${CYAN}docker compose restart minio${NC}         # ریستارت MinIO"
    echo -e "  ${CYAN}docker compose down${NC}                  # توقف همه"
    echo -e "  ${CYAN}docker compose up -d${NC}                 # اجرای همه"
    echo ""
    echo -e "${BOLD}Backup:${NC}"
    echo -e "  ${CYAN}./backup_minio.sh backup${NC}             # بکاپ دستی"
    echo -e "  ${CYAN}./backup_minio.sh list${NC}               # لیست بکاپ‌ها"
    echo -e "  ${CYAN}./backup_minio.sh restore <file>${NC}     # ریستور"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    clear
    print_header "🗄️  نصب MinIO (سرور داخلی)"
    
    echo ""
    echo "این اسکریپت سرور MinIO مستقل را برای شبکه داخلی نصب و تنظیم می‌کند."
    echo ""
    echo "موارد زیر نصب و تنظیم می‌شوند:"
    echo "  • Docker و Docker Compose"
    echo "  • MinIO (Object Storage)"
    echo "  • Bucket و Service Account"
    echo "  • Backup خودکار"
    echo ""
    read -p "آیا ادامه می‌دهید؟ (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "عملیات لغو شد."
        exit 0
    fi
    
    # Pre-flight
    check_root
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
    print_header "✅ نصب با موفقیت انجام شد!"
    
    show_credentials
    show_ingest_config
    show_useful_commands
    
    echo ""
    print_success "🎉 سرور MinIO آماده استفاده است!"
    echo ""
    print_warning "مراحل بعدی:"
    echo "  1. مقادیر اتصال را در .env سرور Ingest وارد کنید"
    echo "  2. سرویس‌های Ingest را restart کنید"
    echo ""
}

main "$@"
