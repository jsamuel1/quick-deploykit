#!/usr/bin/env bash
#
# Deploys the full Amazon Quick Suite kit: both CDK stacks in one pass.
#
#   1. AmazonQuickSuiteStack         - Quick Suite subscription + IAM Identity Center
#   2. QuickDesktopCognitoProxyStack - Cognito OIDC provider + proxy for Quick on desktop
#
# MFA is required on the desktop user pool (enforced in CDK and via context).
# Region is pinned to ap-southeast-2; the AWS profile defaults to the ct-primary
# account but can be overridden with AWS_PROFILE.
#
# Usage:
#   scripts/deploy.sh                 # deploy both stacks
#   AWS_PROFILE=other scripts/deploy.sh
#
set -euo pipefail

# --- Configuration (override via environment) ---------------------------------
export AWS_PROFILE="${AWS_PROFILE:-sauhsoj+ct-primary-Admin}"
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"   # overrides any inherited AWS_REGION
export CDK_DOCKER="${CDK_DOCKER:-finch}"            # container runtime for Lambda bundling

# Resolve repo root (this script lives in <repo>/scripts).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Profile: $AWS_PROFILE   Region: $AWS_REGION   Docker: $CDK_DOCKER"

# --- 1. Ensure the container runtime is up (needed to bundle the Python Lambda) ---
if command -v finch >/dev/null 2>&1 && [ "$CDK_DOCKER" = "finch" ]; then
  status="$(finch vm status 2>/dev/null || echo Unknown)"
  if [ "$status" != "Running" ]; then
    echo "==> Finch VM is '$status' - starting it..."
    finch vm start 2>/dev/null || finch vm init
  fi
  echo "==> Finch VM: $(finch vm status 2>/dev/null)"
fi

# --- 2. Verify credentials and resolve the target account ---------------------
ACCOUNT_ID="$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)"
echo "==> Deploying to account $ACCOUNT_ID / $AWS_REGION"

# --- 3. Install dependencies and build ----------------------------------------
echo "==> Installing npm dependencies..."
npm install

echo "==> Building (tsc)..."
npm run build

# --- 4. Bootstrap (idempotent) ------------------------------------------------
echo "==> Bootstrapping CDK environment (idempotent)..."
npx cdk bootstrap "aws://${ACCOUNT_ID}/${AWS_REGION}" --profile "$AWS_PROFILE"

# --- 5. Deploy both stacks ----------------------------------------------------
# mfaRequired is also enforced in lib/app.ts; passed here for explicitness.
echo "==> Deploying all stacks..."
npx cdk deploy --all \
  --profile "$AWS_PROFILE" \
  --require-approval never \
  -c mfaRequired=true

# --- 6. Show desktop OIDC outputs + next steps --------------------------------
echo ""
echo "==> QuickDesktopCognitoProxyStack outputs (use these in the Quick console):"
aws cloudformation describe-stacks \
  --stack-name QuickDesktopCognitoProxyStack \
  --profile "$AWS_PROFILE" \
  --query "Stacks[0].Outputs" --output table || true

cat <<'EOF'

==> Deploy complete. Remaining manual steps:

  1. Quick Suite admin group membership (if not already done):
     add your IAM Identity Center user to the QUICK_SUITE_ADMIN group.

  2. Configure Amazon Quick "extension access" + create the extension in the
     Quick management console using the outputs above (ClientId, IssuerUrl,
     AuthEndpoint, TokenEndpoint, JwksUri). This step has no API and must be
     done in the console.

  3. Provision desktop users into the Cognito pool from IAM Identity Center:
       AWS_PROFILE=$AWS_PROFILE AWS_REGION=$AWS_REGION \
         python3 scripts/sync_users.py --source idc

  4. Launch Amazon Quick on desktop -> "Enterprise sign-in" and sign in with
     the invited email + temporary password (MFA enrollment required).

Note: the desktop auth proxy API Gateway is PUBLIC (no CIDR allowlist). To
restrict it later, redeploy with: -c allowedCidrs='["1.2.3.0/24"]'
EOF
