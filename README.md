# 🗄️ MinIO Internal Server - راهنمای نصب و راه‌اندازی

## 📌 خلاصه

سرور MinIO مستقل برای شبکه داخلی. بدون SSL و بدون NPM.
دسترسی مستقیم از طریق IP داخلی.

- **S3 API**: `http://10.10.10.50:9000`
- **Console**: `http://10.10.10.50:9001`

### سرویس‌ها
- **MinIO** — Object Storage (S3-compatible)
- **minio-init** — ساخت خودکار Bucket و Service Account (یکبار اجرا)

---

## 🚀 نصب سریع

### پیش‌نیازها
- سرور Ubuntu 20.04+ با حداقل 2GB RAM و 20GB دیسک
- دسترسی root (sudo)

### مراحل

```bash
# 1. فایل‌ها را به سرور منتقل کنید
scp -r minio-server/ ahad@10.10.10.50:/srv/

# 2. SSH به سرور
ssh ahad@10.10.10.50

# 3. اجرای اسکریپت نصب
cd /srv/deployment
sudo bash start.sh
```

اسکریپت به صورت تعاملی از شما سوال می‌پرسد:
- **منبع دانلود**: اینترنت مستقیم یا سرور کش داخلی
- **آدرس سرور کش**: در صورت انتخاب گزینه کش (پیش‌فرض: 10.10.10.111)
- IP سرور در شبکه داخلی (LAN و DMZ)
- تمام تنظیمات دیگر به صورت خودکار تولید می‌شوند

---

## 📁 ساختار فایل‌ها

```
/srv/
├── deployment/
│   ├── start.sh              # اسکریپت نصب اصلی (sudo bash start.sh)
│   ├── docker-compose.yml    # تعریف سرویس‌ها (MinIO + Monitoring)
│   ├── minio-init.sh         # اسکریپت ساخت bucket و service account
│   ├── backup_minio.sh       # اسکریپت بکاپ و ریستور
│   └── daemon.json           # تنظیمات Docker برای cache server
├── documents/
│   ├── AI_Memory.md          # حافظه پروژه
│   └── CACHE-SERVER-SETUP.md # راهنمای cache server
├── .env                      # تنظیمات (تولید می‌شود توسط start.sh)
├── README.md                 # این فایل
└── CREDENTIALS.txt           # اطلاعات دسترسی (تولید می‌شود)
```

---

## 🔗 اتصال سرور Ingest

این مقادیر را در فایل `/srv/.env` سرور Ingest وارد کنید:

```env
# MinIO Storage (Internal Server)
AWS_ACCESS_KEY_ID=<Service Access Key>
AWS_SECRET_ACCESS_KEY=<Service Secret Key>
AWS_STORAGE_BUCKET_NAME=ingest-system
AWS_S3_ENDPOINT_URL=http://10.10.10.50:9000
AWS_S3_REGION_NAME=us-east-1
AWS_S3_USE_SSL=false
```

سپس سرویس‌ها را restart کنید:
```bash
cd /srv
sudo docker compose -f deployment/docker-compose.ingest.yml up -d web worker beat
```

---

## 💾 بکاپ و ریستور

### بکاپ دستی
```bash
./backup_minio.sh backup              # بکاپ محلی
./backup_minio.sh backup --remote     # بکاپ + ارسال به سرور ریموت
```

### ریستور
```bash
./backup_minio.sh restore /opt/backups/minio/minio_backup_XXXXXX.tar.gz
```

### بکاپ خودکار (Cron)
اسکریپت `minio.sh` به صورت خودکار cron job تنظیم می‌کند:
- `0 4 * * *` — بکاپ ساعت 4:00 صبح UTC
- `0 16 * * *` — بکاپ ساعت 4:00 عصر UTC

### وضعیت و لیست
```bash
./backup_minio.sh status    # وضعیت
./backup_minio.sh list      # لیست بکاپ‌ها
```

---

## 🔧 دستورات مفید

```bash
# وضعیت سرویس‌ها
docker compose ps

# لاگ MinIO
docker compose logs -f minio

# ریستارت MinIO
docker compose restart minio

# توقف همه
docker compose down

# اجرای همه
docker compose up -d
```

---

## ⚠️ نکات مهم

1. **پورت‌های 9000 و 9001 روی همه interface ها باز هستند** — فقط از شبکه داخلی قابل دسترسی
2. **فایل CREDENTIALS.txt را بعد از ذخیره حذف کنید**
3. **برای ریستور داده‌های قبلی**: اول بکاپ MinIO از سرور قدیم بگیرید، سپس اینجا ریستور کنید

---

## 🔄 انتقال داده از سرور قدیم

اگر داده‌های MinIO از قبل روی سرور Ingest دارید:

```bash
# روی سرور قدیم (Ingest):
# 1. بکاپ از volume فعلی
sudo docker run --rm -v deployment_minio_data:/data:ro -v /tmp:/backup \
    alpine tar -czf /backup/minio_migration.tar.gz /data

# 2. انتقال به سرور جدید
scp /tmp/minio_migration.tar.gz ahad@10.10.10.50:/tmp/

# روی سرور جدید (MinIO):
# 3. ریستور
cd /srv
./backup_minio.sh restore /tmp/minio_migration.tar.gz
```
