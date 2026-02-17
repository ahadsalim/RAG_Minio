#!/bin/bash
# =============================================================================
# Security Status Check Script
# =============================================================================
# This script displays the current security configuration of the MinIO server
# without starting or stopping any services.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
}

print_section() {
    echo -e "\n${BLUE}▶ $1${NC}"
    echo "───────────────────────────────────────────────────────────────"
}

print_check() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

print_header "MinIO Server Security Status"

# =============================================================================
# 1. UFW Firewall Status
# =============================================================================
print_section "UFW Firewall"

if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "Status: active"; then
        print_check 0 "UFW is active"
        echo ""
        sudo ufw status numbered | head -20
    else
        print_check 1 "UFW is NOT active"
    fi
else
    print_check 1 "UFW is not installed"
fi

# =============================================================================
# 2. DOCKER-USER iptables Chain
# =============================================================================
print_section "DOCKER-USER iptables Chain"

rule_count=$(sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -c "^DROP\|^RETURN" || echo "0")

if [ "$rule_count" -ge 5 ]; then
    print_check 0 "DOCKER-USER chain is configured ($rule_count rules)"
    echo ""
    sudo iptables -L DOCKER-USER -n --line-numbers | head -15
else
    print_check 1 "DOCKER-USER chain has insufficient rules ($rule_count found)"
    echo "  Expected: At least 5 rules (RETURN for trusted networks + DROP)"
fi

# =============================================================================
# 3. docker-user-iptables Service
# =============================================================================
print_section "docker-user-iptables Service"

if systemctl list-unit-files | grep -q "docker-user-iptables.service"; then
    if systemctl is-active --quiet docker-user-iptables.service; then
        print_check 0 "Service is active"
    else
        print_check 1 "Service exists but is not active"
    fi
    
    if systemctl is-enabled --quiet docker-user-iptables.service; then
        print_check 0 "Service is enabled (will start on boot)"
    else
        print_check 1 "Service is not enabled"
    fi
else
    print_check 1 "Service not found"
fi

# =============================================================================
# 4. Port Binding Security
# =============================================================================
print_section "Port Binding Security"

echo ""
echo "Ports listening on 0.0.0.0 (exposed to internet):"
exposed_ports=$(ss -tlnp 2>/dev/null | grep "0.0.0.0" | grep -E ":(9000|9001|8080|9100)" || true)

if [ -z "$exposed_ports" ]; then
    print_check 0 "No sensitive ports exposed to 0.0.0.0"
else
    print_check 1 "WARNING: Sensitive ports exposed to internet!"
    echo "$exposed_ports"
fi

echo ""
echo "MinIO ports on localhost (127.0.0.1):"
localhost_ports=$(ss -tlnp 2>/dev/null | grep "127.0.0.1" | grep -E ":(9000|9001)" || echo "  None found")
echo "$localhost_ports"

# =============================================================================
# 5. Docker Containers Status
# =============================================================================
print_section "Docker Containers"

if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        print_check 0 "Docker is running"
        echo ""
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "minio|cadvisor|node-exporter|promtail|NAMES"
    else
        print_check 1 "Docker daemon is not running"
    fi
else
    print_check 1 "Docker is not installed"
fi

# =============================================================================
# 6. Network Interfaces
# =============================================================================
print_section "Network Interfaces"

echo ""
ip -br addr show | grep -E "ens|eth|lo" | while read -r line; do
    echo "  $line"
done

# =============================================================================
# 7. Open Ports Summary
# =============================================================================
print_section "All Listening Ports"

echo ""
echo "Port  | Interface      | Service"
echo "------|----------------|------------------"
ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4}' | sort -u | while read -r addr; do
    port=$(echo "$addr" | awk -F: '{print $NF}')
    ip=$(echo "$addr" | sed 's/:[^:]*$//')
    
    # Only show relevant ports
    if echo "$port" | grep -qE "^(22|80|443|9000|9001|8080|9100|3100)$"; then
        service=""
        case $port in
            22) service="SSH" ;;
            80) service="HTTP" ;;
            443) service="HTTPS" ;;
            9000) service="MinIO S3 API" ;;
            9001) service="MinIO Console" ;;
            8080) service="cAdvisor" ;;
            9100) service="Node Exporter" ;;
            3100) service="Loki" ;;
        esac
        printf "%-6s| %-14s | %s\n" "$port" "$ip" "$service"
    fi
done

# =============================================================================
# 8. Security Recommendations
# =============================================================================
print_section "Security Recommendations"

echo ""

# Check UFW
if ! command -v ufw &> /dev/null || ! sudo ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}⚠${NC}  Enable UFW firewall: sudo ufw --force enable"
fi

# Check DOCKER-USER
if [ "$rule_count" -lt 5 ]; then
    echo -e "${YELLOW}⚠${NC}  Configure DOCKER-USER chain (see security audit documentation)"
fi

# Check exposed ports
if ss -tlnp 2>/dev/null | grep "0.0.0.0" | grep -qE ":(9000|9001)"; then
    echo -e "${RED}⚠${NC}  CRITICAL: MinIO ports exposed to internet! Bind to 127.0.0.1 only"
fi

# Check service
if ! systemctl is-enabled --quiet docker-user-iptables.service 2>/dev/null; then
    echo -e "${YELLOW}⚠${NC}  Enable docker-user-iptables service: sudo systemctl enable docker-user-iptables.service"
fi

echo ""
print_header "Security Status Check Complete"
echo ""
