# Dashboard Backend (Spring Boot + GCP)

Spring Boot 4 / Java 21 backend for the orders dashboard. Postgres via Flyway migrations, deployed to Cloud Run backed by Cloud SQL.

Sister repo: [dashboard-frontend](https://github.com/bganguly/dashboard-frontend)

## Local Dev

```bash
./scripts/local-dev.sh
```

Checks prerequisites, creates and seeds the database if needed (prompts before any writes), runs diagnostics, then starts on http://localhost:8080.

### Prerequisites

- **Java 21** — install via [SDKMAN](https://sdkman.io/) (workaround for older Macs: `brew install java` can trigger a 30–60 min source build):

  ```bash
  curl -s "https://get.sdkman.io" | bash
  source "$HOME/.sdkman/bin/sdkman-init.sh"
  sdk install java 21-tem
  ```

- **Gradle** — also via SDKMAN (same reason — do **not** use `brew install gradle`):

  ```bash
  sdk install gradle
  ```

- **Postgres** running locally:

  ```bash
  brew install postgresql@15
  brew services start postgresql@15
  ```

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

```bash
source .env.gcp
./scripts/prepare-demo-data.sh
```

Applies migrations, seeds demo orders (when table is empty), rebuilds all read model rollups, and prints elapsed time and row counts per phase.

Expected timing on `db-f1-micro`: 15–25 minutes for the 4 M order seed.

#### Fast path: restore from a GCS snapshot (maintainer only)

```bash
DEMO_SNAPSHOT_GCS_URI=gs://<your-bucket>/dash/demo.dump ./scripts/prepare-demo-data.sh
```

Falls back to full seed automatically when the URI is unset or inaccessible — nothing to configure for developers without the bucket.

#### In-region bake/restore (fastest — avoids local network)

Run from **GCP Cloud Shell** in the same region as Cloud SQL:

```bash
sudo apt-get install -y postgresql-client-15

export DATABASE_URL='<paste from ./scripts/database-url.sh on your local terminal>'
export BUCKET=<your-private-bucket>

# bake: stream directly to GCS (no local file)
pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" \
  | gsutil cp - "gs://$BUCKET/dash/demo.dump"

# restore
gsutil cp "gs://$BUCKET/dash/demo.dump" ~/demo.dump
pg_restore --no-owner --no-privileges --clean --if-exists --jobs 4 \
  --dbname "$DATABASE_URL" ~/demo.dump
rm -f ~/demo.dump
```

`pg_restore --clean --if-exists` drops and recreates objects — intended for refreshing a demo, destructive otherwise.

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
