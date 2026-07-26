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

echo "===> [1/5] Health check (public, no auth needed, expect 200)"
check "NMA health"     "200" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/health")"
check "Baithak health" "200" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/health")"
check "CMS health"     "200" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/health")"

echo ""
echo "===> [2/5] Protected routes without token (expect 401)"
check "NMA /api/ — no token"     "401" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/api/anything")"
check "Baithak /api/ — no token" "401" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/api/anything")"
check "CMS /api/ — no token"     "401" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/api/anything")"

echo ""
echo "===> [3/5] Protected routes with fake token (expect 401)"
FAKE="Bearer eyJhbGciOiJSUzI1NiJ9.fake.sig"
check "NMA — fake token"     "401" "$(http -H 'Host: api.nma.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"
check "Baithak — fake token" "401" "$(http -H 'Host: api.baithak.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"

echo ""
echo "===> [4/5] Zimma — SSO-only openid-connect; F1 regression guard"
# PATH PREFIX (2026-07-26): all zimma paths moved under /zimma/* — see the
# PATH PREFIX note at the top of routes/zimma-api.yaml. Asserted against the
# prefixed path here since that's what the local mirror in
# docker/apisix/setup-routes.sh now registers; a bare /api/auth/sso should
# match no route at all (404), which case-variant assertion below now also
# proves for the un-prefixed form.
check "Zimma SSO — no token"   "401" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/sso")"
check "Zimma SSO — fake token" "401" "$(http -X POST -H 'Host: api.zimma.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/zimma/api/auth/sso")"
# F1 (CRITICAL, fixed in routes/zimma-api.yaml): a wildcard /api/auth/* app
# rule used to shadow the exact SSO rule for case/trailing-slash variants,
# letting them reach zimma-api unauthenticated with attacker-supplied
# X-Userinfo. The fix replaces that wildcard with explicit login/signup
# paths, so a case-variant like /zimma/api/auth/SSO now matches no route at
# all — APISIX 404s it before it is ever proxied to the (mock) backend. This
# is the regression guard for that fix; see docker/apisix/setup-routes.sh
# for the local route mirror it depends on. Bypassing the prefix entirely
# (unprefixed /api/auth/SSO) is asserted too — it must ALSO be a bare 404
# (no route claims un-prefixed paths any more), proving the prefix isn't
# just cosmetic but is actually required to reach zimma-api at all.
check "Zimma SSO case-variant — no route, not proxied unauth" "404" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/SSO")"
check "Zimma SSO — unprefixed path bypass — no route" "404" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/api/auth/sso")"
check "Zimma login — open at gateway, in-app JWT"  "200" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/login")"
check "Zimma signup — open at gateway, in-app JWT" "200" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/signup")"

echo ""
echo "===> [5/5] Zitadel OIDC discovery (expect 200 + valid JSON)"
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
