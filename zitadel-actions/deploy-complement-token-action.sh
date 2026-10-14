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
#      The trigger's action list is READ first, merged (existing ∪ this one)
#      and written back; the list is printed before and after, and the run
#      exits non-zero if the re-read is missing any action it had before.
#   5. Prints what to verify — it does NOT claim success on a 200 alone.
#
# EXIT CODES. 0 = stored and the trigger re-read carries everything. 2 = 403 on
# the precheck, nothing changed. 1 = anything else: every request is checked,
# and any non-2xx, curl error or unreadable response stops the run and prints
# the response body. A run that stops after `update`/`create` but before
# `attach` has changed the Action only; the trigger is untouched.
#
# WHY STEP 5 MATTERS. `suwalka_grant_caps` has not been minted since
# 2026-08-03 and nobody noticed, because a claim that is silently absent looks
# exactly like a user who holds no grants. A 200 from this script proves the
# Action was stored, NOT that it runs or that the claims appear. Verify by
# logging in and decoding X-Userinfo. See the unit test at
# ../tests/zitadel-action-claims.test.js for what the guards are supposed to do.
#
# Usage:  ./deploy-complement-token-action.sh [--dry-run]
#         TRIGGER_ID=<id> only when the Pre Userinfo creation trigger has no
#         actions yet (its id is otherwise read from the live flow).

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# HTTP HELPERS — every call is checked. Nothing below this line may continue
# past a failed request.
# ═══════════════════════════════════════════════════════════════════════════
# The previous form called `curl -s` with no status check on four of its five
# requests. A failed flows/2 GET then parsed as "no actions attached", the
# trigger POST REPLACED the whole list with just this action — detaching
# `complementTokenClaims` and with it the `roles` claim — and the script still
# printed "Stored". These helpers make that impossible: a non-2xx or a curl
# error stops the run, and the error body is printed.

# Response bodies go to a private temp dir, removed on exit — not /tmp/z*.json,
# which any local user could pre-create or read.
ZTMP=$(mktemp -d "${TMPDIR:-/tmp}/zaction.XXXXXX")
trap 'rm -rf "$ZTMP"' EXIT

# Every Zitadel call goes through this, so the PAT is NEVER an argv entry.
#
# `curl -H "Authorization: Bearer $PAT"` puts a full iam-admin token on the command
# line, where anyone who can run `ps` on this machine reads it for as long as the
# curl runs. The script already refuses to put INTERNAL_GRANT_TOKEN on argv for
# exactly that reason ("argv is world-readable in /proc") and then did it anyway
# with the more powerful of the two secrets. Raised in review of #66.
#
# `curl --config -` reads options from stdin, so the header never appears in the
# process table. `--` is not needed: every caller passes its own flags after the
# URL, and curl treats the config as an additional source rather than a
# replacement for them.
zcurl() {
  printf 'header = "Authorization: Bearer %s"\n' "$PAT" | curl -sS --config - "$@"
}

# zcall LABEL CURL-ARGS...
# Runs one request with the body saved to "$ZTMP/LABEL.json". Prints
# "LABEL: HTTP nnn". Exits the SCRIPT (not a subshell — never call this inside
# $(...)) on a curl error or any non-2xx, printing the response body.
zcall() {
  local label=$1 out code
  shift
  out="$ZTMP/$label.json"
  : >"$out"
  if ! code=$(zcurl -o "$out" -w '%{http_code}' "$@"); then
    echo "$label: request failed before an HTTP status (network/TLS) — aborting" >&2
    [ -s "$out" ] && { cat "$out" >&2; echo >&2; }
    exit 1
  fi
  echo "$label: HTTP $code"
  case "$code" in
    2??) ;;
    *)
      echo "$label: HTTP $code — aborting. Response body:" >&2
      cat "$out" >&2
      echo >&2
      exit 1
      ;;
  esac
}

