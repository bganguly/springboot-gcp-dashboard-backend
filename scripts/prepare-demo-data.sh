#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

START_TS="$(date +%s)"
DEMO_ORDER_COUNT="${DEMO_ORDER_COUNT:-4000000}"
SEED_BATCH_SIZE="${SEED_BATCH_SIZE:-500000}"
STEP_TS="$START_TS"

elapsed() { local now; now="$(date +%s)"; printf '%ss' "$((now - START_TS))"; }
step()     { STEP_TS="$(date +%s)"; printf '\n[%s] %s\n    ETA: %s\n' "$(elapsed)" "$1" "$2"; }
step_done() { local now; now="$(date +%s)"; printf '    Done in %ss; total elapsed %s.\n' "$((now - STEP_TS))" "$(elapsed)"; }

table_count() { psql_retry -Atqc "SELECT count(*) FROM $1"; }

print_summary() {
  printf '\n%s\n' "$1"
  psql_retry -P pager=off -x <<'SQL'
SELECT
  (SELECT count(*) FROM orders)                                    AS orders,
  (SELECT count(*) FROM customers)                                 AS customers,
  (SELECT count(*) FROM order_items)                               AS order_items,
  (SELECT count(*) FROM daily_summary)                             AS daily_summary,
  (SELECT count(*) FROM order_category_facts)                      AS order_category_facts,
  (SELECT count(*) FROM daily_customer_category_summary)           AS daily_customer_category_summary,
  (SELECT count(*) FROM daily_customer_token_category_summary)     AS daily_customer_token_category_summary,
  (SELECT count(*) FROM daily_customer_token_order_summary)        AS daily_customer_token_order_summary;
SQL
}

psql_retry() {
  local attempt=1 max="${PSQL_MAX_ATTEMPTS:-5}"
  while true; do
    psql "$DATABASE_URL" "$@" && return 0
    (( attempt >= max )) && return 1
    printf 'psql failed; retrying in 10s (%s/%s)...\n' "$attempt" "$max" >&2
    sleep 10
    attempt=$((attempt + 1))
  done
}

# Fast path: restore from a private GCS pg_dump snapshot.
# Set DEMO_SNAPSHOT_GCS_URI=gs://bucket/dash/demo.dump to enable.
# Falls back to full seed when unset, missing, or credentials unavailable.
# For fastest restore, run this script from a GCP Cloud Shell in the same
# region as Cloud SQL — same approach as the CloudShell path in the AWS README.
restore_from_snapshot() {
  local gcs_uri="${DEMO_SNAPSHOT_GCS_URI:-}"
  [[ -n "$gcs_uri" ]] || return 1
  command -v gsutil    >/dev/null 2>&1 || { echo "gsutil not found; skipping snapshot restore." >&2; return 1; }
  command -v pg_restore >/dev/null 2>&1 || { echo "pg_restore not found; skipping snapshot restore." >&2; return 1; }
  gsutil ls "$gcs_uri" >/dev/null 2>&1  || { echo "$gcs_uri not readable; skipping." >&2; return 1; }

  local dump_file
  dump_file="$(mktemp -t dash-demo.XXXXXX.dump)"
  echo "Downloading snapshot from $gcs_uri ..."
  if ! gsutil cp "$gcs_uri" "$dump_file"; then
    echo "gsutil cp failed; falling back to full seed." >&2; rm -f "$dump_file"; return 1
  fi
  echo "Restoring with pg_restore (parallel)..."
  if ! pg_restore --no-owner --no-privileges --clean --if-exists \
      --jobs "${PG_RESTORE_JOBS:-4}" --dbname "$DATABASE_URL" "$dump_file"; then
    echo "pg_restore reported errors; falling back to full seed." >&2; rm -f "$dump_file"; return 1
  fi
  rm -f "$dump_file"
  return 0
}

# Bake helper: dump the current database to GCS as a pg_dump custom-format snapshot.
# Usage: DEMO_SNAPSHOT_GCS_URI=gs://bucket/dash/demo.dump ./scripts/bake-demo-snapshot.sh
# (See scripts/bake-demo-snapshot.sh)

apply_dashboard_sql_migrations() {
  local migration
  while IFS= read -r migration; do
    printf '    applying %s\n' "${migration#"$ROOT_DIR"/}"
    psql_retry -v ON_ERROR_STOP=1 -f "$migration"
  done < <(find "$ROOT_DIR/src/main/resources/db/migration" -maxdepth 1 -name "V*.sql" -print | sort)
}

# Resolve DATABASE_URL from Cloud SQL Auth Proxy tunnel or environment.
if [[ -z "${DATABASE_URL:-}" ]]; then
  if DATABASE_URL="$("$ROOT_DIR/scripts/database-url.sh" 2>/dev/null)"; then
    echo "[prepare] Using DATABASE_URL from terraform output (needs Cloud SQL Auth Proxy or private network)."
  else
    echo "DATABASE_URL is not set and terraform output is unavailable." >&2
    echo "Run ./scripts/infra-up.sh first, or set DATABASE_URL manually." >&2
    exit 1
  fi
fi
export DATABASE_URL

if restore_from_snapshot; then
  print_summary "Data summary after snapshot restore:"
  printf '\n[%s] Restored from snapshot; read models are ready.\n' "$(elapsed)"
  exit 0
fi

step "1/5 Applying Flyway migrations." "< 1 min"
apply_dashboard_sql_migrations
step_done

step "2/5 Checking demo order volume." "< 10 sec"
ORDER_COUNT="$(table_count orders)"
echo "Found $ORDER_COUNT order(s)."
print_summary "Current data summary:"
step_done

if [[ "$ORDER_COUNT" == "0" ]]; then
  step "3/5 Seeding full demo data: $DEMO_ORDER_COUNT orders." "batched progress every $SEED_BATCH_SIZE rows"
  psql_retry \
    -v orders="$DEMO_ORDER_COUNT" \
    -v batch_size="$SEED_BATCH_SIZE" \
    -f "$ROOT_DIR/scripts/seed-large.sql"
  print_summary "Data summary after seeding:"
else
  step "3/5 Full demo order data already present." "< 10 sec"
  echo "Keeping existing orders and rebuilding read models."
fi
step_done

step "4/5 Applying dashboard SQL migrations and indexes." "1-10 min"
apply_dashboard_sql_migrations
step_done

step "5/5 Rebuilding dashboard read models." "batched by day with per-phase progress"
psql "$DATABASE_URL" -f "$ROOT_DIR/scripts/rebuild-dashboard-read-models.sql"
print_summary "Final data and read-model summary:"
step_done

printf '\n[%s] Demo data and dashboard read models are ready.\n' "$(elapsed)"
