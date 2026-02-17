#!/bin/bash
set -e

echo "============================================"
echo "  MinIO Initialization Script"
echo "============================================"

echo "Waiting for MinIO to be ready..."
sleep 3

echo "Configuring mc client..."
mc alias set local "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api s3v4

# Create bucket if it doesn't exist
echo "Checking bucket: $BUCKET_NAME"
if mc ls local/"$BUCKET_NAME" > /dev/null 2>&1; then
    echo "✅ Bucket '$BUCKET_NAME' already exists"
else
    echo "Creating bucket: $BUCKET_NAME"
    mc mb -p local/"$BUCKET_NAME"
    echo "✅ Bucket '$BUCKET_NAME' created"
fi

# Create dedicated ingest user (not root service account)
INGEST_USER="${SERVICE_ACCESS_KEY}"
INGEST_PASS="${SERVICE_SECRET_KEY}"

echo ""
echo "Creating dedicated 'ingest' user..."

# Create user (or update password if exists)
mc admin user add local "$INGEST_USER" "$INGEST_PASS" 2>/dev/null || \
    echo "⚠️  User may already exist (updating...)"

# Create policy that limits access to only the ingest bucket
echo "Creating bucket-specific policy..."
cat > /tmp/ingest-policy.json << POLICY
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
                "arn:aws:s3:::${BUCKET_NAME}"
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
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
POLICY

mc admin policy create local ingest-policy /tmp/ingest-policy.json 2>/dev/null || \
    mc admin policy create local ingest-policy /tmp/ingest-policy.json 2>&1 || true

# Attach policy to user
mc admin policy attach local ingest-policy --user "$INGEST_USER" 2>/dev/null || true

echo "✅ User 'ingest' created with limited access to bucket '$BUCKET_NAME'"
echo "   Access Key (username): $INGEST_USER"
echo "   Secret Key (password): ${INGEST_PASS:0:8}..."

# Verify
echo ""
echo "Bucket listing:"
mc ls local/
echo ""
echo "Users:"
mc admin user ls local 2>/dev/null || true
echo ""
echo "============================================"
echo "  MinIO initialization completed!"
echo "============================================"
