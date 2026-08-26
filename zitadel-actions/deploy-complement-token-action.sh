#!/usr/bin/env bash
# Deploy `complementTokenClaims.js` to Zitadel via the MANAGEMENT API instead of
# the console paste — so the INTERNAL_GRANT_TOKEN never leaves the cluster and
# nobody hand-copies a secret.
#
# ═══════════════════════════════════════════════════════════════════════════
# THIS SCRIPT IS BLOCKED UNTIL A ROLE IS GRANTED. READ THIS FIRST.
# ═══════════════════════════════════════════════════════════════════════════
# Measured 2026-08-26 against https://sfg-labs.faithandgamble.in with the
# `mgmt-pat` from `sfg-pos-app/suwalka-auth-secrets`:
#
#   POST /management/v1/users/_search        200   <- works
#   GET  /management/v1/orgs/me              200   <- works
#   POST /management/v1/projects/_search     200   <- works
#   POST /management/v1/orgs/me/members/_search  403 AUTH-5mWD2
#   POST /management/v1/actions/_search      403 AUTH-5mWD2
#   GET  /management/v1/flows/2              403 AUTH-5mWD2
#
# 403, not 401 — the PAT authenticates; the service account simply holds user
# and project rights (all `suwalka-auth` ever needed) and neither Actions nor
# Flows. `service-account-token` in the same secret gives the identical 403.
#
# It also cannot grant itself the role: org member management is 403 too. So
# this needs one action from a Zitadel ORG_OWNER:
#
#   Zitadel console -> Organisation -> Managers -> the suwalka-auth service
#   account -> add a role that covers action.write / flow.write (ORG_OWNER is
#   the blunt option; a custom role is tidier).
#
# Once that is done this script runs unattended and is idempotent.
#
# ═══════════════════════════════════════════════════════════════════════════
# WHAT IT DOES
# ═══════════════════════════════════════════════════════════════════════════
#   1. Reads the Action source from complementTokenClaims.js (this directory).
#   2. Substitutes the real INTERNAL_GRANT_TOKEN, read straight from the k8s
#      secret into a shell variable. The value is never echoed, never written
#      to disk, and never passed on a command line.
#   3. Creates the Action, or updates it if one of the same name exists.
#   4. Attaches it to the Complement Token flow, Pre Userinfo creation trigger.
#   5. Prints what to verify — it does NOT claim success on a 200 alone.
#
# WHY STEP 5 MATTERS. `suwalka_grant_caps` has not been minted since
# 2026-08-03 and nobody noticed, because a claim that is silently absent looks
# exactly like a user who holds no grants. A 200 from this script proves the
# Action was stored, NOT that it runs or that the claims appear. Verify by
# logging in and decoding X-Userinfo. See the unit test at
# ../tests/zitadel-action-claims.test.js for what the guards are supposed to do.
#
# Usage:  ./deploy-complement-token-action.sh [--dry-run]

set -euo pipefail

KC=${KUBECONFIG_PATH:-~/.kube/sfg-prod.kubeconfig}
NS=${NS:-sfg-pos-app}
SEC=${SEC:-suwalka-auth-secrets}
ACTION_NAME=${ACTION_NAME:-suwalkaComplementTokenClaims}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/complementTokenClaims.js"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

ISSUER=$(kubectl --kubeconfig "$KC" -n "$NS" get secret "$SEC" -o jsonpath='{.data.zitadel-issuer}' | base64 -d)
PAT=$(kubectl --kubeconfig "$KC" -n "$NS" get secret "$SEC" -o jsonpath='{.data.mgmt-pat}' | base64 -d)
IGT=$(kubectl --kubeconfig "$KC" -n "$NS" get secret "$SEC" -o jsonpath='{.data.internal-grant-token}' | base64 -d)

[ -n "$ISSUER" ] && [ -n "$PAT" ] && [ -n "$IGT" ] || { echo "a secret came back empty — aborting" >&2; exit 1; }
echo "issuer  : $ISSUER"
echo "secrets : loaded (${#PAT} / ${#IGT} chars, not printed)"

