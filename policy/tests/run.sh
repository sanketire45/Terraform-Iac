#!/usr/bin/env bash
# Policy unit tests — run after changing ANY rule:   policy/tests/run.sh      (needs `conftest`)
#   bad.plan.json         a REAL `terraform show -json` of a deliberately bad config → every needle below must appear in the output
#   good.plan.json        a REAL plan of a clean config (443 only, encrypted, public-access-block, scoped IAM, full tags) → must pass with no failures
#   delete-prod.plan.json hand-made: a prod DB cluster REPLACE and a prod DB DELETE must be denied, a dev DELETE must not
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; pol="$here/.."; fx="$here/fixtures"
command -v conftest >/dev/null 2>&1 || { echo "conftest is not installed — install it (e.g. brew install conftest) and re-run"; exit 2; }
run() { conftest test "$1" --policy "$pol" --data "$pol/data" --no-color 2>&1; }
fail=0
expect() {   # expect <fixture> <needle>
  if run "$fx/$1" | grep -qF -- "$2"; then echo "  ok    $1 → $2"; else echo "  MISS  $1 → expected a message containing: $2"; fail=1; fi
}
refute() {   # refute <fixture> <needle>
  if run "$fx/$1" | grep -qF -- "$2"; then echo "  WRONG $1 → must NOT contain: $2"; fail=1; else echo "  ok    $1 → (no) $2"; fi
}

echo "bad.plan.json — every rule must fire"
expect bad.plan.json "aws_security_group.bad: security group opens port 22 to 0.0.0.0/0"
expect bad.plan.json "aws_ebs_volume.plain (aws_ebs_volume): encrypted must be true"
expect bad.plan.json "aws_s3_bucket.nopab: new S3 bucket has no aws_s3_bucket_public_access_block"
expect bad.plan.json "aws_iam_policy.star: IAM policy allows Action * on Resource *"
expect bad.plan.json "missing mandatory tag(s)"
refute bad.plan.json "aws_s3_bucket.logs: new S3 bucket has no"

echo "good.plan.json — must pass"
if run "$fx/good.plan.json" | grep -qE 'FAIL|failures'; then run "$fx/good.plan.json"; echo "  WRONG good.plan.json produced failures"; fail=1; else echo "  ok    good.plan.json → clean"; fi

echo "delete-prod.plan.json — prod deletes denied, dev delete allowed"
expect delete-prod.plan.json "module.rds.aws_rds_cluster.main: plan would REPLACE a protected aws_rds_cluster in prod"
expect delete-prod.plan.json "module.rds.aws_db_instance.old: plan would DELETE a protected aws_db_instance in prod"
refute delete-prod.plan.json "module.dev.aws_db_instance.scratch"

[ "$fail" = 0 ] && echo "ALL POLICY TESTS PASSED" || { echo "POLICY TESTS FAILED"; exit 1; }
