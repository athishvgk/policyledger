#!/usr/bin/env bash
# Deploys PolicyLedger to the AKS cluster kubectl is currently pointed at.
# Used both by hand and by .github/workflows/deploy-azure.yml.
#
# Required env: ACR_NAME KEY_VAULT_NAME TENANT_ID CSI_CLIENT_ID IMAGE_TAG
set -euo pipefail

: "${ACR_NAME:?}" "${KEY_VAULT_NAME:?}" "${TENANT_ID:?}" "${CSI_CLIENT_ID:?}" "${IMAGE_TAG:?}"
cd "$(dirname "$0")/.."

IMAGE="${ACR_NAME}.azurecr.io/policyledger-api:${IMAGE_TAG}"

echo "== namespace + config"
kubectl apply -f k8s/00-namespace.yaml -f k8s/01-configmap.yaml

echo "== Key Vault -> Kubernetes Secret"
sed -e "s|__KEY_VAULT_NAME__|${KEY_VAULT_NAME}|" \
    -e "s|__TENANT_ID__|${TENANT_ID}|" \
    -e "s|__CSI_CLIENT_ID__|${CSI_CLIENT_ID}|" \
    k8s-azure/secret-sync.yaml | kubectl apply -f -
kubectl rollout status deployment/secret-sync -n policyledger --timeout=180s
kubectl get secret policyledger-secret -n policyledger >/dev/null

echo "== app (image: ${IMAGE})"
# Skipped on purpose:
#   02-secret.yaml            local-only Secret; Key Vault supplies it here
#   09/10 (ServiceMonitor,    need the Prometheus Operator CRDs, which this
#   PrometheusRule)           cluster does not install. Azure uses
#                             k8s-azure/servicemonitor.yaml and the alert
#                             in terraform-azure/monitoring.tf instead.
for f in k8s/*.yaml; do
  case "$f" in
    k8s/02-secret.yaml|k8s/09-servicemonitor.yaml|k8s/10-prometheus-rule.yaml) continue ;;
    k8s/06-api-deployment.yaml)
      # The local manifest points at a kind-loaded image with
      # imagePullPolicy: Never. Swap in the ACR image and drop that line.
      sed -e "s|image: policyledger-api:local|image: ${IMAGE}|" \
          -e '/^ *imagePullPolicy: Never$/d' "$f" | kubectl apply -f -
      ;;
    *) kubectl apply -f "$f" ;;
  esac
done

kubectl rollout status deployment/postgres -n policyledger --timeout=180s
kubectl rollout status deployment/policyledger-api -n policyledger --timeout=180s

echo "== metrics scrape config"
# The CRD comes from the AKS monitor_metrics add-on. If it is not there yet
# (add-on still starting), say so instead of failing the whole deploy.
if kubectl get crd servicemonitors.azmonitoring.coreos.com >/dev/null 2>&1; then
  kubectl apply -f k8s-azure/servicemonitor.yaml
else
  echo "WARNING: azmonitoring ServiceMonitor CRD not found; metrics add-on not ready. Re-run later:"
  echo "  kubectl apply -f k8s-azure/servicemonitor.yaml"
fi
echo "== done"
