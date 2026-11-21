#!/usr/bin/env bash
# =============================================================================
#  bootstrap-state-backend.sh — run ONCE, before bootstrap-terraform-iam.sh
# =============================================================================
#  WHY OUTSIDE THE PIPELINE:
#    Every leaf stores its state in an S3 bucket. The pipeline cannot create the
#    place where its own state lives, so the bucket is created by hand, once.
#
#  WHAT THIS CREATES (skipped if it already exists):
#    S3 bucket  <org>-tfstate-<account id>
#      versioning on · encrypted with S3's own keys (SSE-S3, no KMS key) · public access blocked
#
#  RUN IT WITH: your own admin credentials (the ones from `aws configure`).
#  USAGE:       bash scripts/bootstrap-state-backend.sh
#  OPTIONAL ENV: REGION (default us-east-2) · ORG (default acme)
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-2}"
ORG="${ORG:-acme}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${ORG}-tfstate-${ACCOUNT_ID}"

echo "→ Account : ${ACCOUNT_ID}"
echo "→ Region  : ${REGION}"
echo "→ Bucket  : ${BUCKET}"
echo ""

echo "→ S3 bucket ${BUCKET}"
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "  (already exists — skipping creation)"
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "  created"
fi

echo "→ Bucket settings (versioning, encryption, public access block)"
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" }
    }]
  }'

aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo ""
echo "✅ State backend ready."
echo ""
echo "   Put this account id in pipelines/config/dev-config.txt (and _shared-config.txt):"
echo "     AWS_ACCOUNT_ID=${ACCOUNT_ID}"
echo "     SHARED_ACCOUNT_ID=${ACCOUNT_ID}"
echo ""
echo "Next step:  bash scripts/bootstrap-terraform-iam.sh"
