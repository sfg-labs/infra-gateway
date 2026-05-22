#!/usr/bin/env bash
# Smoke tests against the local Docker Compose stack.
# Run after: docker compose up -d && bash docker/apisix/setup-routes.sh
# Usage: bash tests/smoke/smoke-test-local.sh
set -euo pipefail

GATEWAY="http://localhost:9080"
ZITADEL="http://localhost:8080"
PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" || "$actual" =~ $expected ]]; then
    echo "  PASS: ${desc} (${actual})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc} — expected ${expected}, got ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

http() {
  curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$@" 2>/dev/null || echo "000"
}

echo "===> [1/4] Health check (public, no auth needed, expect 200)"
check "NMA health"     "200" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/health")"
check "Baithak health" "200" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/health")"
check "CMS health"     "200" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/health")"

echo ""
echo "===> [2/4] Protected routes without token (expect 401)"
check "NMA /api/ — no token"     "401" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/api/anything")"
check "Baithak /api/ — no token" "401" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/api/anything")"
check "CMS /api/ — no token"     "401" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/api/anything")"

echo ""
echo "===> [3/4] Protected routes with fake token (expect 401)"
FAKE="Bearer eyJhbGciOiJSUzI1NiJ9.fake.sig"
check "NMA — fake token"     "401" "$(http -H 'Host: api.nma.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"
check "Baithak — fake token" "401" "$(http -H 'Host: api.baithak.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"

echo ""
echo "===> [4/4] Zitadel OIDC discovery (expect 200 + valid JSON)"
DISC_STATUS="$(http "${ZITADEL}/.well-known/openid-configuration")"
check "OIDC discovery HTTP 200" "200" "${DISC_STATUS}"

if [[ "$DISC_STATUS" == "200" ]]; then
  ISSUER=$(curl -sf "${ZITADEL}/.well-known/openid-configuration" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer','MISSING'))")
  check "OIDC issuer present" "http" "${ISSUER}"
fi

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || { echo "  FAILED"; exit 1; }
echo "  All local smoke tests passed."
echo "========================================================"
