#!/usr/bin/env bash
# Configures APISIX routes via Admin API for local Docker testing.
# Equivalent to the K8s ApisixRoute CRDs but using the REST Admin API.
# Run after: docker compose up -d && wait for APISIX to be healthy.
# Usage: bash docker/apisix/setup-routes.sh
set -euo pipefail

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"  # default dev key only
ZITADEL_URL="${ZITADEL_URL:-http://zitadel:8080}"
# OIDC client credentials — override via env for non-local environments.
# In bearer_only mode these are not used for JWT validation, only for the
# APISIX plugin schema. In production, inject from a Kubernetes Secret.
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-local-gateway}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-local-gateway-secret}"
# MOCK_BACKEND_URL available for manual override if needed
: "${MOCK_BACKEND_URL:-http://mock-backend:80}"

wait_for_apisix() {
  echo "===> Waiting for APISIX Admin API (up to 3 min)..."
  for i in $(seq 1 60); do
    if curl -sf "${ADMIN_URL}/apisix/admin/routes" -H "X-API-KEY: ${ADMIN_KEY}" > /dev/null 2>&1; then
      echo "    APISIX ready (attempt ${i})."
      return
    fi
    sleep 3
    echo "    ... attempt ${i}/60"
  done
  echo "ERROR: APISIX Admin API not reachable after 3 minutes"; exit 1
}

create_upstream() {
  local id="$1" url="$2"
  echo "--> Upstream: ${id} → ${url}"
  curl -sf -X PUT "${ADMIN_URL}/apisix/admin/upstreams/${id}" \
    -H "X-API-KEY: ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"roundrobin\",
      \"nodes\": {\"${url}\": 1}
    }" > /dev/null
}

create_route() {
  local id="$1" name="$2" host="$3" prefix="$4" upstream_id="$5" protected="$6"
  echo "--> Route: ${name} (${host}${prefix}*) → upstream/${upstream_id} [auth=${protected}]"

  local plugins="{
    \"request-id\": {\"header_name\": \"X-Request-Id\", \"include_in_response\": true},
    \"response-rewrite\": {\"headers\": {\"set\": {\"X-Gateway\": \"sfg-labs\"}}}
  }"

  if [[ "${protected}" == "true" ]]; then
    plugins="{
      \"openid-connect\": {
        \"discovery\": \"${ZITADEL_URL}/.well-known/openid-configuration\",
        \"client_id\": \"${OIDC_CLIENT_ID}\",
        \"client_secret\": \"${OIDC_CLIENT_SECRET}\",
        \"bearer_only\": true,
        \"token_signing_alg_values_expected\": \"RS256\",
        \"set_userinfo_header\": true,
        \"userinfo_header_name\": \"X-Userinfo\",
        \"timeout\": 5
      },
      \"request-id\": {\"header_name\": \"X-Request-Id\", \"include_in_response\": true},
      \"limit-req\": {\"rate\": 100, \"burst\": 50, \"rejected_code\": 429, \"key_type\": \"var\", \"key\": \"remote_addr\"},
      \"response-rewrite\": {\"headers\": {\"set\": {\"X-Gateway\": \"sfg-labs\"}}}
    }"
  fi

  curl -sf -X PUT "${ADMIN_URL}/apisix/admin/routes/${id}" \
    -H "X-API-KEY: ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"host\": \"${host}\",
      \"uri\": \"${prefix}*\",
      \"upstream_id\": \"${upstream_id}\",
      \"plugins\": ${plugins}
    }" > /dev/null
}

create_health_route() {
  local id="$1" name="$2" host="$3" upstream_id="$4"
  echo "--> Route: ${name} (${host}/health) → upstream/${upstream_id} [health, no auth]"
  curl -sf -X PUT "${ADMIN_URL}/apisix/admin/routes/${id}" \
    -H "X-API-KEY: ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"host\": \"${host}\",
      \"uri\": \"/health\",
      \"upstream_id\": \"${upstream_id}\",
      \"plugins\": {
        \"proxy-rewrite\": {\"uri\": \"/get\"},
        \"response-rewrite\": {\"headers\": {\"set\": {\"X-Gateway\": \"sfg-labs\"}}}
      }
    }" > /dev/null
}

