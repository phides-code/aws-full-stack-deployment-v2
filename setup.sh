#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

on_err() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    echo "" >&2
    echo "ERROR: setup failed at line ${line_no} (exit ${exit_code})." >&2
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

require_nonempty() {
    local label="$1"
    local value="$2"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        die "Expected non-empty value for: ${label}"
    fi
}

gh_repo_create_with_retry() {
    # usage: gh_repo_create_with_retry <repo_name> <visibility> [source_path]
    local repo_name="$1"
    local visibility="$2"
    local source_path="${3:-.}"

    local owner
    owner="$(gh api user --jq .login)"
    require_nonempty "GitHub user login" "$owner"

    local full_repo="${owner}/${repo_name}"

    # If the repo already exists, treat as success and ensure origin exists.
    if gh repo view "$full_repo" >/dev/null 2>&1; then
        echo "GitHub repo already exists: ${full_repo}"
        if ! git remote get-url origin >/dev/null 2>&1; then
            git remote add origin "git@github.com:${full_repo}.git" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    local attempts=6
    local delay=2
    local i=1
    while [ "$i" -le "$attempts" ]; do
        # --confirm avoids any prompts in scripts/CI; gh sometimes returns transient API errors.
        if gh repo create "$repo_name" --source="$source_path" --"$visibility" --confirm; then
            return 0
        fi

        # If creation errored but the repo exists, continue (GitHub API can be flaky).
        if gh repo view "$full_repo" >/dev/null 2>&1; then
            echo "GitHub repo exists after create error; continuing: ${full_repo}"
            if ! git remote get-url origin >/dev/null 2>&1; then
                git remote add origin "git@github.com:${full_repo}.git" >/dev/null 2>&1 || true
            fi
            return 0
        fi

        echo "Retrying GitHub repo creation (${i}/${attempts})..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        i=$((i + 1))
    done

    die "Failed to create GitHub repository: ${full_repo}"
}

retry_nonempty() {
    # usage: retry_nonempty <attempts> <sleep_seconds> <command...>
    local attempts="$1"
    local sleep_seconds="$2"
    shift 2

    local out=""
    local i=1
    while [ "$i" -le "$attempts" ]; do
        # shellcheck disable=SC2091
        out="$("$@" 2>/dev/null || true)"
        if [ -n "$out" ] && [ "$out" != "null" ]; then
            printf '%s' "$out"
            return 0
        fi
        sleep "$sleep_seconds"
        i=$((i + 1))
    done

    return 1
}

get_gh_run_id_for_sha() {
    local sha="$1"
    gh run list --limit 30 --json databaseId,headSha \
        | jq -r --arg sha "$sha" '.[] | select(.headSha == $sha) | .databaseId' \
        | head -n 1
}

get_latest_gh_run_id() {
    gh run list --limit 1 --json databaseId \
        | jq -r '.[0].databaseId'
}

gh_watch_last_run_no_prompt() {
    # usage: gh_watch_last_run_no_prompt [commit_sha]
    local sha="${1:-}"
    local run_id=""

    # Prefer the run created for this exact commit, to avoid watching the wrong run.
    if [ -n "$sha" ]; then
        run_id="$(retry_nonempty 60 5 get_gh_run_id_for_sha "$sha" || true)"
    fi

    # Fallback to most recent run if we couldn't match by sha.
    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
        run_id="$(retry_nonempty 60 5 get_latest_gh_run_id || true)"
    fi

    require_nonempty "GitHub Actions run ID" "$run_id"
    env GH_PAGER="cat" gh run watch "$run_id" --exit-status
}

mv_if_different() {
    local src="$1"
    local dest="$2"
    if [ "$src" != "$dest" ] && [ -e "$src" ]; then
        mv "$src" "$dest"
    fi
}

echo "=== AWS Full Stack Project Setup ==="

# Check if the user provided two arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: setup.sh PROJECT_NAME TABLE_NAME"
    echo "  TABLE_NAME: singular entity name (e.g. banana)"
    exit 1
fi

