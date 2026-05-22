#!/usr/bin/env bash
# Live smoke tests against a running gateway.
# Verifies: public health endpoints return 200, protected routes return 401, auth server is reachable.
# Usage: bash tests/smoke/smoke-test.sh [BASE_URL] [AUTH_URL]
# Example: bash tests/smoke/smoke-test.sh https://api.nma-india.in https://auth.sfg-labs.in
set -euo pipefail

NMA_URL="${1:-https://api.nma-india.in}"
BAITHAK_URL="${2:-https://api.baithak.live}"
CMS_URL="${3:-https://api.cms.sfg-labs.in}"
AUTH_URL="${4:-https://auth.sfg-labs.in}"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]] || [[ "$actual" =~ $expected ]]; then
    echo "  PASS: ${desc} (${actual})"
    ((PASS++))
  else
    echo "  FAIL: ${desc} — expected ${expected}, got ${actual}"
    ((FAIL++))
  fi
}

http_status() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$@" 2>/dev/null || echo "000"
}

echo "===> [1/4] Health checks (expect 200)"
check "NMA health"     "200" "$(http_status "${NMA_URL}/health")"
check "Baithak health" "200" "$(http_status "${BAITHAK_URL}/health")"
check "CMS health"     "200" "$(http_status "${CMS_URL}/health")"

echo ""
echo "===> [2/4] Protected routes without token (expect 401)"
check "NMA /api/* — no token"     "401" "$(http_status "${NMA_URL}/api/audit")"
check "Baithak /api/* — no token" "401" "$(http_status "${BAITHAK_URL}/api/meetings")"
check "CMS /api/* — no token"     "401" "$(http_status "${CMS_URL}/api/citizens")"

echo ""
echo "===> [3/4] Protected routes with invalid token (expect 401)"
FAKE_TOKEN="Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.fake.signature"
check "NMA — invalid token"     "401" "$(http_status -H "Authorization: ${FAKE_TOKEN}" "${NMA_URL}/api/audit")"
check "Baithak — invalid token" "401" "$(http_status -H "Authorization: ${FAKE_TOKEN}" "${BAITHAK_URL}/api/meetings")"

echo ""
echo "===> [4/4] Auth server reachable"
AUTH_STATUS="$(http_status "${AUTH_URL}/.well-known/openid-configuration")"
check "OIDC discovery endpoint" "200" "${AUTH_STATUS}"

# Verify the OIDC discovery returns expected fields
if [[ "$AUTH_STATUS" == "200" ]]; then
  DISCOVERY=$(curl -s --max-time 10 "${AUTH_URL}/.well-known/openid-configuration")
  if echo "$DISCOVERY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['issuer', 'authorization_endpoint', 'token_endpoint', 'jwks_uri']
missing = [k for k in required if k not in d]
if missing:
    print(f'Missing fields: {missing}')
    sys.exit(1)
" 2>/dev/null; then
    echo "  PASS: OIDC discovery has required fields (issuer, token_endpoint, jwks_uri)"
    ((PASS++))
  else
    echo "  FAIL: OIDC discovery missing required fields"
    ((FAIL++))
  fi
fi

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || { echo "  Smoke tests FAILED."; exit 1; }
echo "  All smoke tests passed. Gateway is healthy."
echo "========================================================"
