# MinIO Server - AI Memory

## Server Information
- **Server Name**: minio
- **Primary IP**: 10.10.10.50 (ens20)
- **Secondary IP**: 192.168.100.105 (ens18)
- **Installation Date**: 2026-02-17

## Architecture
Single unified `docker-compose.yml` manages all services (MinIO + Monitoring stack).

## Deployed Services

### MinIO
- **Ports**: 9000 (S3 API), 9001 (Console)
- **Image**: minio/minio:latest
- **Network**: deployment_minio_net (bridge)
- **Volume**: deployment_minio_data
- **Metrics**: http://10.10.10.50:9000/minio/v2/metrics/cluster (requires auth)

### Monitoring Exporters (all use network_mode: host)
1. **Node Exporter** (port 9100) - System metrics
2. **cAdvisor** (port 8080) - Container metrics (zcube/cadvisor for cgroup v2)
3. **Promtail** - Logs to Loki at 10.10.10.40:3100 (label: server=minio)

## Key Files
- `/srv/deployment/docker-compose.yml` - Unified config for all services
- `/srv/deployment/promtail-config.yml` - Promtail configuration
- `/srv/deployment/start.sh` - Startup script
- `/srv/deployment/minio-init.sh` - MinIO initialization
- `/srv/.env` - Environment variables

## Management Commands
```bash
cd /srv/deployment
docker compose up -d          # Start all
docker compose down           # Stop all
docker compose restart <svc>  # Restart specific service
docker compose ps             # Status
```

## Prometheus Scrape Configs
```yaml
- job_name: 'node-exporter-minio'
  static_configs:
    - targets: ['10.10.10.50:9100']
      labels: {server: minio, hostname: minio}

- job_name: 'cadvisor-minio'
  static_configs:
    - targets: ['10.10.10.50:8080']
      labels: {server: minio}

- job_name: 'minio-cluster'
  metrics_path: '/minio/v2/metrics/cluster'
  static_configs:
    - targets: ['10.10.10.50:9000']
      labels: {server: minio-dedicated}
```

## Important Notes
- cAdvisor: Use zcube/cadvisor (not google/cadvisor) for cgroup v2 compatibility
- All exporters use network_mode: host for direct system access
- Container names: deployment-minio-1, node-exporter, cadvisor, promtail
- Promtail adds server=minio label to all logs
