# 👤 راهنمای ساخت کاربر جدید در MinIO

## 📌 هدف

وقتی سرور جدیدی (مثلاً Core، Analytics و ...) بخواهد به MinIO وصل شود، باید برای آن یک **کاربر اختصاصی** با **دسترسی محدود** به bucket خودش بسازید.

### الگوی امنیتی

| مرحله | توضیح |
|-------|-------|
| **Bucket** | هر سرویس bucket مخصوص خودش را دارد |
| **Policy** | دسترسی فقط به bucket خودش |
| **User** | Access Key + Secret Key اختصاصی |

---

## روش 1: از Console (رابط وب) — ساده‌ترین

### 1. ورود به Console

- آدرس: `http://10.10.10.50:9001`
- کاربر Root:
  ```
  Username: minioadmin
  Password: (در فایل .env سرور MinIO → MINIO_ROOT_PASSWORD)
  ```

### 2. ساخت Bucket (اگر لازم است)

- `Buckets` → `Create Bucket`
- نام: مثلاً `core-system`

### 3. ساخت Policy

- `Policies` → `Create Policy`
- نام: مثلاً `core-policy`
- محتوا (فقط `core-system` را با نام bucket خودتان عوض کنید):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::core-system"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListMultipartUploadParts",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::core-system/*"
      ]
    }
  ]
}
```

### 4. ساخت کاربر

- `Identity` → `Users` → `Create User`
- **Access Key**: یک نام دلخواه (مثلاً `core-user`)
- **Secret Key**: یک رمز قوی (حداقل 8 کاراکتر)
- **Policy**: انتخاب policy ساخته‌شده (`core-policy`)

---

## روش 2: از خط فرمان (سرور MinIO)

```bash
# SSH به سرور MinIO
ssh ahad@10.10.10.50

# اجرای mc داخل Docker
sudo docker run --rm -it --network srv_minio_net --entrypoint '' minio/mc /bin/sh
```

داخل container:

```bash
# اتصال به MinIO
mc alias set local http://minio:9000 minioadmin MINIO_ROOT_PASSWORD

# 1. ساخت bucket
mc mb local/core-system

# 2. ساخت کاربر
mc admin user add local NEW_ACCESS_KEY NEW_SECRET_KEY

# 3. ساخت policy
cat > /tmp/policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::core-system"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListMultipartUploadParts",
        "s3:AbortMultipartUpload"
      ],
      "Resource": ["arn:aws:s3:::core-system/*"]
    }
  ]
}
EOF

# 4. ایجاد policy
mc admin policy create local core-policy /tmp/policy.json

# 5. اتصال policy به کاربر
mc admin policy attach local core-policy --user NEW_ACCESS_KEY

# 6. بررسی
mc admin user ls local

# خروج
exit
```

---

## تنظیم در سرور مقصد

در فایل `.env` سرور جدید:

```env
AWS_ACCESS_KEY_ID=NEW_ACCESS_KEY
AWS_SECRET_ACCESS_KEY=NEW_SECRET_KEY
AWS_STORAGE_BUCKET_NAME=core-system
AWS_S3_ENDPOINT_URL=http://10.10.10.50:9000
AWS_S3_REGION_NAME=us-east-1
AWS_S3_USE_SSL=false
```

> آدرس جایگزین از شبکه LAN: `http://192.168.100.105:9000`

---

## تست اتصال (Python)

```python
import boto3
from botocore.client import Config

s3 = boto3.client('s3',
    endpoint_url='http://10.10.10.50:9000',
    aws_access_key_id='NEW_ACCESS_KEY',
    aws_secret_access_key='NEW_SECRET_KEY',
    config=Config(signature_version='s3v4'),
    region_name='us-east-1'
)

# تست آپلود
s3.put_object(Bucket='core-system', Key='test.txt', Body=b'Hello')
print('Upload OK')

# تست خواندن
obj = s3.get_object(Bucket='core-system', Key='test.txt')
print(f'Read: {obj["Body"].read().decode()}')

# تست حذف
s3.delete_object(Bucket='core-system', Key='test.txt')
print('Delete OK')
```

---

## کاربران فعلی

| کاربر | نوع | Bucket | Policy |
|-------|-----|--------|--------|
| `minioadmin` | Root | همه | admin (کامل) |
| `gxMvuQSlEu4QJbk2RUI7` | Ingest | `ingest-system` | `ingest-policy` |

---

## ⚠️ نکات مهم

1. **هرگز از کاربر root** (`minioadmin`) در سرویس‌ها استفاده نکنید
2. **هر سرویس = یک کاربر + یک bucket + یک policy**
3. **Secret Key حداقل 8 کاراکتر** باشد
4. بعد از ساخت کاربر، حتماً **تست اتصال** بزنید
