# راهنمای اتصال کلاینت‌ها به Cache Server

## آدرس سرور کش

```
CACHE_SERVER_IP=10.10.10.111
```

## پورت‌های سرویس‌ها

| پورت | سرویس | کاربرد |
|------|--------|---------|
| `:5001` | Docker Hub mirror | `docker.io` images |
| `:5002` | ghcr.io mirror | GitHub Container Registry |
| `:5003` | quay.io mirror | Red Hat / Quay images |
| `:5004` | gcr.io mirror | Google Container Registry |
| `:5005` | registry.k8s.io mirror | Kubernetes images |
| `:3141` | PyPI (devpi) | Python packages |
| `:4873` | npm (verdaccio) | Node.js packages |
| `:3142` | apt-cacher-ng | Ubuntu/Debian apt packages |
| `:80` | Status page | وضعیت سرویس‌ها |

---

## ۰. نصب کامل از صفر (سرور بدون اینترنت)

### مرحله ۱ — بلافاصله بعد از نصب Ubuntu، apt را به cache هدایت کنید

```bash
# روی سرور جدید (بدون اینترنت) اجرا کنید:
echo 'Acquire::http::Proxy "http://10.10.10.111:3142";' | sudo tee /etc/apt/apt.conf.d/00proxy
echo 'Acquire::https::Proxy "http://10.10.10.111:3142";' | sudo tee -a /etc/apt/apt.conf.d/00proxy

# تست:
sudo apt-get update
```

### مرحله ۲ — نصب Docker از طریق cache

```bash
# نصب پیش‌نیازها از cache
sudo apt-get install -y ca-certificates curl gnupg

# اضافه کردن Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# اضافه کردن Docker repo
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable docker && sudo systemctl start docker
```

### مرحله ۳ — تنظیم Docker برای استفاده از cache

```bash
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["http://10.10.10.111:5001"],
  "insecure-registries": [
    "10.10.10.111:5001",
    "10.10.10.111:5002",
    "10.10.10.111:5003",
    "10.10.10.111:5004",
    "10.10.10.111:5005"
  ]
}
EOF
sudo systemctl restart docker
```

---

## ۱. تنظیم Docker برای استفاده از کش (هر ماشین کلاینت)

### روش الف: ویرایش `/etc/docker/daemon.json`

فایل `/etc/docker/daemon.json` را با محتوای زیر بسازید یا ویرایش کنید:

```json
{
  "registry-mirrors": [
    "http://<CACHE_SERVER_IP>:5001"
  ],
  "insecure-registries": [
    "<CACHE_SERVER_IP>:5001",
    "<CACHE_SERVER_IP>:5002",
    "<CACHE_SERVER_IP>:5003",
    "<CACHE_SERVER_IP>:5004",
    "<CACHE_SERVER_IP>:5005"
  ]
}
```

سپس Docker را ری‌استارت کنید:

```bash
sudo systemctl restart docker
```

### نکته مهم برای رجیستری‌های غیر Docker Hub

برای ایمیج‌هایی که از `ghcr.io`، `quay.io`، `gcr.io` هستند، باید آدرس رجیستری را در `docker-compose.yml` یا `Dockerfile` تغییر دهید:

| رجیستری اصلی     | آدرس کش                        |
|------------------|--------------------------------|
| `docker.io`      | `<CACHE_SERVER_IP>:5001`       |
| `ghcr.io`        | `<CACHE_SERVER_IP>:5002`       |
| `quay.io`        | `<CACHE_SERVER_IP>:5003`       |
| `gcr.io`         | `<CACHE_SERVER_IP>:5004`       |
| `registry.k8s.io`| `<CACHE_SERVER_IP>:5005`       |

مثال — تبدیل ایمیج در `docker-compose.yml`:
```yaml
# قبل:
image: ghcr.io/someorg/someimage:latest
# بعد:
image: <CACHE_SERVER_IP>:5002/someorg/someimage:latest
```

---

## ۲. تنظیم pip برای استفاده از کش PyPI

### روش الف: فایل `pip.conf` (دائمی)

```bash
mkdir -p ~/.config/pip
cat > ~/.config/pip/pip.conf << EOF
[global]
index-url = http://<CACHE_SERVER_IP>:3141/root/pypi/+simple/
trusted-host = <CACHE_SERVER_IP>
extra-index-url = https://pypi.org/simple/
EOF
```

### روش ب: متغیر محیطی (موقت)

```bash
export PIP_INDEX_URL="http://<CACHE_SERVER_IP>:3141/root/pypi/+simple/"
export PIP_TRUSTED_HOST="<CACHE_SERVER_IP>"
```

### روش ج: در Dockerfile

```dockerfile
RUN pip install --index-url http://<CACHE_SERVER_IP>:3141/root/pypi/+simple/ \
    --trusted-host <CACHE_SERVER_IP> \
    -r requirements.txt
```

