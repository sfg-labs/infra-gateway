#!/usr/bin/env bash
# Offline test for zitadel-actions/deploy-complement-token-action.sh.
#
# Runs the REAL script end to end with `kubectl` and `curl` replaced by fakes on
# PATH, so no cluster and no Zitadel is ever contacted (the fake issuer is on
# the reserved .invalid TLD as a second guard). Each scenario is a directory of
# canned responses; the fake curl logs every request so a check can prove what
# was, and was NOT, sent.
#
# The case that matters most: a failed read of the trigger list must stop the
# run BEFORE the trigger POST. The old script parsed a failed GET as "nothing
# attached" and replaced the whole list, detaching the action that injects the
# `roles` claim, then printed "Stored".
#
# Run: bash tests/zitadel-deploy-script.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${DEPLOY_SCRIPT:-$ROOT/zitadel-actions/deploy-complement-token-action.sh}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zdeploy-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"

# --- fake kubectl: answers the three secret reads with fixed fake values -----
cat >"$BIN/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *zitadel-issuer*) printf 'https://zitadel.fake.invalid' | base64; exit 0 ;;
    *internal-grant-token*) printf 'fake-igt' | base64; exit 0 ;;
    *.data.pat*) printf 'fake-pat' | base64; exit 0 ;;
  esac
done
exit 1
KUBECTL

# --- fake curl: canned response per "<METHOD>_<path>", optional per-call ----
# Response files in $FAKE_SCN:  <key>.code / <key>.body, or <key>.<n>.code /
# <key>.<n>.body for the n-th call to that key, or <key>.fail to simulate a
# connection error (exit 7, status 000). Every request is appended to
# $FAKE_SCN/requests.log as "<METHOD> <path> <data>".
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
# Reject either secret in argv before parsing; fakes alone reach this process.
for argument in "$@"; do
  case "$argument" in
    *fake-igt*|*fake-pat*) echo 'secret appeared in curl argv' >&2; exit 97 ;;
  esac
done
cat >/dev/null  # the --config on stdin (carries the fake PAT)
method=GET out=/dev/stdout fmt= url= data=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    -d|--data-binary)
      data=$2
      case "$data" in @*) data=$(cat "${data#@}") ;; esac
      shift 2 ;;
    -H|--config) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
