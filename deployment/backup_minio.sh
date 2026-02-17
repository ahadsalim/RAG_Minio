#!/bin/bash

# =============================================================================
# MinIO Backup & Restore Script (Standalone Server)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Load env
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Configuration
LOCAL_BACKUP_DIR="/opt/backups/minio"
LOG_FILE="/var/log/minio_backup.log"
EXCLUDED_BUCKETS="temp-userfile"

# Remote backup settings (optional)
BACKUP_SERVER_HOST="${BACKUP_SERVER_HOST:-}"
BACKUP_SERVER_USER="${BACKUP_SERVER_USER:-root}"
BACKUP_SERVER_PATH_MINIO="${BACKUP_SERVER_PATH_MINIO:-/srv/backup/minio}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-/root/.ssh/backup_key}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Get MinIO volume name
get_minio_volume() {
    local volume=$(docker volume ls --format "{{.Name}}" | grep -E "minio.+minio_data$" | head -1)
    if [ -z "$volume" ]; then
        volume="minio-server_minio_data"
    fi
    echo "$volume"
}

# =============================================================================
# BACKUP
# =============================================================================

create_backup() {
    local date=$(date +%Y%m%d_%H%M%S)
    local backup_name="minio_backup_${date}.tar.gz"
    local backup_path="$LOCAL_BACKUP_DIR/$backup_name"
    
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    print_info "Creating MinIO backup..." >&2
    print_info "Excluding buckets: $EXCLUDED_BUCKETS" >&2
    
    local volume=$(get_minio_volume)
    print_info "Using volume: $volume" >&2
    
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        print_error "MinIO volume not found: $volume" >&2
        return 1
    fi
    
    # Build exclude arguments
    local exclude_args=""
    for bucket in $EXCLUDED_BUCKETS; do
        exclude_args="$exclude_args --exclude=data/$bucket --exclude=data/.minio.sys/buckets/$bucket"
    done
    
    if docker run --rm \
        -v "$volume:/data:ro" \
        -v "$LOCAL_BACKUP_DIR:/backup" \
        alpine tar -czf "/backup/$backup_name" $exclude_args /data 2>/dev/null; then
        
        sha256sum "$backup_path" > "${backup_path}.sha256"
        local size=$(du -sh "$backup_path" | cut -f1)
        print_success "Backup created: $backup_path ($size)" >&2
        echo "$backup_path"
        return 0
    else
        print_error "Backup failed" >&2
        rm -f "$backup_path"
        return 1
    fi
}

send_to_remote() {
    local backup_file="$1"
    
    if [ -z "$BACKUP_SERVER_HOST" ] || [ ! -f "$BACKUP_SSH_KEY" ]; then
        print_warning "Remote backup not configured (set BACKUP_SERVER_HOST and BACKUP_SSH_KEY)"
        return 1
    fi
    
    ssh -i "$BACKUP_SSH_KEY" "$BACKUP_SERVER_USER@$BACKUP_SERVER_HOST" \
        "mkdir -p $BACKUP_SERVER_PATH_MINIO"
    
    if scp -i "$BACKUP_SSH_KEY" "$backup_file" "${backup_file}.sha256" \
        "$BACKUP_SERVER_USER@$BACKUP_SERVER_HOST:$BACKUP_SERVER_PATH_MINIO/"; then
        print_success "Backup sent to $BACKUP_SERVER_HOST:$BACKUP_SERVER_PATH_MINIO/"
        return 0
    else
        print_error "Failed to send backup to remote server"
        return 1
    fi
}