# Assign the arguments to variables
project_name="$1"
table_name="$2"
echo "Project name: $project_name"
echo "Table name: $table_name"

# Basic dependencies used throughout the script
require_cmd aws
require_cmd gh
require_cmd git
require_cmd npx
require_cmd jq
require_cmd sed
require_cmd awk
require_cmd tr
require_cmd cut
require_cmd head
require_cmd md5sum
require_cmd mktemp
require_cmd find

# convert project name and table name to 3 different formats
lowercase_table_name=$(echo "$table_name" | tr '[:upper:]' '[:lower:]')
camelcase_table_name=$(echo "$table_name" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' OFS='')
uppercase_table_name=$(echo "$table_name" | tr '[:lower:]' '[:upper:]')
lowercase_project_name=$(echo "$project_name" | tr '[:upper:]' '[:lower:]')
camel_case_project_name=$(echo "$project_name" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' OFS='')
service_name="${lowercase_project_name}-backend"

echo "Service name: $service_name"

### setup aws secrets
# Path to AWS credentials and config files
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
AWS_CONFIG_FILE="$HOME/.aws/config"

# Check if the files exist
if [ ! -f "$AWS_CREDENTIALS_FILE" ]; then
    echo "AWS credentials file not found: $AWS_CREDENTIALS_FILE"
    exit 1
fi
if [ ! -f "$AWS_CONFIG_FILE" ]; then
    echo "AWS config file not found: $AWS_CONFIG_FILE"
    exit 1
fi

echo "Extracting AWS credentials and region..."
# Extract aws_access_key_id
AWS_ACCESS_KEY_ID="$(grep -m 1 "aws_access_key_id" "$AWS_CREDENTIALS_FILE" | cut -d "=" -f 2 | tr -d '[:space:]' || true)"

# Extract aws_secret_access_key
AWS_SECRET_ACCESS_KEY="$(grep -m 1 "aws_secret_access_key" "$AWS_CREDENTIALS_FILE" | cut -d "=" -f 2 | tr -d '[:space:]' || true)"

# Extract default region
AWS_REGION="$(grep -m 1 "region" "$AWS_CONFIG_FILE" | cut -d "=" -f 2 | tr -d '[:space:]' || true)"

# Check if the aws variables are empty
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Failed to extract AWS credentials from file."
    exit 1
fi
if [ -z "$AWS_REGION" ]; then
    echo "Failed to extract AWS region from file."
    exit 1
fi

echo "AWS Region: $AWS_REGION"

# Get our AWS account ID
echo "Getting AWS account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
require_nonempty "AWS account ID" "$AWS_ACCOUNT_ID"
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Create parent folder
parent_dir="./${lowercase_project_name}-parent"
if [ ! -d "$parent_dir" ]; then
    echo "Creating parent folder: ${lowercase_project_name}-parent"
    mkdir "$parent_dir"
else
    die "Folder already exists: ${parent_dir}"
fi

# Move into the parent folder
cd "${lowercase_project_name}-parent"

# Setup backend
echo "Cloning backend template repo..."
npx degit phides-code/go-multi-api "$service_name"

# Move into the service folder
cd "$service_name" || exit

echo "Replacing template variables in backend files..."
find . -type f -exec sed -i "s/Appname/$camel_case_project_name/g" {} +
find . -type f -exec sed -i "s/appname/$lowercase_project_name/g" {} +
find . -type f -exec sed -i "s/us-east-1/$AWS_REGION/g" {} +

find . -type f -exec sed -i "s/banana/$lowercase_table_name/g" {} +
find . -type f -exec sed -i "s/Banana/$camelcase_table_name/g" {} +

## rename every file containing "banana" to "$lowercase_table_name"
mv_if_different internal/banana/banana.go internal/banana/"$lowercase_table_name".go 
mv_if_different internal/banana/banana_test.go internal/banana/"$lowercase_table_name"_test.go
mv_if_different internal/testutil/banana_fixtures.go internal/testutil/"$lowercase_table_name"_fixtures.go

## rename directory internal/banana
mv internal/banana internal/"$lowercase_table_name"

# create GitHub repo
echo "Setting up GitHub repository..."
# display a mini menu to prompt for GitHub repo visibility
visibility_options=("public" "private")
echo ""
PS3="Please select repo visibility: Make this GitHub repo Public (1) or Private (2)? "
select option in "${visibility_options[@]}"; do
    case $option in
        "public")
            selected_visibility="public"
            break
        ;;
        "private")
            selected_visibility="private"
            break
        ;;
        *)
            echo "Invalid option. Please select 1 (public) or 2 (private)."
        ;;
    esac
