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
  # N1 (PR #33 round-2 review): this used to be `[[ "$actual" == "$expected"
  # || "$actual" =~ $expected ]]` — an UNANCHORED regex fallback, so
  # expected="404" would substring-match an actual of "404000" (see the old
  # http() bug below) or, in principle, any other status code that merely
  # contains "404" somewhere in it. Anchored to a full-string match now;
  # == already covers exact equality, so this is just a stricter version of
  # the same intent, not new behavior for any currently-passing check.
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" || "$actual" =~ ^${expected}$ ]]; then
    echo "  PASS: ${desc} (${actual})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc} — expected ${expected}, got ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

http() {
  # N1 (PR #33 round-2 review): this used to be
  #   curl -sf -o /dev/null -w "%{http_code}" ... 2>/dev/null || echo "000"
  # `-f` (--fail) makes curl exit non-zero on any HTTP >=400 response, but it
  # still WRITES the real status code via -w before exiting — so the `||
  # echo "000"` fallback fires too, and the two concatenate: a real 404
  # becomes the string "404000", a real 401 becomes "401000". Combined with
  # check()'s old unanchored regex this still happened to "work" (expected
  # "404" substring-matches "404000"), which is exactly the false-pass this
  # round of review caught. Dropping -f fixes it at the source: without -f,
  # curl exits 0 whenever ANY HTTP response was received (even 4xx/5xx) and
  # -w prints the real code with nothing appended; on a genuine connection
  # failure (no response at all) curl itself already writes "000" via -w,
  # so the `-n` fallback below only fires on the pathological case of truly
  # empty output.
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$@" 2>/dev/null)"
  [[ -n "${code}" ]] && echo "${code}" || echo "000"
}

has_gateway_header() {
  # N1 (PR #33 round-2 review): status code alone cannot tell "APISIX
  # matched no route" apart from "APISIX matched a route, proxied the
  # request, and the UPSTREAM itself returned 404" — both are visible to the
  # caller as plain HTTP 404. Concretely: if someone reintroduces a
  # /zimma/api/auth/* wildcard on the OPEN app rule, create_route's open
  # branch has no proxy-rewrite, so a case-variant like
  # /zimma/api/auth/SSO would be proxied unauthenticated straight to
  # httpbin, which 404s on a path it doesn't recognize — status-code-only
  # assertions can't tell that apart from a clean "no route matched" 404.
  # response-rewrite (X-Gateway: sfg-labs) only runs when a route actually
  # matched and its plugin chain executed, so its ABSENCE is the signal
  # that distinguishes "never reached any rule" from "reached a rule and
  # the backend replied with its own 404". Echoes "yes"/"no".
  local headers
  headers="$(curl -s -D - -o /dev/null --max-time 10 "$@" 2>/dev/null)"
  if echo "${headers}" | grep -qi $'^X-Gateway: *sfg-labs\r\{0,1\}$'; then
    echo "yes"
  else
    echo "no"
  fi
}

echo "===> [1/6] Health check (public, no auth needed, expect 200)"
check "NMA health"     "200" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/health")"
check "Baithak health" "200" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/health")"
check "CMS health"     "200" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/health")"

echo ""
echo "===> [2/6] Protected routes without token (expect 401)"
check "NMA /api/ — no token"     "401" "$(http -H 'Host: api.nma.localhost'     "${GATEWAY}/api/anything")"
check "Baithak /api/ — no token" "401" "$(http -H 'Host: api.baithak.localhost' "${GATEWAY}/api/anything")"
check "CMS /api/ — no token"     "401" "$(http -H 'Host: api.cms.localhost'     "${GATEWAY}/api/anything")"

echo ""
echo "===> [3/6] Protected routes with fake token (expect 401)"
FAKE="Bearer eyJhbGciOiJSUzI1NiJ9.fake.sig"
check "NMA — fake token"     "401" "$(http -H 'Host: api.nma.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"
check "Baithak — fake token" "401" "$(http -H 'Host: api.baithak.localhost' -H "Authorization: ${FAKE}" "${GATEWAY}/api/anything")"

echo ""
echo "===> [4/6] Zimma — SSO-only openid-connect; F1 regression guard"
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
# Status-code checks (informative — see has_gateway_header below for the
# actual guard, since a 404 alone doesn't prove APISIX never routed this).
check "Zimma SSO case-variant — 404" "404" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/SSO")"
check "Zimma SSO — unprefixed path bypass — 404" "404" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/api/auth/sso")"
# THE ACTUAL GUARD (N1, PR #33 round-2 review): a 404 alone doesn't prove
# the request was never proxied — a reintroduced /zimma/api/auth/* wildcard
# on the OPEN app rule would ALSO 404 (from httpbin itself, unauthenticated)
# and status-code checks can't tell the two apart. X-Gateway: sfg-labs is
# set by response-rewrite, which only runs when some rule's plugin chain
# actually executed, so its ABSENCE proves APISIX matched no route at all.
check "Zimma SSO case-variant — X-Gateway header ABSENT (never routed)" "no" "$(has_gateway_header -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/SSO")"
check "Zimma SSO — unprefixed bypass — X-Gateway header ABSENT (never routed)" "no" "$(has_gateway_header -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/api/auth/sso")"
check "Zimma login — open at gateway, in-app JWT"  "200" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/login")"
check "Zimma signup — open at gateway, in-app JWT" "200" "$(http -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/signup")"
# Sanity check that has_gateway_header itself isn't just always "no": a
# route that DID match (the open login route above) must carry the header.
check "Zimma login — X-Gateway header PRESENT (sanity check on the helper)" "yes" "$(has_gateway_header -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/login")"

