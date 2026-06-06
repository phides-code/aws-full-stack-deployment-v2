#!/bin/bash

# This script deletes all resources created by the project.

set -Eeuo pipefail
IFS=$'\n\t'

on_err() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    echo "" >&2
    echo "ERROR: delete-all failed at line ${line_no} (exit ${exit_code})." >&2
    echo "Last command: ${BASH_COMMAND}" >&2
    exit "$exit_code"
}
trap on_err ERR

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_var() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        die "Missing required variable: ${name} (it will be prepended later by setup)"
    fi
}

wait_until() {
    # usage: wait_until <timeout_seconds> <interval_seconds> <description> <command...>
    local timeout="$1"
    local interval="$2"
    local desc="$3"
    shift 3
    
    local deadline=$((SECONDS + timeout))
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            die "Timed out waiting for: ${desc}"
        fi
        sleep "$interval"
    done
}

cloudfront_is_deployed_and_disabled() {
    local id="$1"
    local status enabled
    
    status="$(aws cloudfront get-distribution --id "$id" | jq -r '.Distribution.Status')"
    enabled="$(aws cloudfront get-distribution --id "$id" | jq -r '.Distribution.DistributionConfig.Enabled')"
    echo "Current status: $status, Enabled: $enabled"
    [ "$status" = "Deployed" ] && [ "$enabled" = "false" ]
}

cloudfront_is_deleted() {
    local id="$1"
    ! aws cloudfront get-distribution --id "$id" >/dev/null 2>&1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Disable pagers (avoid dropping into "less")
export AWS_PAGER=""
export GH_PAGER="cat"

require_cmd aws
require_cmd jq
require_cmd gh
require_cmd git
require_cmd make
require_cmd yes
require_cmd mktemp

# Required variables (these will be prepended by setup.sh later)
require_var PROJECT_NAME
require_var SERVICE_NAME
require_var AWS_REGION
require_var S3_BUCKET_NAME
require_var CLOUDFRONT_DISTRIBUTION_ID
require_var CLOUDFRONT_OAC_ID

echo "=== Deleting CloudFront distribution and related resources ==="

echo "Fetching current CloudFront distribution config..."
cfg="$(mktemp)"
if aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID" > "$cfg"; then
    echo "Extracting ETag..."
    ETAG="$(jq -r '.ETag' "$cfg")"
    if [ -z "$ETAG" ] || [ "$ETAG" = "null" ]; then
        die "Failed to read CloudFront distribution ETag"
    fi
    echo "ETag: $ETAG"
    
    enabled="$(jq -r '.DistributionConfig.Enabled' "$cfg")"
    echo "Current Enabled: $enabled"
    
    if [ "$enabled" = "true" ]; then
        echo "Disabling CloudFront distribution..."
        disabled_cfg="$(mktemp)"
        jq '.DistributionConfig | .Enabled = false' "$cfg" > "$disabled_cfg"
        aws cloudfront update-distribution \
        --id "$CLOUDFRONT_DISTRIBUTION_ID" \
        --distribution-config "file://${disabled_cfg}" \
        --if-match "$ETAG"
        rm -f "$disabled_cfg"
    else
        echo "Distribution already disabled (or disabling)."
    fi
    
    echo "Waiting for CloudFront distribution to be fully disabled..."
    wait_until 7200 10 "CloudFront distribution to become Deployed+Disabled" cloudfront_is_deployed_and_disabled "$CLOUDFRONT_DISTRIBUTION_ID"
    
    echo "Deleting CloudFront distribution..."
    LATEST_ETAG="$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID" | jq -r '.ETag')"
    if [ -z "$LATEST_ETAG" ] || [ "$LATEST_ETAG" = "null" ]; then
        die "Failed to fetch latest CloudFront distribution ETag"
    fi
    aws cloudfront delete-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" --if-match "$LATEST_ETAG"
    
    echo "Waiting for CloudFront distribution to be deleted..."
    wait_until 7200 15 "CloudFront distribution deletion" cloudfront_is_deleted "$CLOUDFRONT_DISTRIBUTION_ID"
else
    echo "CloudFront distribution not found; skipping distribution disable/delete."
fi
rm -f "$cfg"

echo "Deleting Origin Access Control (OAC)..."
if aws cloudfront get-origin-access-control --id "$CLOUDFRONT_OAC_ID" >/dev/null 2>&1; then
    OAC_ETAG="$(aws cloudfront get-origin-access-control --id "$CLOUDFRONT_OAC_ID" | jq -r '.ETag')"
    if [ -z "$OAC_ETAG" ] || [ "$OAC_ETAG" = "null" ]; then
        die "Failed to fetch CloudFront OAC ETag"
    fi
    aws cloudfront delete-origin-access-control --id "$CLOUDFRONT_OAC_ID" --if-match "$OAC_ETAG"
else
    echo "OAC not found; skipping."
fi

echo "=== Emptying and deleting S3 bucket ==="
if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" >/dev/null 2>&1; then
    aws s3 rm "s3://$S3_BUCKET_NAME" --recursive
    aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION"
else
    echo "S3 bucket not found; skipping."
fi

frontend_dir="${PROJECT_NAME}-frontend"
if [ ! -d "$frontend_dir" ]; then
    die "Expected frontend directory not found: ${frontend_dir}"
fi
cd "$frontend_dir"

echo "Deleting frontend GitHub repo..."
frontend_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [ -z "$frontend_repo" ] || [ "$frontend_repo" = "null" ]; then
    die "Failed to resolve frontend GitHub repo from current directory"
fi
gh repo delete "$frontend_repo" --yes

echo "=== Deleting backend resources ==="
cd "../$SERVICE_NAME"

echo "Deleting backend CloudFormation stack..."
echo "Deleting backend CloudFormation stack (auto-confirm enabled)..."
# `yes` often exits with SIGPIPE once `make` stops reading stdin; with pipefail that would fail the script.
# So we temporarily disable `pipefail` (and `-e`) and capture *make's* exit status explicitly.
set +e
set +o pipefail
yes | make delete
make_status="${PIPESTATUS[1]}"
set -o pipefail
set -e
if [ "$make_status" -ne 0 ]; then
    die "Backend stack deletion failed (make delete exit: $make_status)"
fi

echo "Deleting backend GitHub repo..."
backend_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [ -z "$backend_repo" ] || [ "$backend_repo" = "null" ]; then
    die "Failed to resolve backend GitHub repo from current directory"
fi
gh repo delete "$backend_repo" --yes

cd ..

echo "=== All resources deleted ==="
