#!/usr/bin/env bash
# Loads k8s/dashboards/grafana-dashboard.json into Azure Managed Grafana.
#
# The same dashboard the kind cluster uses: its queries are plain PromQL, so
# they run unchanged against Azure's managed Prometheus. The only edit is the
# data source id: locally it is "prometheus", in Managed Grafana Azure picks
# its own, so this looks it up and swaps it in.
#
# Usage: GRAFANA_NAME=amg-... RESOURCE_GROUP=rg-policyledger scripts/import-grafana-dashboard.sh
# (both values are Terraform outputs: grafana_name and resource_group)
set -euo pipefail

: "${GRAFANA_NAME:?}" "${RESOURCE_GROUP:?}"
cd "$(dirname "$0")/.."

az extension add --name amg --only-show-errors >/dev/null 2>&1 || true

uid=$(az grafana data-source list -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" -o json |
  python3 -c 'import json,sys; ds=[d for d in json.load(sys.stdin) if d["type"]=="prometheus"]; print(ds[0]["uid"])')
echo "Prometheus data source uid: ${uid}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed "s|\"uid\": \"prometheus\"|\"uid\": \"${uid}\"|g" k8s/dashboards/grafana-dashboard.json > "$tmp"

az grafana dashboard create -g "$RESOURCE_GROUP" -n "$GRAFANA_NAME" \
  --definition "$tmp" --overwrite true --only-show-errors -o none
echo "Dashboard imported. Open the Grafana URL (terraform output grafana_url) -> Dashboards -> PolicyLedger."