cleanup_old() {
    local days=${1:-$BACKUP_RETENTION_DAYS}
    
    local count=$(find "$LOCAL_BACKUP_DIR" -name "minio_backup_*.tar.gz" -mtime +$days 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$LOCAL_BACKUP_DIR" -name "minio_backup_*.tar.gz*" -mtime +$days -delete
        print_info "Deleted $count old local backup(s)"
    fi
    
    if [ -n "$BACKUP_SERVER_HOST" ] && [ -f "$BACKUP_SSH_KEY" ]; then
        ssh -i "$BACKUP_SSH_KEY" "$BACKUP_SERVER_USER@$BACKUP_SERVER_HOST" \
            "find $BACKUP_SERVER_PATH_MINIO -name 'minio_backup_*.tar.gz*' -mtime +$days -delete 2>/dev/null || true"
    fi
}

# =============================================================================
# RESTORE
# =============================================================================

restore_backup() {
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi
    
    print_warning "This will REPLACE all MinIO data!"
    read -p "Continue? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        return 0
    fi
    
    local volume=$(get_minio_volume)
    
    print_info "Stopping MinIO..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" stop minio 2>/dev/null || true
    sleep 3
    
    print_info "Restoring from: $backup_file"
    if docker run --rm \
        -v "$volume:/data" \
        -v "$(dirname "$backup_file"):/backup:ro" \
        alpine sh -c "rm -rf /data/* && tar -xzf /backup/$(basename "$backup_file") -C / --strip-components=0"; then
        print_success "Data restored"
    else
        print_error "Restore failed"
    fi
    
    print_info "Starting MinIO..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" start minio
    sleep 5
    
    if docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T minio curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
        print_success "MinIO is healthy"
    else
        print_warning "MinIO health check failed - please verify manually"
    fi
    
    print_success "Restore completed"
}

# =============================================================================
# AUTO BACKUP (called by cron)
# =============================================================================

auto_backup() {
    log "INFO" "========== Starting MinIO Auto Backup =========="
    
    local backup_file=$(create_backup)
    if [ $? -ne 0 ]; then
        log "ERROR" "Backup creation failed"
        return 1
    fi
    
    log "INFO" "Backup created: $backup_file"
    
    if [ -n "$BACKUP_SERVER_HOST" ] && [ -f "$BACKUP_SSH_KEY" ]; then
        send_to_remote "$backup_file"
    fi
    
    cleanup_old
    
    log "INFO" "========== MinIO Auto Backup Completed =========="
}

# =============================================================================
# STATUS & LIST
# =============================================================================

show_status() {
    echo -e "${BOLD}📊 MinIO Backup Status${NC}"
    echo ""
    
    local volume=$(get_minio_volume)
    echo "  Volume: $volume"
    echo "  Backup Dir: $LOCAL_BACKUP_DIR"
    echo "  Remote: ${BACKUP_SERVER_HOST:-Not configured}"
    
    if docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T minio curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then
        echo -e "  MinIO: ${GREEN}Healthy${NC}"
    else
        echo -e "  MinIO: ${RED}Not running${NC}"
    fi
    
    local count=$(ls -1 "$LOCAL_BACKUP_DIR"/minio_backup_*.tar.gz 2>/dev/null | wc -l)
    echo "  Local Backups: $count"
    echo ""
}

list_backups() {
    echo -e "${BOLD}📋 MinIO Backups${NC}"
    echo ""
    echo "Local ($LOCAL_BACKUP_DIR):"
    if ls "$LOCAL_BACKUP_DIR"/minio_backup_*.tar.gz >/dev/null 2>&1; then
        ls -lh "$LOCAL_BACKUP_DIR"/minio_backup_*.tar.gz | awk '{print "  " $9 " (" $5 ")"}'
    else
        echo "  None"
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

show_help() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  backup              Create local backup"
    echo "  backup --remote     Create backup and send to remote"
    echo "  restore <file>      Restore from backup file"
    echo "  list                List all backups"
    echo "  status              Show backup status"
    echo "  --auto              Auto backup (for cron)"
    echo "  --help              Show this help"
}

case "${1:-}" in
    backup)
        if [ "${2:-}" = "--remote" ]; then
            backup_file=$(create_backup)
            [ $? -eq 0 ] && send_to_remote "$backup_file"
        else
            create_backup
        fi
        ;;
    restore)
        restore_backup "$2"
        ;;
    list)
        list_backups
        ;;
    status)
        show_status
        ;;
    --auto)
        auto_backup
        ;;
    --help|-h|help)
        show_help
        ;;
    *)
        show_help
        ;;
esac
