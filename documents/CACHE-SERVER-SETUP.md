# تنظیمات Cache Server برای سرور MinIO

## خلاصه

این سرور برای استفاده از Cache Server داخلی به آدرس `10.10.10.111` پیکربندی شده است.
تمام تصاویر Docker از cache دریافت می‌شوند و در صورت قطع اینترنت، سیستم به طور کامل کار می‌کند.

---

## ۱. تنظیم Docker Daemon (یکبار - ضروری)

برای اینکه Docker بتواند از cache server استفاده کند، باید فایل `/etc/docker/daemon.json` را تنظیم کنید:

```bash
# کپی فایل پیکربندی
sudo cp /srv/deployment/daemon.json /etc/docker/daemon.json

# ریستارت Docker
sudo systemctl restart docker

# بررسی وضعیت
sudo systemctl status docker
```

**محتوای فایل `/etc/docker/daemon.json`:**
```json
{
  "registry-mirrors": [
    "http://10.10.10.111:5001"
  ],
  "insecure-registries": [
    "10.10.10.111:5001",
    "10.10.10.111:5002",
    "10.10.10.111:5003",
    "10.10.10.111:5004",
    "10.10.10.111:5005"
  ]
}
```

---

## ۲. تصاویر Docker استفاده شده در این پروژه

تمام تصاویر در `docker-compose.yml` به cache server تغییر مسیر داده شده‌اند:

| تصویر اصلی | تصویر از Cache | پورت Cache |
|-----------|----------------|------------|
| `minio/minio:latest` | `10.10.10.111:5003/minio/minio:latest` | 5003 (Quay.io mirror) |
| `minio/mc:latest` | `10.10.10.111:5003/minio/mc:latest` | 5003 (Quay.io mirror) |
| `prom/node-exporter:latest` | `10.10.10.111:5003/prom/node-exporter:latest` | 5003 (Quay.io mirror) |
| `zcube/cadvisor:latest` | `10.10.10.111:5003/zcube/cadvisor:latest` | 5003 (Quay.io mirror) |
| `grafana/promtail:latest` | `10.10.10.111:5003/grafana/promtail:latest` | 5003 (Quay.io mirror) |

**نکته:** همه تصاویر این پروژه در Quay.io mirror (پورت 5003) ذخیره شده‌اند.

---

## ۳. اطمینان از وجود تصاویر در Cache

✅ **تمام تصاویر از قبل در cache موجود هستند!**

بررسی تصاویر موجود در cache:
```bash
# لیست تصاویر موجود در Quay.io mirror
curl -s http://10.10.10.111:5003/v2/_catalog | jq -r '.repositories[]' | grep -E 'minio|node-exporter|cadvisor|promtail'
```

خروجی:
```
grafana/promtail
minio/mc
minio/minio
prom/node-exporter
zcube/cadvisor
```

اگر تصویری موجود نبود، روی **سرور cache (10.10.10.111)** اضافه کنید:
```bash
cd /srv/cache
# مثال برای اضافه کردن تصویر جدید
docker pull <image-name>:latest
docker tag <image-name>:latest localhost:5003/<image-name>:latest
docker push localhost:5003/<image-name>:latest
```

---

## ۴. تست اتصال به Cache Server

```bash
# تست دریافت تصویر از cache
docker pull 10.10.10.111:5001/minio/minio:latest

# اگر خطا دریافت کردید، بررسی کنید:
# 1. آیا daemon.json تنظیم شده؟
cat /etc/docker/daemon.json

# 2. آیا Docker ریستارت شده؟
sudo systemctl status docker

# 3. آیا cache server در دسترس است؟
curl http://10.10.10.111:5001/v2/_catalog
```

---

## ۵. راه‌اندازی سرویس‌ها

بعد از تنظیم Docker daemon، می‌توانید سرویس‌ها را راه‌اندازی کنید:

```bash
cd /srv/deployment
docker compose down
docker compose pull    # دریافت تصاویر از cache
docker compose up -d
```

---

## ۶. بررسی وضعیت Cache

```bash
# بررسی صفحه وضعیت cache server
curl http://10.10.10.111/

# بررسی لیست تصاویر موجود در Docker Hub mirror
curl http://10.10.10.111:5001/v2/_catalog

# بررسی لیست تصاویر موجود در Quay.io mirror
curl http://10.10.10.111:5003/v2/_catalog
```

---

## ۷. عملکرد در صورت قطع اینترنت

✅ **تمام تصاویر Docker از cache دریافت می‌شوند**
- اگر تصویر در cache باشد → دریافت از cache محلی (بدون نیاز به اینترنت)
- اگر تصویر در cache نباشد → cache server آن را از اینترنت دانلود و ذخیره می‌کند

✅ **این پروژه نیاز به کتابخانه‌های Python ندارد**
- فقط تصاویر Docker استفاده می‌شود
- همه تصاویر از قبل در cache موجود هستند

---

## ۸. نکات مهم

1. **حتماً daemon.json را تنظیم کنید** - بدون این، Docker نمی‌تواند از cache استفاده کند
2. **تصاویر Quay.io** - `prom/node-exporter` از Quay.io است و از پورت 5003 استفاده می‌کند
3. **بدون نیاز به تغییر کد** - فقط تنظیم یکبار daemon.json کافی است
4. **تست قبل از قطع اینترنت** - مطمئن شوید همه تصاویر یکبار pull شده‌اند

---

## ۹. عیب‌یابی

### خطا: "http: server gave HTTP response to HTTPS client"

**راه‌حل:** daemon.json را بررسی کنید و مطمئن شوید که `insecure-registries` تنظیم شده است.

### خطا: "connection refused"

**راه‌حل:** 
1. بررسی کنید cache server در دسترس است: `ping 10.10.10.111`
2. بررسی کنید پورت‌ها باز هستند: `telnet 10.10.10.111 5001`

### تصویر دانلود نمی‌شود

**راه‌حل:**
1. روی cache server، تصویر را اضافه کنید
2. لاگ‌های cache را بررسی کنید: `docker compose logs -f` (روی cache server)

---

## ۱۰. مراجع

- مستندات کامل cache server: `/srv/CLIENT-SETUP.md`
- پورت‌های cache server:
  - Docker Hub: `10.10.10.111:5001`
  - GitHub Container Registry: `10.10.10.111:5002`
  - Quay.io: `10.10.10.111:5003`
  - Google Container Registry: `10.10.10.111:5004`
  - Kubernetes Registry: `10.10.10.111:5005`
