# Dashboard Backend (Spring Boot + GCP)

Spring Boot 4 / Java 21 backend for the orders dashboard. Postgres via Flyway migrations, deployed to Cloud Run backed by Cloud SQL.

Sister repo: [dashboard-frontend](https://github.com/bganguly/dashboard-frontend)

## Local Dev

```bash
./scripts/local-dev.sh
```

Checks prerequisites, creates and seeds the database if needed (prompts before any writes), runs diagnostics, then starts on http://localhost:8080.

### Prerequisites

`local-dev.sh` checks all three and prints install instructions if anything is missing:

- **Java 21** — checked via [SDKMAN](https://sdkman.io/) (workaround for older Macs where `brew install java` triggers a 30–60 min source build)
- **Gradle** — also via SDKMAN (same reason)
- **Postgres** — started automatically via `brew services` if installed but not running

---

## GCP Deploy

### 1. Bring infra up

```bash
GCP_PROJECT=your-project-id ./scripts/infra-up.sh
```

Creates Cloud SQL (Postgres 15), Artifact Registry, and Cloud Run. Safe to rerun.

Expected timing:
- Existing healthy infra: under 2 minutes
- New Cloud SQL instance: 5–10 minutes

### 2. Prepare demo data

**Fastest — in-region from GCP Cloud Shell** (avoids local network entirely; run from Cloud Shell in the same region as Cloud SQL):

```bash
sudo apt-get install -y postgresql-client-15
export DATABASE_URL='<paste from ./scripts/database-url.sh on your local terminal>'
export BUCKET=<your-private-bucket>

# bake a snapshot
pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" \
  | gsutil cp - "gs://$BUCKET/dash/demo.dump"

# restore (destructive — drops and recreates objects)
gsutil cp "gs://$BUCKET/dash/demo.dump" ~/demo.dump
pg_restore --no-owner --no-privileges --clean --if-exists --jobs 4 \
  --dbname "$DATABASE_URL" ~/demo.dump && rm -f ~/demo.dump
```

**Fast — restore from a GCS snapshot** (maintainer only; falls back to full seed automatically if unset or inaccessible):

```bash
source .env.gcp
DEMO_SNAPSHOT_GCS_URI=gs://<bucket>/dash/demo.dump ./scripts/prepare-demo-data.sh
```

**Fallback — full seed** (runs automatically when no snapshot is available; 15–25 min on `db-f1-micro`):

```bash
source .env.gcp
./scripts/prepare-demo-data.sh
```

Applies migrations, seeds demo orders (when table is empty), rebuilds all read model rollups, and prints elapsed time and row counts per phase.

### 3. Deploy backend

```bash
./scripts/deploy.sh
```

Builds the Docker image, pushes to Artifact Registry, and updates Cloud Run via Terraform.

### 4. Start with Cloud SQL Auth Proxy (non-Cloud Run)

```bash
./scripts/start-dashboard.sh
```

Starts the Cloud SQL Auth Proxy tunnel and the Spring Boot app against it.

### 5. Tear down infra

```bash
GCP_PROJECT=your-project-id ./scripts/infra-down.sh
```

Destroys all GCP resources and removes `.env.gcp`.
