#!/usr/bin/env bash
# Deploy `complementTokenClaims.js` to Zitadel via the MANAGEMENT API instead of
# the console paste — so the INTERNAL_GRANT_TOKEN never leaves the cluster and
# nobody hand-copies a secret.
#
# ═══════════════════════════════════════════════════════════════════════════
# UNBLOCKED 2026-08-27 — AND THE TARGET CHANGED. READ THIS.
# ═══════════════════════════════════════════════════════════════════════════
# The blocker was never a missing role on suwalka-auth's `mgmt-pat`; it was that
# no credential in the cluster had Actions rights. `sfg-gateway/iam-admin-pat`
# now does — actions/_search, flows/2 and orgs/me/members/_search all 200.
#
# Inspecting the live instance then changed what this script should do:
#
#   setIdentityClaims       resolver-backed, calls org-hr's admin-grants/by-sub,
#                           and writes ONLY `api.v1.claims.setClaim` — which is
#                           the TOKEN surface. It therefore contributes NOTHING
#                           to userinfo, and APISIX base64s only userinfo into
#                           X-Userinfo. This file is its successor.
#
#   complementTokenClaims   a DIFFERENT action that mirrors Zitadel user
#                           METADATA via `api.v1.userinfo.setClaim`. It is the
#                           only thing currently injecting the top-level `roles`
#                           claim, which assertRole() gates OWNER_GM/BSM_TL
#                           writes on. DO NOT OVERWRITE IT — despite the name
#                           collision with this repo's file.
#
# Measured on a real login (superadmin@suwalka.demo), userinfo carried:
#   suwalka_admin / suwalka_caps / suwalka_identity / roles   PRESENT
#   suwalka_outlet_set / suwalka_dept_set                     ABSENT
#   suwalka_grant_caps / suwalka_levels                       ABSENT
#
# So #648 is confirmed, and two further claims `readUser()` parses have never
# been minted either — `suwalka_outlet_set` was renamed from
# `suwalka_branch_set` and the Action never followed.
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
# `setIdentityClaims`, NOT `complementTokenClaims`. Measured on the live
# instance 2026-08-27: `setIdentityClaims` is the resolver-backed action this
# file is the successor to. `complementTokenClaims` is a DIFFERENT action that
# mirrors Zitadel user METADATA and is the only thing currently injecting the
# top-level `roles` claim, which assertRole() gates OWNER_GM/BSM_TL writes on.
# Deploying under that name would overwrite it and break those writes.
ACTION_NAME=${ACTION_NAME:-setIdentityClaims}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/complementTokenClaims.js"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

ISSUER=$(kubectl --kubeconfig "$KC" -n "$NS" get secret "$SEC" -o jsonpath='{.data.zitadel-issuer}' | base64 -d)
# suwalka-auth's mgmt-pat can read users and projects but 403s on Actions and
# Flows. The iam-admin PAT is the one with the rights — verified against
# actions/_search, flows/2 and orgs/me/members/_search, all 200.
PAT=$(kubectl --kubeconfig "$KC" -n sfg-gateway get secret iam-admin-pat -o jsonpath='{.data.pat}' 2>/dev/null | base64 -d)
if [ -z "$PAT" ]; then
  PAT=$(kubectl --kubeconfig "$KC" -n "$NS" get secret "$SEC" -o jsonpath='{.data.mgmt-pat}' | base64 -d)
  echo "note: falling back to mgmt-pat, which 403s on Actions — expect the precheck to stop this run"
fi
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

# Flow 2 = COMPLEMENT_TOKEN, trigger 3 = PRE_USERINFO_CREATION.
#
# SETTING A TRIGGER REPLACES ITS ENTIRE ACTION LIST. The live trigger carries
# TWO actions, and the other one (`complementTokenClaims`) is the only thing
# injecting the top-level `roles` claim. Posting just this action's id would
# silently detach it and break every OWNER_GM/BSM_TL write that assertRole()
# gates — with no error, because the flow would still be valid.
#
# So: read what is attached, union in this action, preserve order, write back.
CURRENT=$(curl -s "$ISSUER/management/v1/flows/2" -H "Authorization: Bearer $PAT")
IDS=$(ACTION_ID="$ACTION_ID" python3 -c "
import json, os, sys
flow = (json.load(sys.stdin).get('flow') or {})
want = os.environ['ACTION_ID']
ids = []
for ta in flow.get('triggerActions') or []:
    tt = (ta.get('triggerType') or {}).get('key','')
    if 'PreUserinfoCreation' not in tt:
        continue
    for a in ta.get('actions') or []:
        if a.get('id') and a['id'] not in ids:
            ids.append(a['id'])
if want not in ids:
    ids.append(want)
print(json.dumps(ids))
" <<<"$CURRENT")
echo "trigger will carry: $IDS"

curl -s -o /tmp/ztrigger.json -w 'attach trigger: HTTP %{http_code}\n' -X POST \
  "$ISSUER/management/v1/flows/2/trigger/3" \
  -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  -d "{\"actionIds\":$IDS}"

cat <<'EOF'

Stored. That is NOT the same as working.

VERIFY, because this exact claim went missing for three weeks unnoticed:
  1. Log in as any employee.
  2. Decode the base64 X-Userinfo header a backend receives.
  3. Confirm BOTH suwalka_grant_caps and suwalka_levels are present.
     An absent suwalka_grant_caps reads as "pre-matrix, unrestricted" —
     fail-OPEN — so its absence is invisible from the outside.
EOF
