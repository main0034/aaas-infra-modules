#!/usr/bin/env bash
#
# AaaS Phase 0 bootstrap.
#
# Creates the pieces that cannot be managed by the pipeline itself:
#   - Terraform state storage account
#   - two service principals (plan = read-only, apply = write)
#   - GitHub OIDC federated credentials for both
#   - RBAC assignments
#
# This is deliberately a script you read and run yourself rather than
# something an agent executes. It grants real privilege on your tenant.
#
# Prerequisites: az CLI, logged in (`az login`), Owner on the subscription.
#
# Usage:
#   ./bootstrap.sh <subscription-id>
#
# Optional overrides:
#   BUDGET_AMOUNT=20 BUDGET_EMAIL=you@example.com ./bootstrap.sh <subscription-id>
#
# Cost of running this script: effectively nothing. Service principals and
# federated credentials are free, and the state storage account holds a few
# hundred KB. Spend starts when the first deployment PR is merged.
#
set -euo pipefail

SUBSCRIPTION_ID="${1:?Usage: ./bootstrap.sh <subscription-id>}"
GITHUB_OWNER="main0034"
DEPLOY_REPO="aaas-deployments"
LOCATION="swedencentral"
PREFIX="aaas"
ENVIRONMENT="dev"

# Budget alert. Expected steady-state spend for one running deployment is
# ~17-20 USD/month, so 20 is deliberately tight: it fires if a second
# deployment is left running, which is exactly the case worth catching.
BUDGET_AMOUNT="${BUDGET_AMOUNT:-20}"
BUDGET_EMAIL="${BUDGET_EMAIL:-martiningeson@gmail.com}"

RG_STATE="rg-${PREFIX}-tfstate"
CONTAINER_STATE="tfstate"
# SA_STATE is derived from the canonical subscription GUID and is therefore
# computed after the subscription is resolved, not here.

# Default branch. This is NOT cosmetic: it becomes the subject of the OIDC
# federated credential, and Azure matches that string exactly. A mismatch
# fails at token exchange with "no matching federated identity record found",
# which reads like a permissions problem rather than a typo.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"

AUDIENCE="api://AzureADTokenExchange"

###############################################################################
# OIDC subject format
#
# GitHub repositories created after 15 July 2026 use "immutable subject
# claims": the owner and repository numeric IDs are embedded in the sub claim
# and CANNOT be removed, even with claim customisation.
#
#   old: repo:owner/repo:pull_request
#   new: repo:owner@40392502/repo@1328777566:pull_request
#
# The '@' separator is safe because it cannot appear in a GitHub username or
# repository name. Azure matches the subject as an exact string, so a
# credential written in the old format simply never matches, and the failure
# (AADSTS700213) reads like a configuration mistake rather than a format
# change.
#
# We therefore ask GitHub what the IDs are rather than assuming either format.
###############################################################################

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> Resolving GitHub owner/repo IDs for the OIDC subject"
  OWNER_ID=$(gh api "repos/${GITHUB_OWNER}/${DEPLOY_REPO}" --jq '.owner.id' 2>/dev/null || echo "")
  REPO_ID=$(gh api "repos/${GITHUB_OWNER}/${DEPLOY_REPO}" --jq '.id' 2>/dev/null || echo "")
else
  OWNER_ID=""
  REPO_ID=""
  echo "==> gh CLI not available or not authenticated; falling back to the legacy subject format."
  echo "    If the repo uses immutable claims this WILL fail at token exchange."
  echo "    Set OWNER_ID and REPO_ID manually to override."
fi

OWNER_ID="${OWNER_ID_OVERRIDE:-$OWNER_ID}"
REPO_ID="${REPO_ID_OVERRIDE:-$REPO_ID}"

if [[ -n "${OWNER_ID}" && -n "${REPO_ID}" ]]; then
  REPO_SEGMENT="repo:${GITHUB_OWNER}@${OWNER_ID}/${DEPLOY_REPO}@${REPO_ID}"
  echo "    Using immutable subject format: ${REPO_SEGMENT}"
