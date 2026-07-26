#!/usr/bin/env bash
# Deploys APISIX + Zitadel to the sfg-gateway namespace.
# Run from repo root after kubeconfig is configured.
# Usage: bash helm/deploy.sh [--dry-run]
set -euo pipefail

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="--dry-run"

NAMESPACE="sfg-gateway"

# Hard-fail on missing gateway secrets BEFORE touching the cluster (N3, PR #33
# round-2 review). These guards used to sit at step 5/5, after the Zitadel
# and APISIX helm upgrades had already run — so a merge before
# ZIMMA_GATEWAY_SECRET exists as a GitHub Secret (this repo's own PR process
# lists creating it as a merge prerequisite; CI otherwise passes an empty
# string for a not-yet-created secret) aborted CD with the control plane
# already upgraded and zero routes reconciled, not a clean no-op. Checking
# env vars needs no cluster access, so there's no reason not to fail before
# step 1. Skipped entirely under --dry-run — dry-run needs neither secret.
if [[ -z "${DRY_RUN}" ]]; then
  # An unset var makes envsubst emit `X-Gateway-Secret: ` with nothing after
  # the colon, which YAML parses as a NULL value, not a missing key.
  # `kubectl apply` validates only against the ApisixRoute CRD's own
  # (permissive) OpenAPI schema and exits 0 — the CRD doesn't know
  # proxy-rewrite's plugin-level schema, which DOES reject a null header
  # value. That rejection happens downstream, when the ingress controller
  # tries to sync the CRD to the APISIX Admin API, so the observable failure
  # is the route silently failing to sync (calls to it 404, "route not
  # found") — not the clean 401 a missing secret would suggest.
  if [[ -z "${SUWALKA_AI_GATEWAY_SECRET:-}" ]]; then
    echo "  ERROR: SUWALKA_AI_GATEWAY_SECRET is unset. envsubst would emit a null" >&2
    echo "         X-Gateway-Secret value; kubectl apply exits 0 regardless, but the" >&2
    echo "         ingress controller then fails to sync the route to APISIX (proxy-rewrite" >&2
    echo "         rejects a null header) — calls 404, not a clean 401." >&2
    echo "         Set SUWALKA_AI_GATEWAY_SECRET before deploying." >&2
    exit 1
  fi
  if [[ -z "${ZIMMA_GATEWAY_SECRET:-}" ]]; then
    echo "  ERROR: ZIMMA_GATEWAY_SECRET is unset. envsubst would emit a null" >&2
    echo "         X-Gateway-Secret value; kubectl apply exits 0 regardless, but the" >&2
    echo "         ingress controller then fails to sync the route to APISIX (proxy-rewrite" >&2
    echo "         rejects a null header) — the POS SSO handoff 404s, not a clean 401." >&2
    echo "         Set ZIMMA_GATEWAY_SECRET before deploying." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Loudly print the kubectl context/cluster this run targets, BEFORE any write
# — dry-run or real. The incident this guards against: a dry-run was run with
# kubeconfig pointed at the wrong cluster (CMS Bangalore instead of Suwalka
# POS), and an ungated `kubectl apply -f k8s/namespaces.yaml` (see step 2
# below) created 3 real namespaces there. This banner is the tripwire — a
# human staring at the wrong context/server name before anything runs.
# ---------------------------------------------------------------------------
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '<no context set>')"
CURRENT_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '<unknown>')"
echo ">>> TARGET CONTEXT: ${CURRENT_CONTEXT}  SERVER: ${CURRENT_SERVER}"
if [[ -n "${DRY_RUN}" ]]; then
  echo ">>> --dry-run: this run performs ZERO writes to the cluster above, or any cluster."
fi

