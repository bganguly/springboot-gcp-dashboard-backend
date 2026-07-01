#!/usr/bin/env bash
# Emit DATABASE_URL from Pulumi stack output.
# Usage: DATABASE_URL=$(./scripts/database-url.sh)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/infra"

pulumi stack output databaseUrl --show-secrets
