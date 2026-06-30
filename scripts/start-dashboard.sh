#!/usr/bin/env bash
# Start dashboard with Cloud SQL Auth Proxy providing the database tunnel.
# Requires: cloud-sql-proxy binary in PATH, gcloud auth, .env.gcp from infra-up.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_GCP="$ROOT_DIR/.env.gcp"

[[ -f "$ENV_GCP" ]] || { echo ".env.gcp not found — run ./scripts/infra-up.sh first." >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_GCP"

command -v cloud-sql-proxy >/dev/null 2>&1 || {
  echo "cloud-sql-proxy not found. Install: https://cloud.google.com/sql/docs/postgres/sql-proxy" >&2; exit 1
}

PROXY_PORT="${PROXY_PORT:-5432}"

echo "[start] Starting Cloud SQL Auth Proxy for ${CLOUD_SQL_INSTANCE} on :${PROXY_PORT}..."
cloud-sql-proxy "${CLOUD_SQL_INSTANCE}" --port "${PROXY_PORT}" &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null; exit' INT TERM

sleep 2  # give proxy a moment to establish the connection

DATABASE_URL="$(DATABASE_URL="dummy" "$ROOT_DIR/scripts/database-url.sh" 2>/dev/null | \
  sed "s|@[^:]*:[0-9]*/|@127.0.0.1:${PROXY_PORT}/|")" || true

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Could not derive DATABASE_URL; set it manually." >&2
  kill "$PROXY_PID" 2>/dev/null
  exit 1
fi

export DATABASE_URL
echo "[start] DATABASE_URL ready; starting backend on :8080"
cd "$ROOT_DIR"
./gradlew bootRun
