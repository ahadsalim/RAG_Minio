#!/bin/bash
set -e

echo "============================================"
echo "  MinIO Initialization Script"
echo "  Creating 3 Buckets & 3 Service Accounts"
echo "============================================"

echo "Waiting for MinIO to be ready..."
sleep 3

echo "Configuring mc client..."
mc alias set local "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api s3v4

# =============================================================================
# Create 3 Buckets
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Creating Buckets"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for bucket in "$BUCKET_INGEST" "$BUCKET_TEMP" "$BUCKET_USERS"; do
    if mc ls local/"$bucket" > /dev/null 2>&1; then
        echo "✅ Bucket '$bucket' already exists"
    else
        echo "Creating bucket: $bucket"
        mc mb -p local/"$bucket"
        echo "✅ Bucket '$bucket' created"
    fi
done

# =============================================================================
# Create Policies
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Creating Access Policies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Policy 1: Ingest System - Access to ingest-system bucket only
cat > /tmp/ingest-policy.json << 'POLICY'
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
                "arn:aws:s3:::ingest-system"
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
                "arn:aws:s3:::ingest-system/*"
            ]
        }
    ]
}
POLICY

mc admin policy create local ingest-policy /tmp/ingest-policy.json 2>/dev/null || true
echo "✅ Policy 'ingest-policy' created"

# Policy 2: Central System - Access to temp-userfile and users-system buckets
cat > /tmp/central-policy.json << 'POLICY'
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
                "arn:aws:s3:::temp-userfile",
                "arn:aws:s3:::users-system"
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
                "arn:aws:s3:::temp-userfile/*",
                "arn:aws:s3:::users-system/*"
            ]
        }
    ]
}
POLICY

mc admin policy create local central-policy /tmp/central-policy.json 2>/dev/null || true
echo "✅ Policy 'central-policy' created"

# Policy 3: Users System - Access to temp-userfile and users-system buckets (same as central)
cat > /tmp/users-policy.json << 'POLICY'
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
                "arn:aws:s3:::temp-userfile",
                "arn:aws:s3:::users-system"
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
                "arn:aws:s3:::temp-userfile/*",
                "arn:aws:s3:::users-system/*"
            ]
        }
    ]
}
POLICY

mc admin policy create local users-policy /tmp/users-policy.json 2>/dev/null || true
echo "✅ Policy 'users-policy' created"

# =============================================================================
# Create 3 Service Accounts (Users)
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Creating Service Accounts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# User 1: Ingest System
echo ""
echo "1️⃣  Creating Ingest System user..."
mc admin user add local "$INGEST_ACCESS_KEY" "$INGEST_SECRET_KEY" 2>/dev/null || \
    echo "⚠️  User may already exist (updating...)"
mc admin policy attach local ingest-policy --user "$INGEST_ACCESS_KEY" 2>/dev/null || true
echo "✅ Ingest System user created"
echo "   Access Key: $INGEST_ACCESS_KEY"
echo "   Bucket Access: ingest-system"

# User 2: Central System
echo ""
echo "2️⃣  Creating Central System user..."
mc admin user add local "$CENTRAL_ACCESS_KEY" "$CENTRAL_SECRET_KEY" 2>/dev/null || \
    echo "⚠️  User may already exist (updating...)"
mc admin policy attach local central-policy --user "$CENTRAL_ACCESS_KEY" 2>/dev/null || true
echo "✅ Central System user created"
echo "   Access Key: $CENTRAL_ACCESS_KEY"
echo "   Bucket Access: temp-userfile, users-system"

# User 3: Users System
echo ""
echo "3️⃣  Creating Users System user..."
mc admin user add local "$USERS_ACCESS_KEY" "$USERS_SECRET_KEY" 2>/dev/null || \
    echo "⚠️  User may already exist (updating...)"
mc admin policy attach local users-policy --user "$USERS_ACCESS_KEY" 2>/dev/null || true
echo "✅ Users System user created"
echo "   Access Key: $USERS_ACCESS_KEY"
echo "   Bucket Access: temp-userfile, users-system"

# =============================================================================
# Verification & Summary
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "📦 Buckets:"
mc ls local/

echo ""
echo "👥 Users:"
mc admin user ls local 2>/dev/null || true

echo ""
echo "============================================"
echo "  ✅ MinIO Initialization Completed!"
echo "============================================"
echo ""
echo "📋 Summary:"
echo "  • 3 Buckets created: ingest-system, temp-userfile, users-system"
echo "  • 3 Service Accounts created with appropriate permissions"
echo ""
echo "🔑 Service Account Details:"
echo ""
echo "1. Ingest System:"
echo "   Access Key: $INGEST_ACCESS_KEY"
echo "   Secret Key: ${INGEST_SECRET_KEY:0:12}..."
echo "   Buckets: ingest-system"
echo ""
echo "2. Central System:"
echo "   Access Key: $CENTRAL_ACCESS_KEY"
echo "   Secret Key: ${CENTRAL_SECRET_KEY:0:12}..."
echo "   Buckets: temp-userfile, users-system"
echo ""
echo "3. Users System:"
echo "   Access Key: $USERS_ACCESS_KEY"
echo "   Secret Key: ${USERS_SECRET_KEY:0:12}..."
echo "   Buckets: temp-userfile, users-system"
echo ""
echo "============================================"
