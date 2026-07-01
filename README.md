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

> **When finished:** run `GCP_PROJECT=your-project-id ./scripts/infra-down.sh` to destroy all GCP resources and remove `.env.gcp`.

### Deploy

```bash
./scripts/deploy.sh
```

Detects GCP project, region, and Artifact Registry repo from `gcloud` config. Prompts to confirm or override, then builds, pushes, and deploys via Terraform. If infra is not yet up, offers to run `infra-up.sh` first (which also handles demo data seeding). Prints the Cloud Run URL and a reminder to tear down when done.

To bring up infra and seed data independently (without deploying): `GCP_PROJECT=your-project-id ./scripts/infra-up.sh`

### Start with Cloud SQL Auth Proxy (non-Cloud Run)

```bash
./scripts/start-dashboard.sh
```

Starts the Cloud SQL Auth Proxy tunnel and the Spring Boot app against it.

### Tear down

```bash
GCP_PROJECT=your-project-id ./scripts/infra-down.sh
```

Destroys all GCP resources and removes `.env.gcp`.
