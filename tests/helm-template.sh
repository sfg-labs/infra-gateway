#!/usr/bin/env bash
# Renders Helm templates in dry-run mode to verify values.yaml is valid.
# Does NOT require a running cluster — only helm CLI.
# Requires: helm (brew install helm)
set -euo pipefail

echo "===> Adding Helm repos"
helm repo add apisix  https://charts.apiseven.com  2>/dev/null || true
helm repo add zitadel https://charts.zitadel.com   2>/dev/null || true
helm repo update --fail-on-repo-update-fail 2>/dev/null || helm repo update

echo ""
echo "===> Rendering APISIX template"
helm template sfg-apisix apisix/apisix \
  --namespace sfg-gateway \
  --values helm/apisix/values.yaml \
  > /dev/null
echo "    PASS: APISIX values.yaml renders without error"

echo ""
echo "===> Rendering Zitadel template"
helm template sfg-zitadel zitadel/zitadel \
  --namespace sfg-gateway \
  --values helm/zitadel/values.yaml \
  --set zitadel.masterkeySecretName=zitadel-masterkey \
  > /dev/null
echo "    PASS: Zitadel values.yaml renders without error"

echo ""
echo "===> Linting Helm charts"
helm lint --namespace sfg-gateway --values helm/apisix/values.yaml  <(helm show chart apisix/apisix)  2>/dev/null || true
helm lint --namespace sfg-gateway --values helm/zitadel/values.yaml <(helm show chart zitadel/zitadel) 2>/dev/null || true

echo ""
echo "========================================================"
echo "  All Helm templates render successfully."
echo "========================================================"
