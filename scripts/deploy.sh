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
  printf '\nNot authenticated with gcloud. Log in now? [Y/n] '
  read -r do_login
  if [[ -z "$do_login" || "$do_login" =~ ^[Yy]$ ]]; then
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
_GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)
_BUILD_TS=$(date +%Y%m%d%H%M%S)
DETECTED_TAG="${_GIT_HASH:+${_GIT_HASH}-}${_BUILD_TS}"

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
  printf '  Enable it now? [Y/n] '
  read -r enable_ar
  if [[ -z "$enable_ar" || "$enable_ar" =~ ^[Yy]$ ]]; then
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
  printf '\n  No repo found. Create a new Docker repo? [Y/n] '
  read -r create_repo
  if [[ -z "$create_repo" || "$create_repo" =~ ^[Yy]$ ]]; then
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
  printf 'Run infra-up.sh first? [Y/n] '
  read -r run_infra
  if [[ -z "$run_infra" || "$run_infra" =~ ^[Yy]$ ]]; then
    GCP_PROJECT="$GCP_PROJECT" GCP_REGION="$GCP_REGION" "$ROOT_DIR/scripts/infra-up.sh"
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  fi
fi

# ── confirm ───────────────────────────────────────────────────────────────────
printf '\nWill build and push:\n  %s\n' "$IMAGE"
printf 'Then deploy to Cloud Run in %s.\n' "$GCP_REGION"
printf '\nProceed? [Y/n] '
read -r yn
[[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

# ── build & push ──────────────────────────────────────────────────────────────
if docker info >/dev/null 2>&1; then
  printf '\n[1/3] configuring docker auth...\n'
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

  printf '[2/3] building image...\n'
  docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"

  printf '[3/3] pushing image...\n'
  docker push "$IMAGE"
else
  printf '\nDocker not available — building via Cloud Build (no local Docker needed)...\n'
  gcloud services enable cloudbuild.googleapis.com --project "$GCP_PROJECT"
  gcloud builds submit \
    --tag "$IMAGE" \
    --project "$GCP_PROJECT" \
    "$ROOT_DIR"
fi

# ── application default credentials (required by Pulumi GCP provider) ─────────
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nApplication Default Credentials needed for the GCP provider. Set up now? [Y/n] '
  read -r do_adc
  if [[ -z "$do_adc" || "$do_adc" =~ ^[Yy]$ ]]; then
    gcloud auth application-default login
  else
    printf 'Run: gcloud auth application-default login\n'; exit 1
  fi
fi

# ── deploy via pulumi ─────────────────────────────────────────────────────────
printf '\n=== deploying via Pulumi ===\n'
cd "$ROOT_DIR/infra"
npm install --prefer-offline 2>/dev/null || npm install
pulumi stack select "dev" 2>/dev/null || pulumi stack init "dev"
pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"
pulumi config set backendImage "$IMAGE"
pulumi up --yes

BACKEND_URL=$(pulumi stack output backendUrl 2>/dev/null || \
  gcloud run services describe dash-backend \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null || true)

printf '\nDone. Backend URL:\n  %s\n' "$BACKEND_URL"

# ── optional seed ─────────────────────────────────────────────────────────────
_CUSTOMERS=$(curl -sf "${BACKEND_URL}/api/customers" --max-time 10 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "-1")

if [[ "$_CUSTOMERS" == "0" ]]; then
  printf '\nDatabase is empty. Seed demo data now? [y/N] '
  read -r do_seed
  if [[ "$do_seed" =~ ^[Yy]$ ]]; then
    "$ROOT_DIR/scripts/seed-via-proxy.sh" "$GCP_PROJECT" "$GCP_REGION"
  fi
elif [[ "$_CUSTOMERS" == "-1" ]]; then
  printf '\n(Could not reach backend to check seed status — skipping seed prompt.)\n'
fi

printf '\nRemember to tear down when finished:\n'
printf '  GCP_PROJECT=%s ./scripts/infra-down.sh\n' "$GCP_PROJECT"