done

# create remote repo on github
echo "Initializing git and creating GitHub repo ($selected_visibility)..."
git init
git branch -M main
gh_repo_create_with_retry "$service_name" "$selected_visibility" "."

# Generate and save a random AWS_CF_TOKEN token
AWS_CF_TOKEN=$(head -c 64 /dev/urandom | md5sum | awk '{print $1}')

# Local SAM env vars for the backend Lambda function
jq -n \
    --arg fn "${camel_case_project_name}BackendFunction" \
    --arg token "$AWS_CF_TOKEN" \
    '{($fn): {AWS_CF_TOKEN: $token}}' > env.json

# setup AWS secrets in GitHub
echo "Adding AWS secrets to GitHub repo..."
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_CF_TOKEN --body "$AWS_CF_TOKEN"

###
### FRONTEND SETUP
###
# Move to the parent folder
cd .. || exit
# Clone the frontend template repo
echo "Cloning frontend template repo..."
npx degit phides-code/react-s3-template-app "$lowercase_project_name"-frontend

# Move into the frontend folder
cd "$lowercase_project_name"-frontend || exit

# Replace appname and table_name in frontend files
echo "Replacing template variables in frontend files..."
find . -type f -exec sed -i "s/appname/$lowercase_project_name/g" {} +
find . -type f -exec sed -i "s/banana/$lowercase_table_name/g" {} +
find . -type f -exec sed -i "s/Banana/$camelcase_table_name/g" {} +
find . -type f -exec sed -i "s/BANANA/$uppercase_table_name/g" {} +

mv_if_different src/features/bananas/AddBanana.tsx src/features/bananas/Add"$camelcase_table_name".tsx
mv_if_different src/features/bananas/BananaHeader.tsx src/features/bananas/"$camelcase_table_name"Header.tsx
mv_if_different src/features/bananas/BananaListItem.tsx src/features/bananas/"$camelcase_table_name"ListItem.tsx
mv_if_different src/features/bananas/bananasApiSlice.ts src/features/bananas/"$lowercase_table_name"sApiSlice.ts
mv_if_different src/features/bananas/Bananas.tsx src/features/bananas/"$camelcase_table_name"s.tsx
mv_if_different src/features/bananas/ListBananas.tsx src/features/bananas/List"$camelcase_table_name"s.tsx
mv_if_different src/features/bananas/ViewBanana.tsx src/features/bananas/View"$camelcase_table_name".tsx
mv_if_different src/features/bananas src/features/"$lowercase_table_name"s

### Generate random ID for CloudFront CallerReference and S3 bucket name
random_id=$(head -c 64 /dev/urandom | md5sum | awk '{print $1}')
short_id=${random_id:0:8}

### setup new s3 bucket
# Combine project name and short ID
bucket_name="${lowercase_project_name}-${short_id}"

# Create the S3 bucket
echo "=== Creating S3 bucket for frontend ==="
aws s3 mb "s3://${bucket_name}"
aws s3api head-bucket --bucket "$bucket_name" >/dev/null
echo "Created S3 bucket: ${bucket_name}"

### setup CloudFront
# copy CloudFront distribution config, S3 policy, and OAC config
cp ../../json-files/my-dist-config.json .
cp ../../json-files/s3-policy.json .
cp ../../json-files/oac-config.json .

# replace placeholder names in json files
sed -i "s|BUCKET_NAME|$bucket_name|" my-dist-config.json
sed -i "s|CALLER_REFERENCE|$random_id|" my-dist-config.json
sed -i "s|AWS_REGION|$AWS_REGION|" my-dist-config.json
sed -i "s|BUCKET_NAME|$bucket_name|" s3-policy.json
sed -i "s|BUCKET_NAME|$bucket_name|" oac-config.json