else
  REPO_SEGMENT="repo:${GITHUB_OWNER}/${DEPLOY_REPO}"
  echo "    Using legacy subject format: ${REPO_SEGMENT}"
fi

SUBJECT_PR="${REPO_SEGMENT}:pull_request"

# The apply and destroy jobs declare `environment: dev`. When a job references
# a GitHub Environment, the OIDC subject becomes ':environment:<name>' and NOT
# ':ref:refs/heads/<branch>' - the environment claim replaces the ref claim
# rather than supplementing it.
#
# This is easy to get wrong because the workflow still only runs on the
# default branch, so a branch-scoped credential looks correct and fails with
# AADSTS700213 as though it were a permissions problem.
#
# Both credentials are created: the environment one is what apply/destroy
# actually present today, and the branch one keeps any future non-environment
# job on the default branch working.
SUBJECT_ENV="${REPO_SEGMENT}:environment:${ENVIRONMENT}"
SUBJECT_BRANCH="${REPO_SEGMENT}:ref:refs/heads/${DEFAULT_BRANCH}"

echo "==> Selecting subscription: ${SUBSCRIPTION_ID}"

# Accept either a name or an ID, then immediately re-read the canonical GUID.
# `az account set` is happy with a display name, but ARM REST URLs are not -
# passing a name here used to fail much later with a confusing
# "subscription not found" from the budget call, long after the resource
# group had been created.
if ! az account set --subscription "${SUBSCRIPTION_ID}" 2>/dev/null; then
  echo "ERROR: could not select subscription '${SUBSCRIPTION_ID}'."
  echo "Available subscriptions:"
  az account list --query "[].{name:name, id:id, tenant:tenantId, state:state}" --output table
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '[:space:]')
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '[:space:]')