### روش د: در docker-compose build args

```yaml
services:
  web:
    build:
      context: .
      args:
        PIP_INDEX_URL: "http://<CACHE_SERVER_IP>:3141/root/pypi/+simple/"
        PIP_TRUSTED_HOST: "<CACHE_SERVER_IP>"
```

---

## ۳. تنظیم npm برای استفاده از کش

```bash
npm config set registry http://<CACHE_SERVER_IP>:4873
```

یا در `package.json`:
```json
{
  "publishConfig": {
    "registry": "http://<CACHE_SERVER_IP>:4873"
  }
}
```

یا در `.npmrc`:
```
registry=http://<CACHE_SERVER_IP>:4873
```

---

## ۴. رفتار هوشمند: اگر چیزی در کش نبود چه می‌شود؟

**همه سرویس‌ها به صورت pull-through کار می‌کنند:**

- اگر ایمیج یا پکیج در کش باشد → **از کش محلی سرو می‌شود** (بدون اینترنت)
- اگر در کش نباشد → **سرور کش خودش از اینترنت دانلود می‌کند** و برای دفعات بعد ذخیره می‌کند

یعنی کلاینت‌ها **هیچ‌وقت مستقیم به اینترنت نمی‌روند** — همه چیز از طریق سرور کش است.

---

## ۵. تست اتصال

```bash
# تست Docker Hub mirror
docker pull <CACHE_SERVER_IP>:5001/library/redis:7-alpine

# تست ghcr.io mirror
docker pull <CACHE_SERVER_IP>:5002/someorg/someimage:tag

# تست PyPI
pip install requests --index-url http://<CACHE_SERVER_IP>:3141/root/pypi/+simple/ --trusted-host <CACHE_SERVER_IP>

# تست npm
npm install --registry http://<CACHE_SERVER_IP>:4873 lodash

# تست صفحه وضعیت
curl http://<CACHE_SERVER_IP>/
```

---

## ۶. بروزرسانی سرور کش

### اضافه کردن ایمیج جدید به کش

روی **سرور کش** اجرا کنید:

```bash
cd /srv/cache
bash scripts/add-image.sh postgres:16-alpine
bash scripts/add-image.sh python:3.12-slim
```

### اضافه کردن پکیج Python جدید

```bash
bash scripts/add-pypi-package.sh "fastapi==0.110.0"
bash scripts/add-pypi-package.sh "torch>=2.2.0"
```

### بروزرسانی کامل (هفتگی)

```bash
bash scripts/update-cache.sh
```

یا با cron (هر یکشنبه ساعت ۳ صبح):

```bash
crontab -e
# اضافه کنید:
0 3 * * 0 /srv/cache/scripts/update-cache.sh >> /var/log/cache-update.log 2>&1
```

---

## ۷. مشاهده وضعیت و فضای مصرفی

```bash
cd /srv/cache

# وضعیت سرویس‌ها
docker compose ps

# لاگ‌ها
docker compose logs -f

# فضای مصرفی هر کش
du -sh data/dockerhub data/ghcr data/quay data/gcr data/k8s data/devpi data/verdaccio
```

---

## ۸. اضافه کردن لیست requirements.txt به کش

اگر یک فایل `requirements.txt` دارید و می‌خواهید همه پکیج‌هایش را از قبل کش کنید:

```bash
# روی سرور کش:
pip download -r /path/to/requirements.txt \
    --index-url http://localhost:3141/root/pypi/+simple/ \
    --trusted-host localhost \
    --dest /tmp/warmup/ && rm -rf /tmp/warmup/
```

---

## ۹. آپدیت سیستم عامل Ubuntu 24.04 از طریق کش

### یک‌بار روی سرور کش (warm-up)

برای اینکه packages آپدیت Ubuntu 24.04 از قبل در cache باشند، روی **سرور کش** اجرا کنید:

```bash
cd /srv/cache
bash scripts/prefetch-apt.sh
```

این اسکریپت packages زیر را cache می‌کند:
- لیست packages همه repo‌های Ubuntu 24.04 (noble, noble-updates, noble-security, noble-backports)
- packages آپدیت سیستم (`dist-upgrade`)
- ابزارهای ضروری: `curl`, `git`, `build-essential`, `python3`, `postgresql-client`, `containerd` و ...

---

### تنظیم هر سرور کلاینت Ubuntu 24.04

**مرحله ۱ — یک‌بار تنظیم proxy:**

```bash
# تنظیم apt proxy (دائمی)
echo 'Acquire::http::Proxy "http://10.10.10.111:3142";' | sudo tee /etc/apt/apt.conf.d/00proxy

# تست اتصال
sudo apt-get update
```

**مرحله ۲ — آپدیت سیستم عامل (مثل همیشه):**

```bash
sudo apt-get update
sudo apt-get upgrade -y
# یا
sudo apt-get dist-upgrade -y
```

