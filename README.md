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

### 1. Bring infra up and seed data

```bash
GCP_PROJECT=your-project-id ./scripts/infra-up.sh
```

Creates Cloud SQL (Postgres 15), Artifact Registry, and Cloud Run, then prompts for how to seed the database:

- **Option 1 — in-region from Cloud Shell** (fastest): prints the exact commands to run in GCP Cloud Shell to avoid local network overhead
- **Option 2 — full seed** (15–25 min on `db-f1-micro`): runs `prepare-demo-data.sh` directly
- **Option 3 — skip**: seed manually later with `./scripts/prepare-demo-data.sh`

Set `DEMO_SNAPSHOT_GCS_URI=gs://<bucket>/dash/demo.dump` before running to restore from a snapshot automatically without being prompted.

Safe to rerun. Expected timing: existing healthy infra under 2 minutes; new Cloud SQL instance 5–10 minutes.

### 2. Deploy backend

```bash
./scripts/deploy.sh
```

Detects GCP project, region, and Artifact Registry repo from `gcloud` config (seeded from `.env.gcp` if present). Prompts to confirm or override each, then builds, pushes, and deploys via Terraform. Prints the Cloud Run URL when done.

### 3. Start with Cloud SQL Auth Proxy (non-Cloud Run)

```bash
./scripts/start-dashboard.sh
```

Starts the Cloud SQL Auth Proxy tunnel and the Spring Boot app against it.

### 4. Tear down infra

```bash
GCP_PROJECT=your-project-id ./scripts/infra-down.sh
```

Destroys all GCP resources and removes `.env.gcp`.