if ! [[ "${SUBSCRIPTION_ID}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "ERROR: resolved subscription id '${SUBSCRIPTION_ID}' is not a GUID. Aborting."
  exit 1
fi

echo "    Name:   ${SUBSCRIPTION_NAME}"
echo "    ID:     ${SUBSCRIPTION_ID}"
echo "    Tenant: ${TENANT_ID}"

# Resource providers must be registered before their resources can be created.
# On a fresh subscription several of these are not, and the resulting errors
# name the provider rather than the cause.
echo "==> Ensuring resource providers are registered (no-op if already done)"
for rp in Microsoft.Storage Microsoft.DBforPostgreSQL Microsoft.App \
          Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.Network \
          Microsoft.ManagedIdentity Microsoft.Consumption; do
  state=$(az provider show --namespace "$rp" --query registrationState -o tsv 2>/dev/null || echo "NotFound")
  if [ "$state" != "Registered" ]; then
    echo "    registering ${rp} (currently ${state})"
    az provider register --namespace "$rp" --output none
  fi
done
echo "    Registration runs in the background and can take a few minutes."
echo "    If a later step fails with MissingSubscriptionRegistration, wait and re-run."

# Deterministic, globally-unique storage account name. Derived from the
# canonical GUID so that re-running the script always targets the same
# account rather than creating a new one.
SA_STATE="st${PREFIX}tfstate$(printf '%s' "${SUBSCRIPTION_ID}" | shasum | cut -c1-8)"

###############################################################################
# 1. State backend
###############################################################################
echo "==> Creating state resource group and storage account"

az group create \
  --name "${RG_STATE}" \
  --location "${LOCATION}" \
  --tags owner=martin costCenter=poc managedBy=bootstrap \
  --output none

az storage account create \
  --name "${SA_STATE}" \
  --resource-group "${RG_STATE}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

# Versioning and soft delete: cheap insurance against a corrupted state file.
az storage account blob-service-properties update \
  --account-name "${SA_STATE}" \
  --resource-group "${RG_STATE}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  --output none

az storage container create \
  --name "${CONTAINER_STATE}" \
  --account-name "${SA_STATE}" \
  --auth-mode login \
  --output none

SA_ID=$(az storage account show --name "${SA_STATE}" --resource-group "${RG_STATE}" --query id -o tsv)

###############################################################################
# 2. Service principals
#
# Two identities on purpose. The plan job runs on untrusted PR content and
# should never be able to change anything. Retrofitting this split later is
# awkward, so it is done from the start.
###############################################################################

create_sp () {
  local app_name="$1"
  local existing
  existing=$(az ad app list --display-name "${app_name}" --query "[0].appId" -o tsv)
  if [[ -n "${existing}" ]]; then
    echo "${existing}"
    return
  fi
  az ad app create --display-name "${app_name}" --query appId -o tsv
}

add_fed_cred () {
  local app_id="$1" cred_name="$2" subject="$3" existing_subject

  existing_subject=$(az ad app federated-credential list --id "${app_id}" \
    --query "[?name=='${cred_name}'].subject | [0]" -o tsv 2>/dev/null || echo "")

  if [[ -n "${existing_subject}" ]]; then
    if [[ "${existing_subject}" == "${subject}" ]]; then
      echo "    federated credential ${cred_name} already correct, skipping"
      return
    fi
    # Subjects are matched exactly by Entra, so a stale one is not merely
    # redundant - it is the thing that will keep failing. Replace it.
    echo "    federated credential ${cred_name} has stale subject, replacing"
    echo "      was: ${existing_subject}"
    echo "      now: ${subject}"
    az ad app federated-credential delete \
      --id "${app_id}" --federated-credential-id "${cred_name}" --output none
  fi
  az ad app federated-credential create --id "${app_id}" --parameters "{
    \"name\": \"${cred_name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"description\": \"AaaS ${cred_name}\",
    \"audiences\": [\"${AUDIENCE}\"]
  }" --output none
}

echo "==> Creating plan service principal (read-only)"
PLAN_APP_ID=$(create_sp "sp-${PREFIX}-plan-${ENVIRONMENT}")
az ad sp create --id "${PLAN_APP_ID}" --output none 2>/dev/null || true
PLAN_SP_ID=$(az ad sp show --id "${PLAN_APP_ID}" --query id -o tsv)
add_fed_cred "${PLAN_APP_ID}" "github-pull-request" "${SUBJECT_PR}"

echo "==> Creating apply service principal (write)"
APPLY_APP_ID=$(create_sp "sp-${PREFIX}-apply-${ENVIRONMENT}")
az ad sp create --id "${APPLY_APP_ID}" --output none 2>/dev/null || true
APPLY_SP_ID=$(az ad sp show --id "${APPLY_APP_ID}" --query id -o tsv)
add_fed_cred "${APPLY_APP_ID}" "github-environment-${ENVIRONMENT}" "${SUBJECT_ENV}"
add_fed_cred "${APPLY_APP_ID}" "github-${DEFAULT_BRANCH}" "${SUBJECT_BRANCH}"

###############################################################################
# 3. RBAC
###############################################################################
echo "==> Assigning roles (this can take a minute to propagate)"

assign () {
  az role assignment create \
    --assignee-object-id "$1" \
    --assignee-principal-type ServicePrincipal \
    --role "$2" \
    --scope "$3" \
    --output none 2>/dev/null || echo "    (already assigned: $2)"
}

SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Plan: read the world, write only the state blob.
assign "${PLAN_SP_ID}" "Reader" "${SUB_SCOPE}"
assign "${PLAN_SP_ID}" "Storage Blob Data Contributor" "${SA_ID}"

# Apply: Contributor to create resources, User Access Administrator because
# the module creates Key Vault role assignments.
assign "${APPLY_SP_ID}" "Contributor" "${SUB_SCOPE}"
assign "${APPLY_SP_ID}" "User Access Administrator" "${SUB_SCOPE}"
assign "${APPLY_SP_ID}" "Storage Blob Data Contributor" "${SA_ID}"

###############################################################################
# 4. Budget alert
#
# The realistic way to overspend on this POC is not a mis-sized resource - the
# allowed SKUs are all cheap - it is forgetting that a deployment is still
# running. A Postgres Flexible Server bills per hour whether or not anything
# connects to it.
#
# Alerts only. Azure budgets do not stop anything; they email you. Treat the
# 50% notification as the useful one - by 100% you have already spent it.
###############################################################################
echo "==> Creating ${BUDGET_AMOUNT} USD/month budget alert"

BUDGET_START=$(date -u +%Y-%m-01T00:00:00Z)
BUDGET_END="$(( $(date -u +%Y) + 5 ))-$(date -u +%m)-01T00:00:00Z"

az rest \
  --method PUT \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Consumption/budgets/${PREFIX}-poc-budget?api-version=2023-05-01" \
  --headers "Content-Type=application/json" \
  --body "{
    \"properties\": {
      \"category\": \"Cost\",
      \"amount\": ${BUDGET_AMOUNT},
      \"timeGrain\": \"Monthly\",
      \"timePeriod\": {
        \"startDate\": \"${BUDGET_START}\",
        \"endDate\": \"${BUDGET_END}\"
      },
      \"notifications\": {
        \"actual_50\": {
          \"enabled\": true,
          \"operator\": \"GreaterThanOrEqualTo\",
          \"threshold\": 50,
          \"contactEmails\": [\"${BUDGET_EMAIL}\"],
          \"thresholdType\": \"Actual\"
        },
        \"actual_80\": {
          \"enabled\": true,
          \"operator\": \"GreaterThanOrEqualTo\",
          \"threshold\": 80,
          \"contactEmails\": [\"${BUDGET_EMAIL}\"],
          \"thresholdType\": \"Actual\"
        },
        \"actual_100\": {
          \"enabled\": true,
          \"operator\": \"GreaterThanOrEqualTo\",
          \"threshold\": 100,
          \"contactEmails\": [\"${BUDGET_EMAIL}\"],
          \"thresholdType\": \"Actual\"
        },
        \"forecast_100\": {
          \"enabled\": true,
          \"operator\": \"GreaterThanOrEqualTo\",
          \"threshold\": 100,
          \"contactEmails\": [\"${BUDGET_EMAIL}\"],
          \"thresholdType\": \"Forecasted\"
        }
      }
    }
  }" \
  --output none