همه packages از cache سرو می‌شوند — **بدون نیاز به اینترنت مستقیم**.

---

### نصب Docker روی سرور جدید (کاملاً بدون اینترنت)

Docker GPG key و همه packages روی سرور کش ذخیره شده‌اند:

```bash
# پیش‌نیازها از cache
sudo apt-get install -y ca-certificates curl gnupg

# Docker GPG key — مستقیم از سرور کش (بدون اینترنت)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL http://10.10.10.111/keys/docker.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# اضافه کردن Docker repo (از طریق apt-cacher-ng cache می‌شود)
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

# نصب Docker (همه packages از cache)
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
sudo systemctl enable --now docker

# اضافه کردن user به گروه docker
sudo usermod -aG docker $USER
```

> **نکته:** GPG key در `http://10.10.10.111/keys/docker.gpg` ذخیره شده و Docker packages (~144MB) از قبل cache شده‌اند.

---

### غیرفعال کردن موقت proxy

```bash
# یک دستور بدون proxy
sudo apt-get -o Acquire::http::Proxy=false install <package>

# غیرفعال کردن دائم
sudo rm /etc/apt/apt.conf.d/00proxy
```

---

### بروزرسانی دوره‌ای cache apt (روی سرور کش)

برای اینکه آخرین آپدیت‌های Ubuntu همیشه در cache باشند، می‌توانید cron تنظیم کنید:

```bash
# روی سرور کش — هر شنبه ساعت ۲ صبح
crontab -e
# اضافه کنید:
0 2 * * 6 /srv/cache/scripts/prefetch-apt.sh >> /var/log/cache-apt-warmup.log 2>&1
```

---

## ۱۰. تنظیم دقیق هر پروژه RAG

### پروژه RAG-Ingest

**فایل `deployment/Dockerfile`:**

```dockerfile
# خط FROM:
FROM 10.10.10.111:5001/library/python:3.11-slim

# خط pip install build tools:
RUN python -m pip install --upgrade pip setuptools==69.5.1 wheel \
    --index-url http://10.10.10.111:3141/root/pypi/+simple/ \
    --trusted-host 10.10.10.111

# خط pip install requirements:
ARG INSTALL_DEV=false
RUN if [ "$INSTALL_DEV" = "true" ]; then \
        pip install --no-cache-dir --timeout=600 --retries=3 \
            --index-url http://10.10.10.111:3141/root/pypi/+simple/ \
            --trusted-host 10.10.10.111 \
            -r requirements-dev.txt; \
    else \
        pip install --no-cache-dir --timeout=600 --retries=3 \
            --index-url http://10.10.10.111:3141/root/pypi/+simple/ \
            --trusted-host 10.10.10.111 \
            -r requirements.txt; \
    fi
```

**فایل `deployment/docker-compose.ingest.yml`:**

```yaml
services:
  db:
    image: 10.10.10.111:5001/pgvector/pgvector:pg16
  redis:
    image: 10.10.10.111:5001/library/redis:7-alpine
  nginx-proxy-manager:
    image: 10.10.10.111:5001/jc21/nginx-proxy-manager:latest
  cadvisor:
    image: 10.10.10.111:5001/zcube/cadvisor:latest
  node-exporter:
    image: 10.10.10.111:5003/prometheus/node-exporter:v1.7.0
  postgres-exporter:
    image: 10.10.10.111:5003/prometheuscommunity/postgres-exporter:v0.15.0
```

---

### پروژه RAG_Reranker

**فایل `deployment/Dockerfile`:**

```dockerfile
FROM 10.10.10.111:5001/library/python:3.11-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl

COPY requirements.txt .

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt \
        --index-url http://10.10.10.111:3141/root/pypi/+simple/ \
        --trusted-host 10.10.10.111
```

---

### پروژه RAG-Users

**فایل `deployment/Dockerfile.backend`:**

```dockerfile
FROM 10.10.10.111:5001/library/python:3.11-slim

# ... (بقیه دستورات)

RUN pip install -r requirements.txt \
    --index-url http://10.10.10.111:3141/root/pypi/+simple/ \
    --trusted-host 10.10.10.111
```

**فایل `deployment/Dockerfile.frontend`:**

```dockerfile
FROM 10.10.10.111:5001/library/node:20-alpine

# npm را به verdaccio هدایت کنید
RUN npm config set registry http://10.10.10.111:4873

COPY package*.json ./
RUN npm ci
```

**فایل `frontend/.npmrc`** (بسازید):
```
registry=http://10.10.10.111:4873
```

**فایل `deployment/docker-compose.yml`:**

```yaml
services:
  db:
    image: 10.10.10.111:5001/library/postgres:15-alpine
  redis:
    image: 10.10.10.111:5001/library/redis:7-alpine
  rabbitmq:
    image: 10.10.10.111:5001/library/rabbitmq:3-management-alpine
```