echo ""
echo "===> [5/6] X-Client-IP reaches the upstream (zimma-api rate-limit dependency)"
# routes/zimma-api.yaml's proxy-rewrite now injects X-Client-IP: $remote_addr
# on zimma routes (see that file for the why — zimma-api's rate limiter is
# meant to trust this header instead of a rotating APISIX pod IP).
# mock-backend is httpbin, which echoes every header it received back in its
# JSON response body under "headers" — the only local signal that can prove
# the header actually reached the upstream (a passing status code alone
# can't; the header could be silently dropped and the route would still
# 200). Only usable against the unprotected exact zimma routes
# (login/signup), whose create_exact_route branch proxy-rewrites to
# httpbin's /post; the protected SSO routes 401 before proxy-rewrite ever
# runs (no valid local JWT to present here), so there is nothing to echo
# for those — this section deliberately does not attempt it.
client_ip_header_value() {
  # Echoes the X-Client-IP value httpbin recorded (case-insensitive match,
  # since werkzeug/httpbin title-cases header names in its echo), or
  # "MISSING" if the key isn't present in the echoed headers at all.
  local body
  body="$(curl -s --max-time 10 "$@" 2>/dev/null)"
  python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    headers = data.get('headers', {})
    for k, v in headers.items():
        if k.lower() == 'x-client-ip':
            print(v)
            sys.exit(0)
    print('MISSING')
except Exception:
    print('MISSING')
" <<< "${body}"
}
CLIENT_IP_LOGIN="$(client_ip_header_value -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/login")"
if [[ "${CLIENT_IP_LOGIN}" != "MISSING" && -n "${CLIENT_IP_LOGIN}" ]]; then
  echo "  PASS: Zimma login — X-Client-IP reached upstream (${CLIENT_IP_LOGIN})"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Zimma login — X-Client-IP reached upstream — expected a value, got MISSING"
  FAIL=$((FAIL + 1))
fi
CLIENT_IP_SIGNUP="$(client_ip_header_value -X POST -H 'Host: api.zimma.localhost' "${GATEWAY}/zimma/api/auth/signup")"
if [[ "${CLIENT_IP_SIGNUP}" != "MISSING" && -n "${CLIENT_IP_SIGNUP}" ]]; then
  echo "  PASS: Zimma signup — X-Client-IP reached upstream (${CLIENT_IP_SIGNUP})"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Zimma signup — X-Client-IP reached upstream — expected a value, got MISSING"
  FAIL=$((FAIL + 1))
fi
# Anti-spoofing guard: proxy-rewrite uses `headers.set` (overwrite), not
# `headers.add` (append) — see the CRITICAL comment in routes/zimma-api.yaml.
# If a client's own X-Client-IP survived to the upstream (whether replacing
# the gateway's value or comma-joined alongside it), the attacker controls
# part of zimma-api's rate-limit key and can mint unlimited buckets, which
# defeats the entire point of this header. Substring match (not exact
# equality) so this also catches an appended/comma-joined regression, not
# just a full-overwrite-by-attacker regression.
SPOOFED_LOGIN="$(client_ip_header_value -X POST -H 'Host: api.zimma.localhost' -H 'X-Client-IP: 1.2.3.4' "${GATEWAY}/zimma/api/auth/login")"
if [[ "${SPOOFED_LOGIN}" != "MISSING" && -n "${SPOOFED_LOGIN}" && "${SPOOFED_LOGIN}" != *"1.2.3.4"* ]]; then
  echo "  PASS: Zimma login — client-sent X-Client-IP: 1.2.3.4 did NOT survive to upstream (gateway value: ${SPOOFED_LOGIN})"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Zimma login — client-sent X-Client-IP: 1.2.3.4 was NOT overwritten — got '${SPOOFED_LOGIN}' (expected gateway's own \$remote_addr, spoofed value must not appear)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "===> [6/6] Zitadel OIDC discovery (expect 200 + valid JSON)"
DISC_STATUS="$(http "${ZITADEL}/.well-known/openid-configuration")"
check "OIDC discovery HTTP 200" "200" "${DISC_STATUS}"

if [[ "$DISC_STATUS" == "200" ]]; then
  ISSUER=$(curl -sf "${ZITADEL}/.well-known/openid-configuration" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer','MISSING'))")
  # This is a genuine prefix check (any http(s) issuer URL is valid, so an
  # exact match is impossible) — done directly rather than through check()'s
  # regex fallback, which N1 anchored to a full-string match for the status
  # code checks above and shouldn't be re-loosened just for this one case.
  if [[ "${ISSUER}" == http* ]]; then
    echo "  PASS: OIDC issuer present (${ISSUER})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: OIDC issuer present — expected to start with http, got ${ISSUER}"
    FAIL=$((FAIL + 1))
  fi
fi

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || { echo "  FAILED"; exit 1; }
echo "  All local smoke tests passed."
echo "========================================================"