# ---------------------------------------------------------------------------
# Real-deploy confirmation gate. Skipped entirely under --dry-run (which is
# already a no-op against every cluster-mutating command below). For a REAL
# deploy, require ONE of:
#   - CONFIRM_CONTEXT=<expected-context-name> matching kubectl's current
#     context exactly — fails loudly on any mismatch. Non-interactive path,
#     e.g. a human deploying from their laptop.
#   - An interactive y/N-style prompt, when stdin is a TTY and CONFIRM_CONTEXT
#     is unset.
#   - The CD workflow's own workflow_dispatch "confirm: deploy" input IS
#     already a human confirmation gate (see .github/workflows/cd.yaml), and
#     that runner writes a fresh kubeconfig from the DOKS_KUBECONFIG secret
#     every run rather than relying on a possibly-stale local context — so a
#     non-interactive shell with CI=true (set automatically by GitHub
#     Actions) auto-passes without hanging.
#   - Anything else (non-interactive, no CONFIRM_CONTEXT, not CI) fails
#     loudly rather than silently deploying to whatever context happens to
#     be current.
# ---------------------------------------------------------------------------
if [[ -z "${DRY_RUN}" ]]; then
  if [[ -n "${CONFIRM_CONTEXT:-}" ]]; then
    if [[ "${CONFIRM_CONTEXT}" != "${CURRENT_CONTEXT}" ]]; then
      echo "  ERROR: CONFIRM_CONTEXT='${CONFIRM_CONTEXT}' does not match the current" >&2
      echo "         kubectl context '${CURRENT_CONTEXT}'. Refusing to deploy — this is" >&2
      echo "         exactly the misconfiguration that created real namespaces on the" >&2
      echo "         wrong cluster. Fix your kubeconfig context or CONFIRM_CONTEXT." >&2
      exit 1
    fi
    echo "    CONFIRM_CONTEXT matches current context '${CURRENT_CONTEXT}' — proceeding."
  elif [[ -t 0 ]]; then
    read -r -p "  About to deploy REAL changes to context '${CURRENT_CONTEXT}' (${CURRENT_SERVER}). Type 'yes' to continue: " CONFIRM_REPLY
    if [[ "${CONFIRM_REPLY}" != "yes" ]]; then
      echo "  Aborted: confirmation not given." >&2
      exit 1
    fi
  elif [[ "${CI:-}" == "true" ]]; then
    echo "    Non-interactive run with CI=true — the CD workflow's own workflow_dispatch"
    echo "    confirm input is the human gate for this deploy; proceeding without a"
    echo "    CONFIRM_CONTEXT match."
  else
    echo "  ERROR: refusing to deploy — stdin is not a TTY, CONFIRM_CONTEXT is unset, and" >&2
    echo "         CI=true is not set. Re-run interactively, or set" >&2
    echo "         CONFIRM_CONTEXT=<expected-context-name> to confirm the target cluster" >&2
    echo "         non-interactively." >&2
    exit 1
  fi
fi

echo "===> [1/5] Adding Helm repos"
# Canonical APISIX chart repo. charts.apiseven.com now 301-redirects here and the redirect
# can hang/fail on CI runners, so point directly at the GitHub Pages URL.
# --force-update makes re-adding an existing repo idempotent without masking real errors.
# Not gated by --dry-run: this only touches the local Helm repo cache, never a cluster.
helm repo add apisix  https://apache.github.io/apisix-helm-chart --force-update
helm repo add zitadel https://charts.zitadel.com                 --force-update
helm repo update

echo "===> [2/5] Ensuring namespaces (sfg-gateway, sfg-apps, sfg-labs)"
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f k8s/namespaces.yaml
else
  echo "    [dry-run] would run: kubectl apply -f k8s/namespaces.yaml"
fi

echo "===> [2b/5] Installing cert-manager (for Let's Encrypt TLS)"
# Installs CRDs + controller + webhook. Idempotent. The ClusterIssuer/Certificate are applied
# later (step 6) once the webhook is up and APISIX can solve the HTTP-01 challenge.
CERT_MANAGER_VERSION="v1.20.2"
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  echo "    Waiting for cert-manager to be ready..."
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
  kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
else
  echo "    [dry-run] would run: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  echo "    [dry-run] would wait on rollout status for cert-manager, cert-manager-webhook, cert-manager-cainjector"
fi

echo "===> [3/5] Installing Zitadel"
# Zitadel must be deployed before APISIX so its service is reachable for OIDC discovery
if [[ -z "${DRY_RUN}" ]]; then
  if ! kubectl -n "${NAMESPACE}" get secret zitadel-masterkey &>/dev/null; then
    echo "    Generating Zitadel master key secret..."
    kubectl -n "${NAMESPACE}" create secret generic zitadel-masterkey \
      --from-literal=masterkey="$(openssl rand -base64 32)"
  fi
else
  echo "    [dry-run] would run: kubectl -n ${NAMESPACE} create secret generic zitadel-masterkey ... (only if missing)"
fi

# `--dry-run` (from ${DRY_RUN} below) is Helm's own client-side dry run — it renders and
# simulates the release without creating/updating anything in the cluster.
helm upgrade --install sfg-zitadel zitadel/zitadel \
  --namespace "${NAMESPACE}" \
  --values helm/zitadel/values.yaml \
  --wait \
  --timeout 5m \
  ${DRY_RUN}

echo "===> [4/5] Installing APISIX + Ingress Controller"
if [[ -z "${DRY_RUN}" ]]; then
  if ! kubectl -n "${NAMESPACE}" get secret apisix-admin-key &>/dev/null; then
    echo "    Generating APISIX admin key secret..."
    kubectl -n "${NAMESPACE}" create secret generic apisix-admin-key \
      --from-literal=key="$(openssl rand -hex 16)"
  fi
  APISIX_ADMIN_KEY="$(kubectl -n "${NAMESPACE}" get secret apisix-admin-key \
    -o jsonpath='{.data.key}' | base64 -d)"
