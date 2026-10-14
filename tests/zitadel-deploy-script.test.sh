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
[ -n "$fmt" ] && printf '%s' "$(cat "$base.code")"
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
s=$(new_scn happy); run_scn "$s"
if [ "$RC" = 0 ] && grep -q 'POST flows/2/trigger/4 {"actionIds":\["R1", "A1"\]}' "$s/requests.log" \
  && grep -q 'BEFORE: R1(complementTokenClaims) A1(setIdentityClaims)' <<<"$OUT" \
  && grep -q 'AFTER : R1(complementTokenClaims) A1(setIdentityClaims)' <<<"$OUT" \
  && grep -q '^PUT actions/A1 .*fake-igt' "$s/requests.log" \
  && grep -q '^Stored' <<<"$OUT"; then ok 'happy path keeps R1, sends token only in body, prints before/after, exits 0'; else bad 'happy path'; fi

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
s=$(new_scn attach500); respond "$s" POST_flows_2_trigger_4 500 '{"message":"boom"}'; run_scn "$s"
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
if [ "$RC" = 0 ] && grep -q '"actionIds":\["R1", "A1"\]' "$s/requests.log"; then ok 'flat triggerType.key shape parsed'; else bad 'flat key shape'; fi

echo
echo "$PASS/$((PASS + FAIL)) passed"
[ "$FAIL" = 0 ]
