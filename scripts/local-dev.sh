#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ORDERS="${ORDERS:-100000}"
DB="dashboard_perf"
DB_URL="jdbc:postgresql://localhost:5432/${DB}?user=$(whoami)"

# ── helpers ───────────────────────────────────────────────────────────────────
fail() { printf '\nERROR: %s\n\n' "$*" >&2; exit 1; }
ok()   { printf '  %-18s %s\n' "$1" "$2"; }

# ── prerequisites ─────────────────────────────────────────────────────────────
printf '\n=== prerequisites ===\n'

command -v java >/dev/null 2>&1 || fail "Java 21 not found.
  Install via SDKMAN (workaround for older Macs — brew triggers a 30-60 min source build):
    curl -s https://get.sdkman.io | bash
    source ~/.sdkman/bin/sdkman-init.sh
    sdk install java 21-tem"

JAVA_VER=$(java -version 2>&1 | head -1)
[[ "$JAVA_VER" =~ 21 ]] || fail "Java 21 required. Found: $JAVA_VER
  Install via SDKMAN:  sdk install java 21-tem"
ok "java" "$JAVA_VER"

command -v gradle >/dev/null 2>&1 || fail "Gradle not found.
  Install via SDKMAN (workaround for older Macs — brew triggers a 30-60 min source build):
    sdk install gradle"
ok "gradle" "$(gradle --version 2>/dev/null | grep '^Gradle ' | head -1)"

command -v psql >/dev/null 2>&1 || fail "psql not found — install Postgres (brew install postgresql@15)"
ok "psql" "$(psql --version)"

if ! pg_isready >/dev/null 2>&1; then
  printf '  postgres: not running — starting...\n'
  if command -v brew >/dev/null 2>&1; then
    brew services start postgresql@15 2>/dev/null || brew services start postgresql 2>/dev/null || true
    sleep 2
  fi
  pg_isready >/dev/null 2>&1 || fail "Postgres did not start. Install: brew install postgresql@15"
fi
ok "postgres" "ready"

# ── gradle wrapper ────────────────────────────────────────────────────────────
if [[ ! -f "$ROOT_DIR/gradlew" ]]; then
  printf '\ngradlew not found — generating...\n'
  gradle wrapper
fi

# ── database setup ────────────────────────────────────────────────────────────
DB_EXISTS=$(psql -lqt 2>/dev/null | cut -d'|' -f1 | tr -d ' ' | grep -x "$DB" || true)

if [[ -z "$DB_EXISTS" ]]; then
  printf '\n=== first-time database setup ===\n'
  printf 'Will:\n'
  printf '  1. createdb %s\n' "$DB"
  printf '  2. apply V1/V2/V3 migrations\n'
  printf '  3. seed %s orders\n' "$ORDERS"
  printf '  4. rebuild all read model rollups\n'
  printf '\n  Set ORDERS=N to change the seed size (default 100k; production uses 4M).\n'
  printf '\nProceed? [y/N] '
  read -r yn
  [[ "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

  printf '\n[1/4] creating database...\n'
  createdb "$DB"

  printf '[2/4] applying migrations...\n'
  psql -d "$DB" -f src/main/resources/db/migration/V1__initial_schema.sql
  psql -d "$DB" -f src/main/resources/db/migration/V2__daily_summary.sql
  psql -d "$DB" -f src/main/resources/db/migration/V3__indexes_and_read_models.sql

  printf '[3/4] seeding %s orders...\n' "$ORDERS"
  psql -d "$DB" -v orders="$ORDERS" -f scripts/seed-large.sql

  printf '[4/4] rebuilding read model rollups...\n'
  psql -d "$DB" -f scripts/rebuild-dashboard-read-models.sql

  printf '\nSetup complete.\n'
else
  ok "database" "$DB (exists — skipping setup)"
fi

# ── diagnostics ───────────────────────────────────────────────────────────────
printf '\n=== diagnostics ===\n'
DATABASE_URL="$DB_URL" ./scripts/diagnose.sh

# ── start ─────────────────────────────────────────────────────────────────────
printf '\n=== starting backend :8080 ===\n'
DATABASE_URL="$DB_URL" ./gradlew bootRun
