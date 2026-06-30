# Dashboard Backend (Spring Boot + GCP)

Spring Boot 4 / Java 21 backend for the orders dashboard. Postgres via Flyway migrations, deployed to Cloud Run backed by Cloud SQL.

Sister repo: [dashboard-frontend](https://github.com/bganguly/dashboard-frontend)

## Local Dev

### Prerequisites

- Java 21
- Gradle via [SDKMAN](https://sdkman.io/) — do **not** use `brew install gradle` (pulls in a 30-60 min source-build chain):

```bash
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk install gradle
```

- Postgres running locally

### Quick Start (first time)

```bash
# 1. Generate the Gradle wrapper
gradle wrapper

# 2. Create and seed the database (100 k rows; default is 4 M, too slow locally)
createdb dashboard_perf
psql -d dashboard_perf -f src/main/resources/db/migration/V1__initial_schema.sql
psql -d dashboard_perf -f src/main/resources/db/migration/V2__daily_summary.sql
psql -d dashboard_perf -f src/main/resources/db/migration/V3__indexes_and_read_models.sql
psql -d dashboard_perf -v orders=100000 -f scripts/seed-large.sql
psql -d dashboard_perf -f scripts/rebuild-dashboard-read-models.sql

# 3. Verify — prints Java version, Postgres readiness, row counts, Flyway state
DATABASE_URL="jdbc:postgresql://localhost:5432/dashboard_perf?user=$(whoami)" ./scripts/diagnose.sh

# 4. Start
DATABASE_URL="jdbc:postgresql://localhost:5432/dashboard_perf?user=$(whoami)" ./gradlew bootRun
```

Listens on http://localhost:8080. The frontend proxies `/api/*` here in dev.

---

## GCP Deploy

### Prerequisites

- `gcloud` CLI authenticated (`gcloud auth login`)
- Terraform >= 1.5
- Docker

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

- Applies Flyway migrations
- Seeds demo orders when the table is empty
- Rebuilds all dashboard read models
- Prints elapsed time and row-count summary for each phase

Expected timing on `db-f1-micro`: 15–25 minutes for the 4 M order seed.

#### Fast path: restore from a GCS snapshot (maintainer only)

```bash
# bake the current database into a private GCS snapshot
DEMO_SNAPSHOT_GCS_URI=gs://<your-bucket>/dash/demo.dump ./scripts/bake-demo-snapshot.sh

# restore instead of re-seeding
DEMO_SNAPSHOT_GCS_URI=gs://<your-bucket>/dash/demo.dump ./scripts/prepare-demo-data.sh
```

The bucket is private. Developers without the URI fall back to the full seed automatically — nothing to configure.

#### In-region bake/restore (fastest — avoids the local network entirely)

Run from **GCP Cloud Shell** in the same region as Cloud SQL to keep traffic off your local link.

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