else
  echo "    [dry-run] would run: kubectl -n ${NAMESPACE} create secret generic apisix-admin-key ... (only if missing)"
  echo "    [dry-run] would read back the apisix-admin-key secret to wire into the Helm release"
fi

# `--dry-run` (from ${DRY_RUN} below) is Helm's own client-side dry run — see step 3 note.
helm upgrade --install sfg-apisix apisix/apisix \
  --namespace "${NAMESPACE}" \
  --values helm/apisix/values.yaml \
  ${APISIX_ADMIN_KEY:+--set "apisix.admin.credentials.admin=${APISIX_ADMIN_KEY}"} \
  ${APISIX_ADMIN_KEY:+--set "ingress-controller.config.apisix.adminKey=${APISIX_ADMIN_KEY}"} \
  --wait \
  --timeout 5m \
  ${DRY_RUN}

echo "===> [4b/5] Wiring v2 ingress controller (GatewayProxy + IngressClass)"
# The v2 controller ignores ingress-controller.config.apisix.* and instead needs a GatewayProxy
# that an IngressClass references. Without this, routes never reach APISIX (404 Route Not Found).
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f k8s/gateway-proxy.yaml
  kubectl apply -f k8s/ingressclass.yaml
else
  echo "    [dry-run] would run: kubectl apply -f k8s/gateway-proxy.yaml"
  echo "    [dry-run] would run: kubectl apply -f k8s/ingressclass.yaml"
fi

echo "===> [5/5] Applying service routes"
if [[ -z "${DRY_RUN}" ]]; then
  # Two route files embed a deploy-time secret as an envsubst placeholder
  # (X-Gateway-Secret injection, proving requests came from APISIX):
  #   routes/suwalka-ai-services.yaml -> ${SUWALKA_AI_GATEWAY_SECRET}
  #   routes/zimma-api.yaml           -> ${ZIMMA_GATEWAY_SECRET}
  # Substitute ONLY the file's own var so proxy-rewrite regex refs like $1
  # survive; every other route applies verbatim. A bare `kubectl apply` of
  # either file would ship the literal placeholder and 401 every affected
  # call. Both vars are hard-fail-checked up front, before step 1 — see the
  # guard at the top of this script (N3, PR #33 round-2 review) for why it
  # was moved there instead of living here.
  for route in routes/*.yaml; do
    case "${route}" in
      *suwalka-ai-services.yaml)
        envsubst '${SUWALKA_AI_GATEWAY_SECRET}' < "${route}" | kubectl apply -f -
        ;;
      *zimma-api.yaml)
        envsubst '${ZIMMA_GATEWAY_SECRET}' < "${route}" | kubectl apply -f -
        ;;
      *)
        kubectl apply -f "${route}"
        ;;
    esac
  done
  kubectl -n "${NAMESPACE}" get apisixroutes
else
  echo "    [dry-run] would apply the following route files (envsubst substitution noted where used):"
  for route in routes/*.yaml; do
    case "${route}" in
      *suwalka-ai-services.yaml)
        echo "      [dry-run] would run: envsubst '\${SUWALKA_AI_GATEWAY_SECRET}' < ${route} | kubectl apply -f -"
        ;;
      *zimma-api.yaml)
        echo "      [dry-run] would run: envsubst '\${ZIMMA_GATEWAY_SECRET}' < ${route} | kubectl apply -f -"
        ;;
      *)
        echo "      [dry-run] would run: kubectl apply -f ${route}"
        ;;
    esac
  done
fi

echo "===> [6/6] Applying TLS (cert-manager issuers + Zitadel certificate + ApisixTls)"
# Applied after routes so the apisix IngressClass + GatewayProxy exist for the HTTP-01 challenge.
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f k8s/cert-issuer.yaml
  kubectl apply -f k8s/zitadel-tls.yaml
  echo "    Certificate issuance is async; check with:"
  echo "      kubectl -n ${NAMESPACE} get certificate,order,challenge"
else
  echo "    [dry-run] would run: kubectl apply -f k8s/cert-issuer.yaml"
  echo "    [dry-run] would run: kubectl apply -f k8s/zitadel-tls.yaml"
fi

echo ""
echo "========================================================"
if [[ -z "${DRY_RUN}" ]]; then
  echo "  Gateway deployed successfully."
  echo ""
  echo "  APISIX pods:"
  kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=apisix 2>/dev/null || true
  echo ""
  echo "  Zitadel pods:"
  kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=zitadel 2>/dev/null || true
  echo ""
  echo "  Next: Configure your DNS to point to the master IP"
  echo "        Then run: bash tests/smoke/smoke-test.sh https://api.nma-india.in"
else
  echo "  Dry run complete — zero writes were made to context '${CURRENT_CONTEXT}' (${CURRENT_SERVER}),"
  echo "  or to any other cluster. Re-run without --dry-run to actually deploy."
fi
echo "========================================================"