# flow_trigger FLOW_JSON_FILE
# Reads the Complement Token flow and prints ONE tab-separated line:
#   <trigger id or ->  <JSON id list>  <human list "id(name) ...">
# for the Pre Userinfo creation trigger. Exits non-zero — so the caller aborts —
# when the response cannot be read with certainty: not JSON, no `flow` object,
# a trigger entry whose type cannot be identified, or an attached action
# without an id. "No Pre Userinfo trigger entry" is the one legitimate empty
# list; anything ambiguous is a refusal, because guessing "empty" here is what
# detaches the `roles` action.
#
# Zitadel's v1 API nests the trigger key (`triggerType.name.key`, e.g.
# TRIGGER_TYPE_PRE_USERINFO_CREATION); the old parser read `triggerType.key`
# only. Both shapes, and the localized name, are matched here.
flow_trigger() {
  python3 - "$1" <<'PYFLOW'
import json, re, sys

def die(msg):
    print('flows/2: ' + msg + ' — refusing to touch the trigger', file=sys.stderr)
    raise SystemExit(1)

try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception as e:
    die('response is not JSON (%s)' % e)
flow = doc.get('flow') if isinstance(doc, dict) else None
if not isinstance(flow, dict):
    die('response has no "flow" object')
entries = flow.get('triggerActions') or []
if not isinstance(entries, list):
    die('"triggerActions" is not a list')

def labels(tt):
    out = []
    for v in (tt.get('key'), tt.get('name'), tt.get('localizedMessage')):
        if isinstance(v, str):
            out.append(v)
        elif isinstance(v, dict):
            out += [x for x in (v.get('key'), v.get('localizedMessage')) if isinstance(x, str)]
    return [re.sub(r'[^a-z]', '', x.lower()) for x in out if x]

trigger_id, ids, human = None, [], []
for ta in entries:
    tt = ta.get('triggerType') if isinstance(ta, dict) else None
    names = labels(tt) if isinstance(tt, dict) else []
    if not names:
        die('a trigger entry has no recognisable type')
    if not any('preuserinfocreation' in n for n in names):
        continue
    if tt.get('id') is not None:
        trigger_id = str(tt['id'])
    for a in ta.get('actions') or []:
        aid = a.get('id') if isinstance(a, dict) else None
        if not aid:
            die('an attached action has no id')
        if aid not in ids:
            ids.append(aid)
            human.append('%s(%s)' % (aid, a.get('name', '?')))
print('\t'.join([trigger_id or '-', json.dumps(ids), ' '.join(human) or '(none)']))
PYFLOW
}

# merge_ids BEFORE_JSON WANT_ID — prints BEFORE ∪ {WANT}, order kept. Never
# drops an id that is already attached.
merge_ids() {
  python3 -c '
import json, sys
ids = json.loads(sys.argv[1])
if sys.argv[2] not in ids:
    ids.append(sys.argv[2])
print(json.dumps(ids))
' "$1" "$2"
}

# missing_ids EXPECTED_JSON ACTUAL_JSON — prints the expected ids that are not
# in ACTUAL, space-separated (empty when none are missing).
missing_ids() {
  python3 -c '
import json, sys
have = set(json.loads(sys.argv[2]))
print(" ".join(i for i in json.loads(sys.argv[1]) if i not in have))
' "$1" "$2"
}

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
if ! PRECHECK=$(zcurl -o "$ZTMP/precheck.json" -w '%{http_code}' -X POST "$ISSUER/management/v1/actions/_search" \
  -H 'Content-Type: application/json' -d '{}'); then
  echo "precheck: request failed before an HTTP status (network/TLS) — aborting. Nothing was changed." >&2
  exit 1
fi
if [ "$PRECHECK" = "403" ]; then
  echo >&2
  echo "403 on actions/_search — the service account still lacks Actions permission." >&2
  echo "See the header: an ORG_OWNER must grant action.write/flow.write first." >&2
  echo "Nothing was changed." >&2
  exit 2
fi
if [ "$PRECHECK" != "200" ]; then
  echo "unexpected HTTP $PRECHECK on the precheck — aborting. Nothing was changed. Response body:" >&2
  cat "$ZTMP/precheck.json" >&2
  echo >&2
  exit 1
fi

