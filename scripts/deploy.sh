#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env.gcp"

# ── helpers ───────────────────────────────────────────────────────────────────
prompt() {
  local label="$1" default="$2"
  if [[ -n "$default" ]]; then
    printf '  %s [%s]: ' "$label" "$default"
  else
    printf '  %s: ' "$label"
  fi
  read -r input
  echo "${input:-$default}"
}

# ── detect GCP context ────────────────────────────────────────────────────────
printf '\n=== detecting GCP context ===\n'

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

if command -v gcloud >/dev/null 2>&1; then
  DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
  DETECTED_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
  DETECTED_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"

  if [[ -n "$DETECTED_PROJECT" ]]; then
    DETECTED_REGISTRY=$(gcloud artifacts repositories list \
      --project="$DETECTED_PROJECT" \
      --location="$DETECTED_REGION" \
      --format="value(name)" 2>/dev/null | head -1 || true)
    DETECTED_REGISTRY="${DETECTED_REGISTRY##*/}"
  fi
  DETECTED_REGISTRY="${DETECTED_REGISTRY:-${ARTIFACT_REGISTRY:-}}"
else
  printf '  gcloud not found — values will need to be entered manually\n'
  DETECTED_PROJECT="${GCP_PROJECT:-}"
  DETECTED_REGION="${GCP_REGION:-us-central1}"
  DETECTED_REGISTRY="${ARTIFACT_REGISTRY:-}"
fi

DETECTED_TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)

[[ -n "$DETECTED_PROJECT"  ]] && printf '  project   : %s\n' "$DETECTED_PROJECT"
[[ -n "$DETECTED_REGION"   ]] && printf '  region    : %s\n' "$DETECTED_REGION"
[[ -n "$DETECTED_REGISTRY" ]] && printf '  registry  : %s\n' "$DETECTED_REGISTRY"
printf '  tag       : %s\n' "$DETECTED_TAG"

# ── confirm or override ───────────────────────────────────────────────────────
printf '\n=== confirm or override ===\n'

GCP_PROJECT=$(prompt "GCP project"             "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf 'GCP project is required.\n' >&2; exit 1; }

GCP_REGION=$(prompt  "region"                  "$DETECTED_REGION")
REGISTRY=$(prompt    "Artifact Registry repo"  "$DETECTED_REGISTRY")
[[ -n "$REGISTRY" ]] || { printf 'Registry repo name is required.\n' >&2; exit 1; }

TAG=$(prompt         "image tag"               "$DETECTED_TAG")

IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/backend:${TAG}"

# ── check infra ───────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  printf '\n.env.gcp not found — infra may not be up.\n'
  printf 'Run infra-up.sh first? [y/N] '
  read -r run_infra
  if [[ "$run_infra" =~ ^[Yy]$ ]]; then
    GCP_PROJECT="$GCP_PROJECT" GCP_REGION="$GCP_REGION" "$ROOT_DIR/scripts/infra-up.sh"
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  fi
fi

# ── confirm ───────────────────────────────────────────────────────────────────
printf '\nWill build and push:\n'
printf '  %s\n' "$IMAGE"
printf '\nThen apply Terraform to update Cloud Run in %s.\n' "$GCP_REGION"
printf '\nProceed? [y/N] '
read -r yn
[[ "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

# ── build & push ──────────────────────────────────────────────────────────────
printf '\n[1/3] configuring docker auth...\n'
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

printf '[2/3] building image...\n'
docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"

printf '[3/3] pushing image...\n'
docker push "$IMAGE"

# ── deploy via terraform ──────────────────────────────────────────────────────
printf '\n=== deploying via Terraform ===\n'
cd "$ROOT_DIR/infra"
terraform apply \
  -var="gcp_project=${GCP_PROJECT}" \
  -var="gcp_region=${GCP_REGION}" \
  -var="backend_image=${IMAGE}" \
  -input=false -auto-approve

printf '\nDone. Backend URL:\n'
terraform output -raw backend_url 2>/dev/null || \
  gcloud run services describe dashboard-backend \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null || true

printf '\n⚠️  Remember to run ./scripts/infra-down.sh when finished to tear down all GCP resources.\n'
