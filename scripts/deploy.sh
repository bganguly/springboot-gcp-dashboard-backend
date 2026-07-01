#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

# ── gcloud install ────────────────────────────────────────────────────────────
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
    # shellcheck source=/dev/null
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install it from: https://cloud.google.com/sdk/docs/install\nThen re-run this script.\n'
    exit 1
  fi
fi

# ── gcloud auth ───────────────────────────────────────────────────────────────
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated with gcloud. Log in now? [y/N] '
  read -r do_login
  if [[ "$do_login" =~ ^[Yy]$ ]]; then
    gcloud auth login
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
    [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
  else
    printf 'Exiting. Run: gcloud auth login\n'; exit 1
  fi
fi
printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

# ── seed known values ─────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
DETECTED_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
DETECTED_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"
DETECTED_TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)

# ── project + region ──────────────────────────────────────────────────────────
printf '\n=== deployment config ===\n'

GCP_PROJECT=$(ask \
  "GCP project ID" \
  "https://console.cloud.google.com — top nav project selector, or: gcloud projects list" \
  "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf '\nProject ID is required.\n' >&2; exit 1; }

GCP_REGION=$(ask \
  "Region" \
  "Common: us-central1, us-east1, europe-west1 — or: gcloud compute regions list" \
  "$DETECTED_REGION")

# ── Artifact Registry API + repo ──────────────────────────────────────────────
AR_STATE=$(gcloud services list \
  --project="$GCP_PROJECT" \
  --filter="name:artifactregistry.googleapis.com" \
  --format="value(state)" 2>/dev/null || true)

if [[ "$AR_STATE" != "ENABLED" ]]; then
  printf '\n  Artifact Registry API is not enabled for project %s.\n' "$GCP_PROJECT"
  printf '  Enable it now? [y/N] '
  read -r enable_ar
  if [[ "$enable_ar" =~ ^[Yy]$ ]]; then
    gcloud services enable artifactregistry.googleapis.com --project="$GCP_PROJECT"
    printf '  API enabled.\n'
  else
    printf '  Cannot deploy without Artifact Registry. Exiting.\n' >&2; exit 1
  fi
fi

DETECTED_REGISTRY=$(gcloud artifacts repositories list \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --format="value(name)" 2>/dev/null | head -1 || true)
DETECTED_REGISTRY="${DETECTED_REGISTRY##*/}"
DETECTED_REGISTRY="${DETECTED_REGISTRY:-${ARTIFACT_REGISTRY:-}}"

REGISTRY=$(ask \
  "Artifact Registry repo name" \
  "https://console.cloud.google.com/artifacts?project=${GCP_PROJECT} — or: gcloud artifacts repositories list --project=${GCP_PROJECT} --location=${GCP_REGION}" \
  "$DETECTED_REGISTRY")

if [[ -z "$REGISTRY" ]]; then
  printf '\n  No repo found. Create a new Docker repo? [y/N] '
  read -r create_repo
  if [[ "$create_repo" =~ ^[Yy]$ ]]; then
    printf '  Repo name: '
    read -r REGISTRY
    [[ -n "$REGISTRY" ]] || { printf 'Repo name required.\n' >&2; exit 1; }
    gcloud artifacts repositories create "$REGISTRY" \
      --repository-format=docker \
      --location="$GCP_REGION" \
      --project="$GCP_PROJECT"
    printf '  Repo "%s" created in %s.\n' "$REGISTRY" "$GCP_REGION"
  else
    printf 'Artifact Registry repo is required.\n' >&2; exit 1
  fi
fi

# ── tag ───────────────────────────────────────────────────────────────────────
TAG=$(ask "Image tag" "Leave blank to use the detected git hash" "$DETECTED_TAG")

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
printf '\nWill build and push:\n  %s\n' "$IMAGE"
printf 'Then deploy to Cloud Run in %s.\n' "$GCP_REGION"
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

# ── application default credentials (required by Terraform) ───────────────────
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nTerraform requires Application Default Credentials (separate from gcloud login).\n'
  printf 'Set them up now? [y/N] '
  read -r do_adc
  if [[ "$do_adc" =~ ^[Yy]$ ]]; then
    gcloud auth application-default login
  else
    printf 'Run: gcloud auth application-default login\n'; exit 1
  fi
fi

# ── deploy via terraform ──────────────────────────────────────────────────────
printf '\n=== deploying via Terraform ===\n'
cd "$ROOT_DIR/infra"
terraform apply \
  -var="gcp_project=${GCP_PROJECT}" \
  -var="gcp_region=${GCP_REGION}" \
  -var="backend_image=${IMAGE}" \
  -input=false -auto-approve

printf '\nDone. Backend URL:\n  '
terraform output -raw backend_url 2>/dev/null || \
  gcloud run services describe dashboard-backend \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null || true

printf '\n\nRemember to tear down when finished:\n'
printf '  GCP_PROJECT=%s ./scripts/infra-down.sh\n' "$GCP_PROJECT"
