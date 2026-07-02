#!/usr/bin/env bash
# Seeds demo data by restoring an S3 pg_dump snapshot directly into Cloud SQL.
# Temporarily enables public IP and whitelists the local machine's IP on port 5432
# (avoids Cloud SQL Auth Proxy port 3307 which is often blocked by corporate networks).
# Usage: seed-via-proxy.sh <GCP_PROJECT> <GCP_REGION>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GCP_PROJECT="${1:?GCP_PROJECT required}"
GCP_REGION="${2:-us-central1}"
SQL_INSTANCE="dash-db"
DUMP_FILE=""
LOCAL_IP=""

cleanup() {
  [[ -n "$DUMP_FILE" && -f "$DUMP_FILE" ]] && rm -f "$DUMP_FILE"
  printf '\nRemoving Cloud SQL public IP and authorized network...\n'
  gcloud sql instances patch "$SQL_INSTANCE" \
    --no-assign-ip --authorized-networks="" \
    --project "$GCP_PROJECT" --quiet 2>/dev/null || true
  printf 'Done.\n'
}
trap cleanup EXIT

# ── tool checks ───────────────────────────────────────────────────────────────
for tool in aws pg_restore; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '\n%s not found.\n' "$tool"
    if command -v brew >/dev/null 2>&1; then
      case "$tool" in
        aws)        brew install awscli ;;
        pg_restore) brew install libpq && export PATH="$(brew --prefix libpq)/bin:$PATH" ;;
      esac
    else
      printf 'Install %s and re-run.\n' "$tool"; exit 1
    fi
  fi
done

# ── get local public IP ───────────────────────────────────────────────────────
LOCAL_IP=$(curl -sf https://checkip.amazonaws.com || curl -sf https://api.ipify.org)
[[ -n "$LOCAL_IP" ]] || { printf 'Could not determine local public IP.\n' >&2; exit 1; }
printf '\nLocal public IP: %s\n' "$LOCAL_IP"

# ── enable public IP + whitelist ──────────────────────────────────────────────
printf 'Enabling public IP and whitelisting %s on %s...\n' "$LOCAL_IP" "$SQL_INSTANCE"
gcloud sql instances patch "$SQL_INSTANCE" \
  --assign-ip \
  --authorized-networks="${LOCAL_IP}/32" \
  --project "$GCP_PROJECT" --quiet
printf 'Public IP enabled.\n'

# ── wait for public IP to be assigned ─────────────────────────────────────────
for i in $(seq 1 20); do
  PUBLIC_IP=$(gcloud sql instances describe "$SQL_INSTANCE" \
    --project "$GCP_PROJECT" \
    --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || true)
  [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] && break
  sleep 3
done
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || { printf 'Public IP not assigned.\n' >&2; exit 1; }
printf 'Cloud SQL public IP: %s\n' "$PUBLIC_IP"

# ── get credentials from Pulumi ───────────────────────────────────────────────
cd "$ROOT_DIR/infra"
RAW_DB_URL=$(pulumi stack output databaseUrl --show-secrets 2>/dev/null || true)
[[ -n "$RAW_DB_URL" ]] || { printf '\nCould not read databaseUrl from Pulumi stack.\n' >&2; exit 1; }
_NO_SCHEME="${RAW_DB_URL#postgresql://}"
_USERINFO="${_NO_SCHEME%%@*}"
DB_USER="${_USERINFO%%:*}"
DB_PASS="${_USERINFO#*:}"
DB_NAME="${_NO_SCHEME##*/}"

export PGPASSWORD="$DB_PASS"
DIRECT_DB_URL="postgresql://${DB_USER}:${DB_PASS}@${PUBLIC_IP}:5432/${DB_NAME}?sslmode=require"

# ── restore from S3 snapshot ──────────────────────────────────────────────────
S3_URI="${DEMO_SNAPSHOT_S3_URI:-s3://bikram-nextjs-subsecond-fetch-with-websockets/dash/demo.dump}"
printf '\nDownloading snapshot from %s...\n' "$S3_URI"
DUMP_FILE="$(mktemp -t dash-demo.XXXXXX.dump)"
aws s3 cp "$S3_URI" "$DUMP_FILE"

printf 'Restoring with pg_restore (parallel jobs: %s)...\n' "${PG_RESTORE_JOBS:-4}"
pg_restore \
  --no-owner --no-privileges \
  --clean --if-exists \
  --jobs "${PG_RESTORE_JOBS:-4}" \
  --dbname "$DIRECT_DB_URL" \
  "$DUMP_FILE"

printf '\nRestore complete.\n'