create_exact_route() {
  # Like create_route, but for an EXACT (non-wildcard) uri. Needed for zimma:
  # an exact route is looked up before any prefix/wildcard route, which is
  # what routes/zimma-api.yaml relies on to keep POST /api/auth/sso
  # protected without a wildcard shadowing it (see that file's F1 comment).
  # protected=false routes also proxy-rewrite to a real httpbin endpoint
  # (mirrors create_health_route's /get trick) so the smoke test can assert
  # a genuine 200 from upstream, not just "didn't 401".
  local id="$1" name="$2" host="$3" uri="$4" upstream_id="$5" protected="$6"
  echo "--> Route: ${name} (${host}${uri}) [exact] → upstream/${upstream_id} [auth=${protected}]"

  local plugins
  if [[ "${protected}" == "true" ]]; then
    plugins="{
      \"openid-connect\": {
        \"discovery\": \"${ZITADEL_URL}/.well-known/openid-configuration\",
        \"client_id\": \"${OIDC_CLIENT_ID}\",
        \"client_secret\": \"${OIDC_CLIENT_SECRET}\",
        \"bearer_only\": true,
        \"token_signing_alg_values_expected\": \"RS256\",
        \"set_userinfo_header\": true,
        \"userinfo_header_name\": \"X-Userinfo\",
        \"timeout\": 5
      },
      \"request-id\": {\"header_name\": \"X-Request-Id\", \"include_in_response\": true},
      \"limit-req\": {\"rate\": 10, \"burst\": 5, \"rejected_code\": 429, \"key_type\": \"var\", \"key\": \"remote_addr\"},
      \"response-rewrite\": {\"headers\": {\"set\": {\"X-Gateway\": \"sfg-labs\"}}}
    }"
  else
    plugins="{
      \"proxy-rewrite\": {\"uri\": \"/post\"},
      \"request-id\": {\"header_name\": \"X-Request-Id\", \"include_in_response\": true},
      \"response-rewrite\": {\"headers\": {\"set\": {\"X-Gateway\": \"sfg-labs\"}}}
    }"
  fi

  curl -sf -X PUT "${ADMIN_URL}/apisix/admin/routes/${id}" \
    -H "X-API-KEY: ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"host\": \"${host}\",
      \"uri\": \"${uri}\",
      \"methods\": [\"POST\", \"OPTIONS\"],
      \"upstream_id\": \"${upstream_id}\",
      \"plugins\": ${plugins}
    }" > /dev/null
}

wait_for_apisix

echo ""
echo "===> Creating upstreams"
create_upstream "1" "mock-backend:80"    # NMA engine (mock)
create_upstream "2" "mock-backend:80"    # Baithak (mock)
create_upstream "3" "mock-backend:80"    # CMS (mock)
create_upstream "4" "zitadel:8080"       # Zitadel auth
create_upstream "5" "mock-backend:80"    # Suwalka HR/Payroll (mock)
create_upstream "6" "mock-backend:80"    # Zimma (mock)

echo ""
echo "===> Creating routes"

# Public: Zitadel auth endpoints (no auth)
create_route "20" "zitadel-auth"  "auth.localhost"        "/"       "4" "false"

# Protected: NMA (JWT required)
create_route "30" "nma-api"       "api.nma.localhost"     "/api/"   "1" "true"
create_health_route "31" "nma-health"    "api.nma.localhost"     "1"

# Protected: Baithak (JWT required)
create_route "40" "baithak-api"   "api.baithak.localhost" "/api/"   "2" "true"
create_health_route "41" "baithak-health" "api.baithak.localhost" "2"

# Protected: CMS (JWT required)
create_route "50" "cms-api"       "api.cms.localhost"     "/api/"   "3" "true"
create_health_route "51" "cms-health"    "api.cms.localhost"     "3"