# Build the script body with the token substituted.
#
# THE TOKEN GOES IN AS AN ENV VAR, NOT ON STDIN.
#
# The previous form was `python3 - <<'X' … X <<<"$IGT"`, which has TWO stdin
# redirections: the heredoc feeds python its script and the herestring is
# swallowed. `sys.stdin.read()` therefore returned EMPTY and the token silently
# became "". That is what actually shipped — the deployed Action ran with
# `INTERNAL_GRANT_TOKEN = ""`, every resolver call 401'd, and because the
# original ordering required `zitadel/http` before `zitadel/log` it produced no
# log key either. From outside it was indistinguishable from "the Action never
# runs", which is exactly the wrong diagnosis it led to.
#
# Env rather than argv: argv is world-readable in /proc.
BODY=$(SRC="$SRC" ACTION_NAME="$ACTION_NAME" IGT="$IGT" python3 <<'PYBODY'
import json, os, re, sys

src = open(os.environ['SRC']).read()

token = os.environ['IGT']
if not token:
    print('INTERNAL_GRANT_TOKEN is empty — refusing to deploy an Action that cannot '
          'authenticate. An empty token 401s every resolver call and looks like a '
          'dead Action.', file=sys.stderr)
    raise SystemExit(1)

placeholder = "'<set-me-in-the-zitadel-console-only>'"
if placeholder not in src:
    print('PLACEHOLDER_MISSING', file=sys.stderr)
    raise SystemExit(1)
src = src.replace(placeholder, json.dumps(token))

# ZITADEL INVOKES THE FUNCTION WHOSE NAME MATCHES THE ACTION NAME. Proven by
# probe: a minimal script named `setIdentityClaims` runs and logs; identical
# logic under a mismatched name does nothing at all, and says nothing.
action_name = os.environ['ACTION_NAME']
src, n = re.subn(r'\bfunction\s+complementTokenClaims\s*\(',
                 'function ' + action_name + '(', src)
if n != 1:
    print('expected exactly one function declaration to rename, found %d' % n, file=sys.stderr)
    raise SystemExit(1)

print(json.dumps(src))
PYBODY
)

