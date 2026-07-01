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

step() { printf '\n[infra-up] %s\n' "$1"; }

# ── pulumi ────────────────────────────────────────────────────────────────────
if ! command -v pulumi >/dev/null 2>&1; then
  printf '\npulumi not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install pulumi/tap/pulumi
  else
    printf 'Install from: https://www.pulumi.com/docs/install/\nThen re-run.\n'; exit 1
  fi
fi

# ── node ──────────────────────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  printf '\nNode.js not found (needed for Pulumi TypeScript).\n'
  if command -v brew >/dev/null 2>&1; then
    brew install node
  else
    printf 'Install Node 18+ from: https://nodejs.org\nThen re-run.\n'; exit 1
  fi
fi

# ── gcloud ────────────────────────────────────────────────────────────────────
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud not found.\n'
  if command -v brew >/dev/null 2>&1; then
    brew install --cask google-cloud-sdk
    # shellcheck source=/dev/null
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install from: https://cloud.google.com/sdk/docs/install\nThen re-run.\n'; exit 1
  fi
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated with gcloud. Log in now? [y/N] '
  read -r do_login
  if [[ "$do_login" =~ ^[Yy]$ ]]; then
    gcloud auth login
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
    [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
  else
    printf 'Run: gcloud auth login\n'; exit 1
  fi
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nApplication Default Credentials needed for GCP provider. Set up now? [y/N] '
  read -r do_adc
  if [[ "$do_adc" =~ ^[Yy]$ ]]; then
    gcloud auth application-default login
  else
    printf 'Run: gcloud auth application-default login\n'; exit 1
  fi
fi
printf '\ngcloud: %s\n' "$ACTIVE_ACCOUNT"

# ── pulumi login ──────────────────────────────────────────────────────────────
# Each user logs into their own Pulumi Cloud account — stacks are isolated per org.
# You cannot affect anyone else's stack; they cannot affect yours.
PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
if [[ -z "$PULUMI_USER" ]]; then
  printf '\nNot logged in to Pulumi Cloud. Log in now? [y/N] '
  read -r do_pulumi_login
  if [[ "$do_pulumi_login" =~ ^[Yy]$ ]]; then
    pulumi login
    PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
    [[ -n "$PULUMI_USER" ]] || { printf 'Pulumi login did not complete.\n' >&2; exit 1; }
  else
    printf 'Run: pulumi login\n'; exit 1
  fi
fi
printf 'pulumi:  %s\n' "$PULUMI_USER"

# ── GCP config ────────────────────────────────────────────────────────────────
printf '\n=== GCP config ===\n'
DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT=$(ask "GCP project ID" \
  "https://console.cloud.google.com — or: gcloud projects list" \
  "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf 'Project ID required.\n' >&2; exit 1; }

DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION=$(ask "Region" \
  "Common: us-central1, us-east1, europe-west1" \
  "${DETECTED_REGION:-us-central1}")

# ── npm install ───────────────────────────────────────────────────────────────
step "npm install"
cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install

# ── stack (isolated per Pulumi user — cannot touch anyone else's) ─────────────
STACK="dev"
if ! pulumi stack ls 2>/dev/null | grep -q "^dev "; then
  step "creating stack (dev)"
  pulumi stack init "dev"
fi
pulumi stack select "dev"

pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"

# ── up ────────────────────────────────────────────────────────────────────────
step "pulumi up"
pulumi up

# ── write .env.gcp ────────────────────────────────────────────────────────────
step "writing .env.gcp"
CLOUD_SQL_INSTANCE=$(pulumi stack output cloudSqlInstance 2>/dev/null || true)
ARTIFACT_REGISTRY=$(pulumi stack output artifactRegistry  2>/dev/null || true)
BACKEND_URL=$(pulumi stack output backendUrl               2>/dev/null || true)
FRONTEND_URL=$(pulumi stack output frontendUrl             2>/dev/null || true)

cat > "$ENV_FILE" <<EOF
CLOUD_SQL_INSTANCE=${CLOUD_SQL_INSTANCE}
ARTIFACT_REGISTRY=${ARTIFACT_REGISTRY}
CLOUD_RUN_URL=${BACKEND_URL}
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
EOF

printf '\nInfra ready.\n'
printf '  Cloud SQL  : %s\n' "$CLOUD_SQL_INSTANCE"
printf '  Registry   : %s\n' "$ARTIFACT_REGISTRY"
printf '  Backend    : %s\n' "$BACKEND_URL"
printf '  Frontend   : %s\n' "$FRONTEND_URL"

# ── demo data ─────────────────────────────────────────────────────────────────
source "$ENV_FILE"

if [[ -n "${DEMO_SNAPSHOT_GCS_URI:-}" ]]; then
  printf '\nDEMO_SNAPSHOT_GCS_URI is set — restoring from snapshot...\n'
  DEMO_SNAPSHOT_GCS_URI="$DEMO_SNAPSHOT_GCS_URI" "$ROOT_DIR/scripts/prepare-demo-data.sh"
else
  printf '\n=== demo data ===\n'
  printf 'How would you like to populate the database?\n\n'
  printf '  1) In-region from Cloud Shell (fastest — avoids local network)\n'
  printf '  2) Full seed via prepare-demo-data.sh (15-25 min on db-f1-micro)\n'
  printf '  3) Skip — I will run prepare-demo-data.sh manually\n'
  printf '\nChoice [1/2/3]: '
  read -r choice

  case "$choice" in
    1)
      DB_URL=$("$ROOT_DIR/scripts/database-url.sh" 2>/dev/null || echo '<run ./scripts/database-url.sh>')
      printf '\nRun the following from GCP Cloud Shell in region %s:\n\n' "$GCP_REGION"
      printf '  sudo apt-get install -y postgresql-client-15\n'
      printf '  export DATABASE_URL='"'"'%s'"'"'\n' "$DB_URL"
      printf '  export BUCKET=<your-private-bucket>\n\n'
      printf '  # bake\n'
      printf '  pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" \\\n'
      printf '    | gsutil cp - "gs://$BUCKET/dash/demo.dump"\n\n'
      printf '  # restore (destructive)\n'
      printf '  gsutil cp "gs://$BUCKET/dash/demo.dump" ~/demo.dump\n'
      printf '  pg_restore --no-owner --no-privileges --clean --if-exists --jobs 4 \\\n'
      printf '    --dbname "$DATABASE_URL" ~/demo.dump && rm -f ~/demo.dump\n'
      ;;
    2)
      "$ROOT_DIR/scripts/prepare-demo-data.sh"
      ;;
    *)
      printf '\nSkipped. Run ./scripts/prepare-demo-data.sh when ready.\n'
      ;;
  esac
fi

printf '\nRemember to tear down when finished:\n'
printf '  ./scripts/infra-down.sh\n'
