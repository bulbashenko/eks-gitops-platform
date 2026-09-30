# Shared S3 backend settings for every layer under infra/live.
# The account-specific bucket and KMS key are passed by the Makefile / CI:
#   terraform init -backend-config=../backend.hcl -backend-config="bucket=egp-tfstate-<account_id>" \
#                  -backend-config="kms_key_id=alias/egp-tfstate"
region       = "eu-north-1"
encrypt      = true
use_lockfile = true