# Fail EARLY and with the real reason, rather than half-deploying.
PRECHECK=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ISSUER/management/v1/actions/_search" \
  -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d '{}')
if [ "$PRECHECK" = "403" ]; then
  echo >&2
  echo "403 on actions/_search — the service account still lacks Actions permission." >&2
  echo "See the header: an ORG_OWNER must grant action.write/flow.write first." >&2
  echo "Nothing was changed." >&2
  exit 2
fi
[ "$PRECHECK" = "200" ] || { echo "unexpected HTTP $PRECHECK on the precheck — aborting" >&2; exit 1; }

# Build the script body with the token substituted. Done in python via stdin so
# the secret is never an argv entry (argv is world-readable in /proc).
BODY=$(SRC="$SRC" python3 - <<'PY'
import json, os, sys
src = open(os.environ['SRC']).read()
token = sys.stdin.read().strip()
placeholder = "'<set-me-in-the-zitadel-console-only>'"
if placeholder not in src:
    print("PLACEHOLDER_MISSING", file=sys.stderr); raise SystemExit(1)
print(json.dumps(src.replace(placeholder, json.dumps(token))))
PY
<<<"$IGT")

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run — would create/update action '$ACTION_NAME' (${#BODY} bytes) and attach it to flow 2 / trigger 3"
  exit 0
fi

EXISTING=$(curl -s -X POST "$ISSUER/management/v1/actions/_search" \
  -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c "
import json,sys,os
d=json.load(sys.stdin)
name=os.environ['ACTION_NAME']
print(next((a['id'] for a in (d.get('result') or []) if a.get('name')==name), ''))
" ACTION_NAME="$ACTION_NAME" 2>/dev/null || true)

PAYLOAD=$(python3 -c "
import json,sys,os
print(json.dumps({'name': os.environ['ACTION_NAME'],
                  'script': json.loads(sys.stdin.read()),
                  'timeout': '10s',
                  'allowedToFail': True}))
" ACTION_NAME="$ACTION_NAME" <<<"$BODY")

if [ -n "$EXISTING" ]; then
  echo "updating existing action $EXISTING"
  curl -s -o /tmp/zaction.json -w 'update: HTTP %{http_code}\n' -X PUT \
    "$ISSUER/management/v1/actions/$EXISTING" \
    -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d "$PAYLOAD"
  ACTION_ID="$EXISTING"
else
  echo "creating action"
  curl -s -o /tmp/zaction.json -w 'create: HTTP %{http_code}\n' -X POST \
    "$ISSUER/management/v1/actions" \
    -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d "$PAYLOAD"
  ACTION_ID=$(python3 -c "import json;print(json.load(open('/tmp/zaction.json')).get('id',''))")
fi

[ -n "$ACTION_ID" ] || { echo "no action id returned:"; cat /tmp/zaction.json; exit 1; }
echo "action id: $ACTION_ID"

# Flow 2 = COMPLEMENT_TOKEN, trigger 3 = PRE_USERINFO_CREATION. Setting the
# trigger REPLACES its action list, so include every action that should run.
curl -s -o /tmp/ztrigger.json -w 'attach trigger: HTTP %{http_code}\n' -X POST \
  "$ISSUER/management/v1/flows/2/trigger/3" \
  -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  -d "{\"actionIds\":[\"$ACTION_ID\"]}"

cat <<'EOF'

Stored. That is NOT the same as working.

VERIFY, because this exact claim went missing for three weeks unnoticed:
  1. Log in as any employee.
  2. Decode the base64 X-Userinfo header a backend receives.
  3. Confirm BOTH suwalka_grant_caps and suwalka_levels are present.
     An absent suwalka_grant_caps reads as "pre-matrix, unrestricted" —
     fail-OPEN — so its absence is invisible from the outside.
EOF
