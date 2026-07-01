#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENV_FILE="$ROOT_DIR/.env.gcp"

# ── helpers ───────────────────────────────────────────────────────────────────
ask() {
  local label="$1" hint="$2" default="$3"
  printf '\n  %s\n' "$label" >&2
  [[ -n "$hint"    ]] && printf '  → %s\n' "$hint" >&2
  [[ -n "$default" ]] && printf '  [detected: %s]\n' "$default" >&2
  printf '  > ' >&2
  read -r input
  echo "${input:-$default}"
}

# ── pulumi login ──────────────────────────────────────────────────────────────
PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
[[ -n "$PULUMI_USER" ]] || { printf 'Not logged in to Pulumi. Run: pulumi login\n' >&2; exit 1; }

# ── seed known values ─────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
DETECTED_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
DETECTED_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"

# ── project + region ──────────────────────────────────────────────────────────
printf '\n=== infra teardown config ===\n'

GCP_PROJECT=$(ask \
  "GCP project ID" \
  "gcloud config get-value project  — or: gcloud projects list" \
  "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf '\nProject ID is required.\n' >&2; exit 1; }

GCP_REGION=$(ask \
  "Region" \
  "Common: us-central1, us-east1, europe-west1" \
  "$DETECTED_REGION")

# ── confirm ───────────────────────────────────────────────────────────────────
printf '\nThis will destroy ALL GCP resources in project %s (%s).\n' "$GCP_PROJECT" "$GCP_REGION"
printf 'Stack: %s/dashboard/dev\n' "$PULUMI_USER"
printf '\nThis removes: Cloud Run services, Cloud SQL, VPC, Secret Manager secrets, Artifact Registry, IAM bindings.\n'
printf '\nProceed? [Y/n] '
read -r yn
[[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

# ── destroy ───────────────────────────────────────────────────────────────────
cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install

pulumi stack select "dev"
pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"

pulumi destroy --yes

rm -f "$ENV_FILE"
printf '\n[infra-down] done — all GCP resources destroyed and .env.gcp removed.\n'