# create OAC, capture the OAC id and insert in my-dist-config.json
echo "=== Creating CloudFront Origin Access Control (OAC) ==="
oac_create_response=$(aws cloudfront create-origin-access-control --origin-access-control-config file://oac-config.json)
oac_id=$(echo "$oac_create_response" | jq -r '.OriginAccessControl.Id')
require_nonempty "CloudFront OAC ID" "$oac_id"
echo "Created OAC with ID: $oac_id"
sed -i "s|OAC_ID|$oac_id|" my-dist-config.json

# create CloudFront distribution and capture the ARN
echo "=== Creating CloudFront distribution ==="
dist_create_response=$(aws cloudfront create-distribution --distribution-config file://my-dist-config.json)
arn=$(echo "$dist_create_response" | jq -r '.Distribution.ARN')
dist_domain=$(echo "$dist_create_response" | jq -r '.Distribution.DomainName')
dist_domain=https://$dist_domain
distribution_id=$(echo "$dist_create_response" | jq -r '.Distribution.Id')
require_nonempty "CloudFront distribution ARN" "$arn"
require_nonempty "CloudFront distribution ID" "$distribution_id"
require_nonempty "CloudFront distribution domain" "$dist_domain"
echo "Created CloudFront distribution: ${distribution_id}"
echo "Distribution ARN: $arn"

# update s3-policy.json with ARN
echo "Updating S3 bucket policy with CloudFront distribution ARN..."
sed -i "s|SOURCE_ARN|$arn|" s3-policy.json

# update S3 bucket policy
echo "Applying S3 bucket policy..."
aws s3api put-bucket-policy --bucket "$bucket_name" --policy file://s3-policy.json

# remove json files
echo "Cleaning up CloudFront and S3 policy files..."
rm my-dist-config.json
rm s3-policy.json
rm oac-config.json

# go back to the backend directory to set frontend origin and perform initial commit
cd ../"$service_name" || exit

# setup distribution url as origin in backend
echo "Setting CloudFront distribution as frontend origin in backend..."
find . -maxdepth 1 -type f -exec sed -i "s|FRONTEND_URL|$dist_domain|g" {} +

# commit and push backend changes (including frontend origin) to GitHub
echo "Committing and pushing backend code to GitHub..."
git add .
git commit -m "initial commit"
git push origin main

# watch the progress of the backend GitHub Actions workflow
echo "Watching GitHub Actions workflow..."
backend_sha="$(git rev-parse HEAD)"
gh_watch_last_run_no_prompt "$backend_sha"

# After backend deployment is complete, fetch the API Gateway ID and service URL
echo "Fetching API Gateway ID..."
get_api_gateway_id() {
    aws apigateway get-rest-apis --output json \
        | jq -r --arg service "$service_name" '.items[]? | select(.name == $service) | .id' \
        | head -n 1
}
api_gateway_id="$(retry_nonempty 30 10 get_api_gateway_id || true)"
require_nonempty "API Gateway ID (from API Gateway named: ${service_name})" "$api_gateway_id"
service_url_host="${api_gateway_id}.execute-api.${AWS_REGION}.amazonaws.com"
service_url="${dist_domain}/Prod/${lowercase_table_name}s"
echo "Service URL: $service_url"

# Add API as custom origin and /Prod/* behavior to CloudFront distribution
echo "Adding API origin and cache behavior to CloudFront distribution..."
export AWS_PAGER=""
cf_config=$(mktemp)
cf_updated=$(mktemp)
cf_fragment=$(mktemp)
trap 'rm -f "$cf_config" "$cf_updated" "$cf_fragment"' EXIT
aws cloudfront get-distribution-config --id "$distribution_id" --query 'DistributionConfig' > "$cf_config"
cf_etag=$(aws cloudfront get-distribution-config --id "$distribution_id" --query 'ETag' --output text)
require_nonempty "CloudFront distribution ETag" "$cf_etag"
cp ../../json-files/api-origin-behavior.json "$cf_fragment"
sed -i "s|ORIGIN_ID|$service_url_host|g" "$cf_fragment"
sed -i "s|CF_TOKEN|$AWS_CF_TOKEN|g" "$cf_fragment"
sed -i "s|PATH_PATTERN|/Prod/${lowercase_table_name}s*|g" "$cf_fragment"
jq -s '.[1] as $frag | .[0] | .Origins.Quantity += 1 | .Origins.Items += [$frag.origin] | .CacheBehaviors = $frag.cacheBehaviors' "$cf_config" "$cf_fragment" > "$cf_updated"
aws cloudfront update-distribution --id "$distribution_id" --distribution-config "file://${cf_updated}" --if-match "$cf_etag"
echo "CloudFront distribution update initiated (API origin and /Prod/* behavior). Deployment may take 5–15 minutes."

# return to the frontend directory to set up its repo and initial commit
cd ../"$lowercase_project_name"-frontend || exit

# Create GitHub repo for frontend
echo "=== Creating GitHub repo for frontend ==="
git init
git branch -M main
gh_repo_create_with_retry "${lowercase_project_name}-frontend" "$selected_visibility" "."

# Setup AWS secrets in GitHub for frontend
echo "Adding AWS and deployment secrets to GitHub repo for frontend..."
gh secret set AWS_ACCESS_KEY_ID --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_REGION --body "$AWS_REGION"
gh secret set AWS_S3_BUCKET --body "$bucket_name"
gh secret set AWS_DISTRIBUTION --body "$distribution_id"
gh secret set "$uppercase_table_name"S_SERVICE_URL --body "$service_url"

# Create local .env file for frontend
echo "Creating local .env file for frontend..."
cat <<EOF > .env
VITE_${uppercase_table_name}S_SERVICE_URL=$service_url
EOF

### initial commit:
echo "Committing and pushing frontend code to GitHub..."
git add .
git commit -m "initial commit"
git push origin main

# watch the progress of the frontend GitHub Actions workflow
echo "Watching GitHub Actions workflow..."
frontend_sha="$(git rev-parse HEAD)"
gh_watch_last_run_no_prompt "$frontend_sha"



### wrap up message
echo ""
echo "Please allow a few moments for the GitHub Actions workflow to complete."
echo "View the progress by running:"
echo ""
echo "cd $lowercase_project_name-parent/$lowercase_project_name-frontend"
echo "gh run watch"
echo ""

# go back to the parent directory
cd .. || exit

echo "==== Summary of created resources and variables ===="
echo "Project name: $project_name"
echo "Service name: $service_name"
echo "API Gateway ID: $api_gateway_id"
echo "Service URL: $service_url"
echo "S3 Bucket Name: $bucket_name"
echo "CloudFront Distribution ID: $distribution_id"
echo "CloudFront OAC ID: $oac_id"
echo "CloudFront Domain: $dist_domain"
echo ""
echo "All variables above can be used for further automation or manual configuration."

# copy delete-all.sh from the parent directory
echo "Preparing delete-all.sh for future cleanup automation..."
cp ../delete-all.sh .

# Prepare variable declarations for delete-all.sh
delete_vars=$(cat <<EOF
#!/bin/bash
PROJECT_NAME="$project_name"
SERVICE_NAME="$service_name"
AWS_REGION="$AWS_REGION"
S3_BUCKET_NAME="$bucket_name"
CLOUDFRONT_DISTRIBUTION_ID="$distribution_id"
CLOUDFRONT_OAC_ID="$oac_id"
EOF
)

# Prepend variables to delete-all.sh, keeping the rest of the script
if [ -f delete-all.sh ]; then
    tmpfile=$(mktemp)
    echo "$delete_vars" > "$tmpfile"
    cat delete-all.sh >> "$tmpfile"
    mv "$tmpfile" delete-all.sh
else
    echo "$delete_vars" > delete-all.sh
fi

chmod +x delete-all.sh

echo ""
echo "All resource variables have been prepended to delete-all.sh for future cleanup automation."