# Refuse to ship a body whose token did not make it in — belt and braces on top
# of the guard above, because this failure is invisible once deployed.
if printf '%s' "$BODY" | grep -q 'INTERNAL_GRANT_TOKEN = \\"\\"'; then
  echo "the built body carries an EMPTY INTERNAL_GRANT_TOKEN — aborting" >&2
  exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run — would create/update action '$ACTION_NAME' (${#BODY} bytes) and attach it to the Complement Token flow / Pre Userinfo creation trigger"
  exit 0
fi

# A failed search used to read as "no such action" (`2>/dev/null || true`) and
# create a DUPLICATE. Now a failed or unreadable search stops the run.
zcall search -X POST "$ISSUER/management/v1/actions/_search" \
  -H 'Content-Type: application/json' -d '{}'
EXISTING=$(ACTION_NAME="$ACTION_NAME" python3 -c "
import json,sys,os
d=json.load(open(sys.argv[1]))
if not isinstance(d, dict):
    raise SystemExit('actions/_search: response is not an object')
name=os.environ['ACTION_NAME']
print(next((a['id'] for a in (d.get('result') or []) if a.get('name')==name), ''))
" "$ZTMP/search.json") || { echo "could not read the actions/_search response — aborting" >&2; cat "$ZTMP/search.json" >&2; exit 1; }

PAYLOAD=$(printf '%s' "$BODY" | ACTION_NAME="$ACTION_NAME" python3 -c "
import json,sys,os
print(json.dumps({'name': os.environ['ACTION_NAME'],
                  'script': json.loads(sys.stdin.read()),
                  'timeout': '10s',
                  'allowedToFail': True}))
")

# Keep the embedded internal-grant token out of curl's argv and disk. FD 3 is
# a pipe carrying the body; stdin remains available for the PAT curl config.
if [ -n "$EXISTING" ]; then
  echo "updating existing action $EXISTING"
  zcall update -X PUT "$ISSUER/management/v1/actions/$EXISTING" \
    -H 'Content-Type: application/json' --data-binary @/dev/fd/3 3< <(printf '%s' "$PAYLOAD")
  ACTION_ID="$EXISTING"
else
  echo "creating action"
  zcall create -X POST "$ISSUER/management/v1/actions" \
    -H 'Content-Type: application/json' --data-binary @/dev/fd/3 3< <(printf '%s' "$PAYLOAD")
  ACTION_ID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('id',''))" "$ZTMP/create.json" 2>/dev/null || true)
  [ -n "$ACTION_ID" ] || { echo "create returned 2xx but no action id — aborting. Response body:" >&2; cat "$ZTMP/create.json" >&2; exit 1; }
fi
echo "action id: $ACTION_ID"

# Flow 2 = COMPLEMENT_TOKEN; the Pre Userinfo creation trigger.
#
# SETTING A TRIGGER REPLACES ITS ENTIRE ACTION LIST. The live trigger carries
# TWO actions, and the other one (`complementTokenClaims`) is the only thing
# injecting the top-level `roles` claim. Posting just this action's id would
# silently detach it and break every OWNER_GM/BSM_TL write that assertRole()
# gates — with no error, because the flow would still be valid.
#
# So: read what is attached (abort if that read is not certain), union in this
# action, write back, then READ AGAIN and abort if anything that was attached
# before is gone.
zcall flow-before "$ISSUER/management/v1/flows/2"
FLOW_BEFORE=$(flow_trigger "$ZTMP/flow-before.json") || exit 1
IFS=$'\t' read -r SEEN_TRIGGER BEFORE_IDS BEFORE_HUMAN <<<"$FLOW_BEFORE"
IDS=$(merge_ids "$BEFORE_IDS" "$ACTION_ID")

# The trigger id comes from the live flow when the trigger already has actions.
# TRIGGER_ID overrides; if the two disagree, stop rather than write to one
# trigger while reading another.
if [ "$SEEN_TRIGGER" != "-" ] && [ -n "${TRIGGER_ID:-}" ] && [ "$SEEN_TRIGGER" != "$TRIGGER_ID" ]; then
  echo "TRIGGER_ID=$TRIGGER_ID but the live flow lists Pre Userinfo creation as trigger $SEEN_TRIGGER — aborting" >&2
  exit 1
fi
if [ "$SEEN_TRIGGER" != "-" ]; then
  TRIGGER_ID="$SEEN_TRIGGER"
fi
[ -n "${TRIGGER_ID:-}" ] || {
  echo "the Pre Userinfo creation trigger has no actions yet, so its id cannot be read from the flow — set TRIGGER_ID and re-run" >&2
  exit 1
}

echo "trigger $TRIGGER_ID BEFORE: $BEFORE_HUMAN"
if [ "$IDS" = "$BEFORE_IDS" ]; then
  echo "trigger $TRIGGER_ID unchanged; skipping attach"
else
  echo "trigger $TRIGGER_ID WRITING: $IDS"
  zcall attach -X POST "$ISSUER/management/v1/flows/2/trigger/$TRIGGER_ID" \
    -H 'Content-Type: application/json' \
    -d "{\"actionIds\":$IDS}"
fi

zcall flow-after "$ISSUER/management/v1/flows/2"
FLOW_AFTER=$(flow_trigger "$ZTMP/flow-after.json") || exit 1
IFS=$'\t' read -r _ AFTER_IDS AFTER_HUMAN <<<"$FLOW_AFTER"
echo "trigger $TRIGGER_ID AFTER : $AFTER_HUMAN"
MISSING=$(missing_ids "$IDS" "$AFTER_IDS")
if [ -n "$MISSING" ]; then
  echo "the trigger does NOT carry what was written — missing: $MISSING" >&2
  echo "Re-attach them by hand NOW (an action missing from this trigger drops its claims, e.g. roles)." >&2
  exit 1
fi

cat <<'EOF'

Stored, and the trigger re-read carries every action it had before plus this one.
That is NOT the same as working.

VERIFY, because this exact claim went missing for three weeks unnoticed:
  1. Log in as any employee.
  2. Decode the base64 X-Userinfo header a backend receives.
  3. Confirm BOTH suwalka_grant_caps and suwalka_levels are present.
     An absent suwalka_grant_caps reads as "pre-matrix, unrestricted" —
     fail-OPEN — so its absence is invisible from the outside.
EOF