# Protected: Suwalka HR/Payroll (JWT required)
# Local host: api.suwalka.localhost  Path prefix: /api/hr/
# Upstream 5 → mock-backend:80 (the actual service is not in the Docker compose stack;
# mock-backend stands in for local smoke testing, same pattern as other services above).
create_route "60" "suwalka-hr-api" "api.suwalka.localhost" "/api/hr/" "5" "true"
# Recruitment + the folded HRMS modules (perf/docs/helpdesk) — all served by org-hr:3001.
create_route "62" "suwalka-recruitment-api" "api.suwalka.localhost" "/api/recruitment/" "5" "true"
create_route "63" "suwalka-perf-api"        "api.suwalka.localhost" "/api/perf/"        "5" "true"
create_route "64" "suwalka-docs-api"        "api.suwalka.localhost" "/api/docs/"        "5" "true"
create_route "65" "suwalka-helpdesk-api"    "api.suwalka.localhost" "/api/helpdesk/"    "5" "true"
create_route "66" "suwalka-training-api"    "api.suwalka.localhost" "/api/training/"    "5" "true"
create_health_route "61" "suwalka-hr-health" "api.suwalka.localhost" "5"

# Mixed: Zimma (mirrors routes/zimma-api.yaml — only SSO carries openid-connect)
# Local host: api.zimma.localhost
# F1 fix mirrored here: the auth app-paths are EXPLICIT exact routes, not a
# /api/auth/* prefix wildcard — a wildcard there would shadow the exact SSO
# route below for case/trailing-slash variants of /api/auth/sso, letting
# them reach the (mock) backend unauthenticated. See routes/zimma-api.yaml
# for the full writeup; tests/smoke/smoke-test-local.sh asserts this.
#
# PATH PREFIX mirrored here too (2026-07-26): production now matches these
# under /zimma/* (see routes/zimma-api.yaml's PATH PREFIX note — shared-host
# collision avoidance on api.faithandgamble.in). This local mock does not
# implement proxy-rewrite/regex_uri (mock-backend is httpbin and doesn't care
# what path it was reached on), so only the match-path arg below changes;
# the create_route/create_exact_route plumbing is untouched.
create_exact_route "70" "zimma-sso"          "api.zimma.localhost" "/zimma/api/auth/sso"    "6" "true"
create_exact_route "71" "zimma-sso-slash"    "api.zimma.localhost" "/zimma/api/auth/sso/"   "6" "true"
create_exact_route "72" "zimma-login"        "api.zimma.localhost" "/zimma/api/auth/login"    "6" "false"
create_exact_route "73" "zimma-login-slash"  "api.zimma.localhost" "/zimma/api/auth/login/"   "6" "false"
create_exact_route "74" "zimma-signup"       "api.zimma.localhost" "/zimma/api/auth/signup"   "6" "false"
create_exact_route "75" "zimma-signup-slash" "api.zimma.localhost" "/zimma/api/auth/signup/"  "6" "false"
# Non-auth resource paths — open at the gateway, zimma-api validates its own
# 7-day JWT in-app (see the sfg-auth: mixed note in CLAUDE.md).
create_route "76" "zimma-tasks"    "api.zimma.localhost" "/zimma/api/tasks"    "6" "false"
create_route "77" "zimma-members"  "api.zimma.localhost" "/zimma/api/members" "6" "false"
# Public webhooks — no auth at all, same posture as routes/public.yaml's
# zimma-webhooks (HMAC verified in-app). No /health or /ready mirror here:
# F6 removed those from the production public.yaml (probes hit the pod
# directly; a gateway health route added no value), so there's nothing to
# mirror.
create_route "78" "zimma-webhooks" "api.zimma.localhost" "/zimma/api/webhooks" "6" "false"

echo ""
echo "========================================================"
echo "  Routes configured. Test with:"
echo ""
echo "  # Health (public, expect 200):"
echo "  curl -H 'Host: api.nma.localhost' http://localhost:9080/health"
echo "  curl -H 'Host: api.suwalka.localhost' http://localhost:9080/healthz"
echo ""
echo "  # Protected without token (expect 401):"
echo "  curl -H 'Host: api.nma.localhost' http://localhost:9080/api/audit"
echo "  curl -H 'Host: api.suwalka.localhost' http://localhost:9080/api/hr/employees"
echo "  curl -X POST -H 'Host: api.zimma.localhost' http://localhost:9080/zimma/api/auth/sso"
echo ""
echo "  # Zimma SSO case-variant — must NOT reach upstream unauth (expect 404, no route):"
echo "  curl -X POST -H 'Host: api.zimma.localhost' http://localhost:9080/zimma/api/auth/SSO"
echo ""
echo "  # Zitadel OIDC discovery:"
echo "  curl http://localhost:8080/.well-known/openid-configuration | jq .issuer"
echo "========================================================"
