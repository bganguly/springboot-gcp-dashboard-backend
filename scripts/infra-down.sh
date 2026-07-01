#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENV_FILE="$ROOT_DIR/.env.gcp"

PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
[[ -n "$PULUMI_USER" ]] || { printf 'Not logged in to Pulumi. Run: pulumi login\n' >&2; exit 1; }

printf '\nThis will destroy all GCP resources in your stack (%s/dashboard/dev).\n' "$PULUMI_USER"
printf 'Proceed? [Y/n] '
read -r yn
[[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install
pulumi stack select "dev"
pulumi destroy

rm -f "$ENV_FILE"
printf '\n[infra-down] done — all GCP resources destroyed and .env.gcp removed.\n'