path=${url#*/management/v1/}
if [ "$method" = GET ] && [[ "$path" == actions/* ]] && [ "$out" != /dev/stdout ]; then
  echo 'Action response must not be written to disk' >&2
  exit 96
fi
key="${method}_$(printf '%s' "$path" | tr '/' '_')"
n_file="$FAKE_SCN/.count_$key"
n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$n_file"
printf '%s %s %s\n' "$method" "$path" "$data" >>"$FAKE_SCN/requests.log"
if [ -e "$FAKE_SCN/$key.fail" ]; then
  [ -n "$fmt" ] && printf '000'
  exit 7
fi
base="$FAKE_SCN/$key"
[ -e "$base.$n.code" ] && base="$base.$n"
if [ ! -e "$base.code" ]; then
  echo "fake curl: no canned response for $key (call $n)" >&2
  [ -n "$fmt" ] && printf '000'
  exit 7
fi
cat "$base.body" >"$out" 2>/dev/null || : >"$out"
if [ -n "$fmt" ]; then
  [[ "$fmt" == *'\n'* ]] && printf '\n'
  printf '%s' "$(cat "$base.code")"
fi
exit 0
CURL
chmod +x "$BIN/kubectl" "$BIN/curl"

# respond SCN KEY CODE BODY
respond() { printf '%s' "$3" >"$1/$2.code"; printf '%s' "$4" >"$1/$2.body"; }

SEARCH_EXISTING='{"result":[{"id":"A1","name":"setIdentityClaims"},{"id":"R1","name":"complementTokenClaims"}]}'
SEARCH_NONE='{"result":[{"id":"R1","name":"complementTokenClaims"}]}'
# Zitadel v1 shape: the trigger key is nested under name.
FLOW_R1_A1='{"flow":{"triggerActions":[{"triggerType":{"id":"4","name":{"key":"TRIGGER_TYPE_PRE_USERINFO_CREATION","localizedMessage":"Pre Userinfo creation"}},"actions":[{"id":"R1","name":"complementTokenClaims"},{"id":"A1","name":"setIdentityClaims"}]},{"triggerType":{"id":"5","name":{"key":"TRIGGER_TYPE_PRE_ACCESS_TOKEN_CREATION"}},"actions":[{"id":"X9","name":"other"}]}]}}'
FLOW_R1='{"flow":{"triggerActions":[{"triggerType":{"id":"4","name":{"key":"TRIGGER_TYPE_PRE_USERINFO_CREATION"}},"actions":[{"id":"R1","name":"complementTokenClaims"}]}]}}'
FLOW_R1_N1='{"flow":{"triggerActions":[{"triggerType":{"id":"4","name":{"key":"TRIGGER_TYPE_PRE_USERINFO_CREATION"}},"actions":[{"id":"R1","name":"complementTokenClaims"},{"id":"N1","name":"setIdentityClaims"}]}]}}'
FLOW_ONLY_A1='{"flow":{"triggerActions":[{"triggerType":{"id":"4","name":{"key":"TRIGGER_TYPE_PRE_USERINFO_CREATION"}},"actions":[{"id":"A1","name":"setIdentityClaims"}]}]}}'

# Base scenario: precheck ok, action exists, update ok, attach ok.
new_scn() {
  local s="$WORK/scn-$1"
  mkdir -p "$s"
  respond "$s" POST_actions__search 200 "$SEARCH_EXISTING"
  respond "$s" PUT_actions_A1 200 '{}'
  python3 - "$ROOT/zitadel-actions/complementTokenClaims.js" "$s" <<'PYFIXTURE'
import json, pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text().replace("'<set-me-in-the-zitadel-console-only>'", json.dumps('fake-igt'))
src = re.sub(r'\bfunction\s+complementTokenClaims\s*\(', 'function setIdentityClaims(', src)
action = {'action': {'name': 'setIdentityClaims', 'script': src, 'timeout': '10.000s', 'allowedToFail': True}}
pathlib.Path(sys.argv[2], 'desired-action.json').write_text(json.dumps(action))
PYFIXTURE
  respond "$s" GET_actions_A1.1 200 '{"action":{"name":"setIdentityClaims","script":"old script","timeout":"10s","allowedToFail":true}}'
  respond "$s" GET_actions_A1 200 "$(cat "$s/desired-action.json")"
  respond "$s" GET_actions_N1 200 "$(cat "$s/desired-action.json")"
  respond "$s" POST_flows_2_trigger_4 200 '{}'
  respond "$s" GET_flows_2 200 "$FLOW_R1_A1"
  echo "$s"
}

# run_scn SCN -> sets RC and OUT (stdout+stderr)
run_scn() {
  set +e
  OUT=$(FAKE_SCN="$1" PATH="$BIN:$PATH" KUBECONFIG_PATH="$WORK/none" bash "$SCRIPT" 2>&1)
  RC=$?
  set -e
}

PASS=0 FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() {
  echo "  FAIL $1"
  while IFS= read -r line; do echo "       | $line"; done <<<"$OUT"
  FAIL=$((FAIL + 1))
}
attached() { grep -q '^POST flows/2/trigger/' "$1/requests.log" 2>/dev/null; }

# 1. happy path, existing action: list kept, before/after printed, exit 0
s=$(new_scn happy)
respond "$s" POST_flows_2_trigger_4 400 '{"code":9,"message":"NoChanges COMMAND-Nfh52"}'
run_scn "$s"
if [ "$RC" = 0 ] && ! attached "$s" && [ "$(grep -c '^GET flows/2 ' "$s/requests.log")" = 2 ] \
  && grep -q 'BEFORE: R1(complementTokenClaims) A1(setIdentityClaims)' <<<"$OUT" \
  && grep -q 'AFTER : R1(complementTokenClaims) A1(setIdentityClaims)' <<<"$OUT" \
  && grep -q '^PUT actions/A1 .*fake-igt' "$s/requests.log" \
  && grep -q '^Stored' <<<"$OUT"; then ok 'unchanged trigger skips NoChanges attach, still verifies twice and updates action securely'; else bad 'unchanged trigger'; fi

# 2. G1: the flows/2 GET fails -> stop BEFORE the trigger POST
s=$(new_scn flow500); respond "$s" GET_flows_2 500 '{"code":13,"message":"internal"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s" && ! grep -q '^Stored' <<<"$OUT" && grep -q '"message":"internal"' <<<"$OUT"; then
  ok 'failed flows/2 read aborts before attach and shows the error body'; else bad 'failed flows/2 read'; fi

# 3. flows/2 200 but no flow object -> refuse, no attach
s=$(new_scn flowempty); respond "$s" GET_flows_2 200 '{}'; run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s"; then ok '200 without a flow object aborts before attach'; else bad 'flow object missing'; fi

# 4. flows/2 network failure -> refuse, no attach
s=$(new_scn flownet); rm "$s/GET_flows_2.code"; touch "$s/GET_flows_2.fail"; run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s"; then ok 'network failure on flows/2 aborts before attach'; else bad 'flows/2 network failure'; fi

# 5. a trigger entry whose type cannot be identified -> refuse
s=$(new_scn flowunknown); respond "$s" GET_flows_2 200 '{"flow":{"triggerActions":[{"triggerType":{"id":"4"},"actions":[{"id":"R1"}]}]}}'; run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s"; then ok 'unidentifiable trigger type aborts before attach'; else bad 'unidentifiable trigger'; fi

# 6. G2: PUT update 400 -> exit non-zero, body shown, flow untouched
s=$(new_scn put400); respond "$s" PUT_actions_A1 400 '{"message":"script invalid"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q 'flows/2' "$s/requests.log" && grep -q 'script invalid' <<<"$OUT"; then
  ok 'update 400 exits non-zero with the body, flow untouched'; else bad 'update 400'; fi

# 7. attach 200 but the re-read lost R1 -> exit 1 naming R1
s=$(new_scn lost)
respond "$s" GET_flows_2.1 200 "$FLOW_R1_A1"; respond "$s" GET_flows_2.2 200 "$FLOW_ONLY_A1"; run_scn "$s"
if [ "$RC" != 0 ] && grep -q 'missing: R1' <<<"$OUT" && ! grep -q '^Stored' <<<"$OUT"; then
  ok 'post-attach re-read missing R1 exits non-zero and names it'; else bad 'post-attach re-read'; fi

# 8. attach 500 -> non-zero, no "Stored"
s=$(new_scn attach500); respond "$s" GET_flows_2.1 200 "$FLOW_R1"; respond "$s" POST_flows_2_trigger_4 500 '{"message":"boom"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q '^Stored' <<<"$OUT" && grep -q 'boom' <<<"$OUT"; then ok 'attach 500 exits non-zero'; else bad 'attach 500'; fi

# 9. new action: create -> id N1 appended after R1
s=$(new_scn create)
respond "$s" POST_actions__search 200 "$SEARCH_NONE"; respond "$s" POST_actions 200 '{"id":"N1"}'
respond "$s" GET_flows_2.1 200 "$FLOW_R1"; respond "$s" GET_flows_2.2 200 "$FLOW_R1_N1"; run_scn "$s"
if [ "$RC" = 0 ] && grep -q 'POST flows/2/trigger/4 {"actionIds":\["R1", "N1"\]}' "$s/requests.log" \
  && grep -q '^POST actions .*fake-igt' "$s/requests.log"; then
  ok 'create path merges R1 + N1'; else bad 'create path'; fi

# 10. actions/_search 500 -> stop, no duplicate create
s=$(new_scn search500); respond "$s" POST_actions__search.2 500 '{"message":"db down"}'
respond "$s" POST_actions__search.1 200 "$SEARCH_EXISTING"; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q '^POST actions ' "$s/requests.log" && ! grep -q '^PUT ' "$s/requests.log"; then
  ok 'failed search aborts instead of creating a duplicate'; else bad 'search 500'; fi

# 11. precheck network failure -> exit 1, nothing else sent
s=$(new_scn precheck); touch "$s/POST_actions__search.fail"; run_scn "$s"
if [ "$RC" = 1 ] && [ "$(wc -l <"$s/requests.log")" -eq 1 ]; then ok 'precheck network failure exits 1, nothing else sent'; else bad 'precheck network failure'; fi

# 12. old flat triggerType.key shape is still recognised
s=$(new_scn flatkey)
respond "$s" GET_flows_2 200 '{"flow":{"triggerActions":[{"triggerType":{"id":"4","key":"PreUserinfoCreation"},"actions":[{"id":"R1","name":"complementTokenClaims"},{"id":"A1","name":"setIdentityClaims"}]}]}}'
run_scn "$s"
if [ "$RC" = 0 ] && ! attached "$s" && grep -q 'AFTER : R1(complementTokenClaims) A1(setIdentityClaims)' <<<"$OUT"; then ok 'flat triggerType.key shape parsed'; else bad 'flat key shape'; fi

# 13. existing action not yet attached: append it without losing existing actions.
s=$(new_scn existing-missing)
respond "$s" GET_flows_2.1 200 "$FLOW_R1"; run_scn "$s"
if [ "$RC" = 0 ] && grep -q 'POST flows/2/trigger/4 {"actionIds":\["R1", "A1"\]}' "$s/requests.log"; then
  ok 'existing unattached action is appended and verified'; else bad 'existing action attach'; fi

# 14. skipping an unchanged write must not skip verification of the live list.
s=$(new_scn unchanged-read-fails)
respond "$s" GET_flows_2.2 500 '{"message":"verification unavailable"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s" && ! grep -q '^Stored' <<<"$OUT"; then
  ok 'unchanged trigger still fails when verification cannot be read'; else bad 'unchanged verification'; fi

# 15. Unchanged action must not call PUT, even when provider refuses no-op updates.
s=$(new_scn unchanged-action)
respond "$s" GET_actions_A1.1 200 "$(cat "$s/desired-action.json")"
respond "$s" PUT_actions_A1 400 '{"code":9,"message":"NoChanges ACTION-dg4t2"}'
run_scn "$s"
if [ "$RC" = 0 ] && ! grep -q '^PUT actions/' "$s/requests.log" && [ "$(grep -c '^GET actions/A1 ' "$s/requests.log")" = 2 ]; then
  ok 'unchanged normalized Action skips PUT and verifies stored content'; else bad 'unchanged Action update'; fi

# 16. Unreadable before-state must fail closed without an update or attach.
s=$(new_scn action-read-fails); respond "$s" GET_actions_A1.1 500 '{"message":"read unavailable"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q '^PUT actions/' "$s/requests.log" && ! attached "$s"; then
  ok 'failed Action read aborts before mutation'; else bad 'Action pre-read'; fi

# 17. A successful update with mismatched content is not accepted.
s=$(new_scn action-mismatch)
respond "$s" GET_actions_A1 200 '{"action":{"name":"setIdentityClaims","script":"wrong script","timeout":"10s","allowedToFail":true}}'
run_scn "$s"
if [ "$RC" != 0 ] && ! attached "$s" && ! grep -q '^Stored' <<<"$OUT"; then
  ok 'post-update mismatch stops before trigger changes'; else bad 'Action verification mismatch'; fi

# 18. Verification is mandatory even when the initial Action was identical.
s=$(new_scn action-verify-fails)
respond "$s" GET_actions_A1.1 200 "$(cat "$s/desired-action.json")"
respond "$s" GET_actions_A1 500 '{"message":"verify unavailable"}'
run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q '^PUT actions/' "$s/requests.log" && ! attached "$s"; then
  ok 'unchanged Action still fails on verification read error'; else bad 'Action verify read'; fi

# 19. Missing settings are not treated as an identical Action.
s=$(new_scn action-malformed); respond "$s" GET_actions_A1.1 200 '{"action":{"name":"setIdentityClaims"}}'; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q '^PUT actions/' "$s/requests.log" && ! attached "$s"; then
  ok 'malformed Action response fails closed'; else bad 'malformed Action'; fi

# 20. Action error payloads may contain scripts/secrets and must be suppressed.
s=$(new_scn action-error-secret); respond "$s" GET_actions_A1.1 500 '{"script":"fake-igt"}'; run_scn "$s"
if [ "$RC" != 0 ] && ! grep -q 'fake-igt' <<<"$OUT" && grep -q 'response suppressed' <<<"$OUT"; then
  ok 'Action response remains memory-only and error body is suppressed'; else bad 'Action error redaction'; fi

echo
echo "$PASS/$((PASS + FAIL)) passed"
[ "$FAIL" = 0 ]
