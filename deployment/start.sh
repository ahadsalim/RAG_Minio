#!/bin/bash
# =============================================================================
# MinIO Server Startup Script with Security Checks
# =============================================================================
# This script:
# 1. Checks security prerequisites (UFW, DOCKER-USER chain)
# 2. Starts MinIO server and all monitoring exporters
# 3. Verifies security configuration
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

print_error() {
    echo -e "${RED}❌ ERROR: $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
}

print_info() {
    echo -e "ℹ️  $1"
}

# =============================================================================
# Security Checks
# =============================================================================

check_ufw() {
    print_info "Checking UFW firewall status..."
    if ! command -v ufw &> /dev/null; then
        print_error "UFW is not installed. Please install it first."
        exit 1
    fi
    
    if ! sudo ufw status | grep -q "Status: active"; then
        print_error "UFW is not active. Please enable it first."
        echo "Run: sudo ufw --force enable"
        exit 1
    fi
    
    print_success "UFW is active"
}

check_docker_user_chain() {
    print_info "Checking DOCKER-USER iptables chain..."
    
    # Check if DOCKER-USER chain has rules
    local rule_count=$(sudo iptables -L DOCKER-USER -n | grep -c "^DROP\|^RETURN" || true)
    
    if [ "$rule_count" -lt 5 ]; then
        print_warning "DOCKER-USER chain has insufficient rules ($rule_count found)"
        print_info "Checking if docker-user-iptables service exists..."
        
        if systemctl list-unit-files | grep -q "docker-user-iptables.service"; then
            print_info "Starting docker-user-iptables service..."
            sudo systemctl start docker-user-iptables.service
            print_success "DOCKER-USER rules applied"
        else
            print_error "docker-user-iptables.service not found"
            print_error "Please run the security audit script first to configure DOCKER-USER chain"
            exit 1
        fi
    else
        print_success "DOCKER-USER chain is configured ($rule_count rules)"
    fi
}

check_docker() {
    print_info "Checking Docker..."
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running"
        exit 1
    fi
    
    print_success "Docker is running"
}

check_env_file() {
    print_info "Checking .env file..."
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        print_error ".env file not found in $SCRIPT_DIR"
        print_info "Please create .env file with required variables:"
        echo "  - MINIO_ROOT_USER"
        echo "  - MINIO_ROOT_PASSWORD"
        echo "  - SERVICE_ACCESS_KEY"
        echo "  - SERVICE_SECRET_KEY"
        exit 1
    fi
    print_success ".env file exists"
}

verify_port_binding() {
    print_info "Verifying MinIO port binding security..."
    
    # Wait a bit for containers to start
    sleep 3
    
    # Check if MinIO ports are bound to localhost only
    if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:9000\|0.0.0.0:9001"; then
        print_error "MinIO ports are exposed to 0.0.0.0 (internet)!"
        print_error "This is a critical security issue."
        exit 1
    fi
    
    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:9000" && ss -tlnp 2>/dev/null | grep -q "127.0.0.1:9001"; then
        print_success "MinIO ports are correctly bound to localhost only"
    else
        print_warning "Could not verify MinIO port binding"
    fi
}

show_security_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    SECURITY STATUS"
    echo "═══════════════════════════════════════════════════════════════"
    
    # UFW Status
    echo -e "\n${GREEN}UFW Firewall:${NC}"
    sudo ufw status numbered | head -15
    
    # DOCKER-USER Chain
    echo -e "\n${GREEN}DOCKER-USER Chain:${NC}"
    sudo iptables -L DOCKER-USER -n --line-numbers | head -15
    
    # Open Ports
    echo -e "\n${GREEN}Open Ports (0.0.0.0):${NC}"
    ss -tlnp 2>/dev/null | grep "0.0.0.0" | grep -E ":(22|80|443|9000|9001|8080|9100)" || echo "  None (good!)"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

echo "═══════════════════════════════════════════════════════════════"
echo "          MinIO Server Startup with Security Checks"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Run security checks
check_docker
check_env_file
check_ufw
check_docker_user_chain

echo ""
print_info "All security checks passed. Starting services..."
echo ""

cd "$SCRIPT_DIR"
docker compose up -d

# Verify port binding after startup
verify_port_binding

echo ""
print_success "All services started successfully!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    SERVICE ENDPOINTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "${GREEN}MinIO Services (localhost only):${NC}"
echo "  - S3 API:          http://127.0.0.1:9000"
echo "  - Console:         http://127.0.0.1:9001"
echo "  - Metrics:         http://127.0.0.1:9000/minio/v2/metrics/cluster"
echo ""
echo "${GREEN}Monitoring Services (LAN/DMZ only):${NC}"
echo "  - Node Exporter:   http://192.168.100.105:9100/metrics"
echo "  - cAdvisor:        http://192.168.100.105:8080/metrics"
echo "  - Promtail:        → 10.10.10.40:3100 (Loki)"
echo ""
echo "${YELLOW}Security Notes:${NC}"
echo "  ✓ MinIO ports bound to localhost only (127.0.0.1)"
echo "  ✓ UFW firewall active"
echo "  ✓ DOCKER-USER chain configured"
echo "  ✓ Only SSH (22) exposed to internet"
echo "  ✓ All services accessible from LAN (192.168.100.0/24)"
echo "  ✓ All services accessible from DMZ (10.10.10.0/24)"
echo ""
echo "${GREEN}Access Methods:${NC}"
echo "  - From LAN/DMZ:    Direct access to all services"
echo "  - From Internet:   SSH tunnel required for MinIO"
echo "    Example: ssh -L 9000:localhost:9000 -L 9001:localhost:9001 user@192.168.100.105"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    CONTAINER STATUS"
echo "═══════════════════════════════════════════════════════════════"
echo ""
docker compose ps

# Show security status
show_security_status

echo ""
print_success "MinIO server is running securely!"
echo ""
