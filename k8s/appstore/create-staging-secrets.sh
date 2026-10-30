#!/usr/bin/env bash
# One-time (or rotate-by-rerunning-after-delete) creation of the two
# Secrets this chart expects to already exist — see templates/secrets.yaml
# for why they're not templated by Helm/ArgoCD. Reads values straight out
# of ../../.env.staging (gitignored, never touches this script's stdout).
#
# Usage:
#   ./create-staging-secrets.sh [namespace]
#
# namespace defaults to appstore-staging (global.namespace in values-staging.yaml).
set -euo pipefail

NAMESPACE="${1:-appstore-staging}"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.env.staging"

if [ ! -f "$ENV_FILE" ]; then
  echo "Not found: $ENV_FILE" >&2
  exit 1
fi

# Export every KEY=value line from .env.staging into this shell's
# environment, same mechanism the Makefile uses for other targets.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# SMTP_USER/SMTP_PASSWORD/SMTP_FROM_EMAIL are deliberately NOT required
# here — docker-compose.staging.yml itself defaults them to empty and
# gates mail delivery entirely on SMTP_ENABLED (default false; see that
# file's comment on the backend service). An empty SMTP_* is a valid,
# supported "mail disabled" configuration, not a missing value.
missing=0
for var in DB_USER DB_PASSWORD DB_NAME WORKER_DB_PASSWORD \
           KEYCLOAK_DB_USER KEYCLOAK_DB_PASSWORD KEYCLOAK_DB_NAME \
           KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_CLIENT_SECRET \
           SECRET_KEY CREDENTIAL_ENCRYPTION_KEY GIT_ACCESS_TOKEN \
           LTI_SESSION_SECRET; do
  if [ -z "${!var:-}" ]; then
    echo "Missing or empty in $ENV_FILE: $var" >&2
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  echo "Aborting — fill in the missing value(s) above in .env.staging first." >&2
  exit 1
fi

kubectl create secret generic appstore-core-secrets \
  --namespace="$NAMESPACE" \
  --from-literal=DB_USER="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=DB_NAME="$DB_NAME" \
  --from-literal=WORKER_DB_PASSWORD="$WORKER_DB_PASSWORD" \
  --from-literal=KEYCLOAK_DB_USER="$KEYCLOAK_DB_USER" \
  --from-literal=KEYCLOAK_DB_PASSWORD="$KEYCLOAK_DB_PASSWORD" \
  --from-literal=KEYCLOAK_DB_NAME="$KEYCLOAK_DB_NAME" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
  --from-literal=KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET" \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=CREDENTIAL_ENCRYPTION_KEY="$CREDENTIAL_ENCRYPTION_KEY" \
  --from-literal=GIT_ACCESS_TOKEN="$GIT_ACCESS_TOKEN" \
  --from-literal=LTI_SESSION_SECRET="$LTI_SESSION_SECRET" \
  --from-literal=SMTP_USER="${SMTP_USER:-}" \
  --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
  --from-literal=SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# VITE_KEYCLOAK_CLIENT_SECRET is not in .env.staging today (that file
# only carries KEYCLOAK_CLIENT_SECRET, the backend's confidential-client
# secret) — the frontend uses a public client in realm-export.json.j2
# (no client secret), so this is usually empty. Override by exporting it
# yourself before running this script if that ever changes.
kubectl create secret generic appstore-frontend-secrets \
  --namespace="$NAMESPACE" \
  --from-literal=VITE_KEYCLOAK_CLIENT_SECRET="${VITE_KEYCLOAK_CLIENT_SECRET:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets created/updated in namespace $NAMESPACE."
