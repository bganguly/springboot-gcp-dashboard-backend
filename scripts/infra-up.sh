#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENV_FILE="$ROOT_DIR/.env.gcp"

: "${GCP_PROJECT:?Set GCP_PROJECT env var}"
: "${GCP_REGION:=${TF_VAR_gcp_region:-us-central1}}"

step() { printf '\n[infra-up] %s\n' "$1"; }

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

# ── terraform ─────────────────────────────────────────────────────────────────
cd "$INFRA_DIR"

step "terraform init"
terraform init -upgrade -input=false

step "terraform apply"
terraform apply \
  -var="gcp_project=${GCP_PROJECT}" \
  -var="gcp_region=${GCP_REGION}" \
  -input=false \
  -auto-approve

step "writing .env.gcp"
INSTANCE=$(terraform output -raw cloud_sql_instance)
REGISTRY=$(terraform output -raw artifact_registry)
RUN_URL=$(terraform output -raw cloud_run_url)

cat > "$ENV_FILE" <<EOF
CLOUD_SQL_INSTANCE=${INSTANCE}
ARTIFACT_REGISTRY=${REGISTRY}
CLOUD_RUN_URL=${RUN_URL}
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
EOF

printf '\nInfra ready.\n'
printf '  Cloud SQL instance : %s\n' "$INSTANCE"
printf '  Artifact Registry  : %s\n' "$REGISTRY"
printf '  Cloud Run URL      : %s\n' "$RUN_URL"

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
      printf '  # bake a snapshot\n'
      printf '  pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" \\\n'
      printf '    | gsutil cp - "gs://$BUCKET/dash/demo.dump"\n\n'
      printf '  # restore (destructive)\n'
      printf '  gsutil cp "gs://$BUCKET/dash/demo.dump" ~/demo.dump\n'
      printf '  pg_restore --no-owner --no-privileges --clean --if-exists --jobs 4 \\\n'
      printf '    --dbname "$DATABASE_URL" ~/demo.dump && rm -f ~/demo.dump\n\n'
      printf 'Or re-run with DEMO_SNAPSHOT_GCS_URI=gs://<bucket>/dash/demo.dump to restore automatically.\n'
      ;;
    2)
      "$ROOT_DIR/scripts/prepare-demo-data.sh"
      ;;
    *)
      printf '\nSkipped. Run ./scripts/prepare-demo-data.sh when ready.\n'
      ;;
  esac
fi