echo "    Budget alert set: ${BUDGET_AMOUNT} USD/month -> ${BUDGET_EMAIL}"
echo "    Forecast alert included, so you hear about it before the money is spent."

###############################################################################
# 5. Output the GitHub configuration
###############################################################################
cat <<EOF

================================================================================
Bootstrap complete.

Set these as repository VARIABLES (not secrets) on ${GITHUB_OWNER}/${DEPLOY_REPO}:

  gh variable set AZURE_TENANT_ID       --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${TENANT_ID}"
  gh variable set AZURE_SUBSCRIPTION_ID --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${SUBSCRIPTION_ID}"
  gh variable set AZURE_CLIENT_ID_PLAN  --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${PLAN_APP_ID}"
  gh variable set AZURE_CLIENT_ID_APPLY --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${APPLY_APP_ID}"
  gh variable set TFSTATE_RG            --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${RG_STATE}"
  gh variable set TFSTATE_SA            --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${SA_STATE}"
  gh variable set TFSTATE_CONTAINER     --repo ${GITHUB_OWNER}/${DEPLOY_REPO} --body "${CONTAINER_STATE}"

These are identifiers, not credentials - there is no secret to leak, which is
the entire point of OIDC.

State backend values for backend.hcl:
  resource_group_name  = "${RG_STATE}"
  storage_account_name = "${SA_STATE}"
  container_name       = "${CONTAINER_STATE}"
================================================================================
EOF
