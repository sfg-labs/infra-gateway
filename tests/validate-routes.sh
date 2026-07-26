#!/usr/bin/env bash
# Validates ApisixRoute YAML files for correct structure and required fields.
# No cluster connection required — pure YAML schema validation.
# Requires: python3 + pyyaml (pip install pyyaml)
set -euo pipefail

PASS=0
FAIL=0

validate_route() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
with open(path) as f:
    docs = list(yaml.safe_load_all(f))

errors = []
for doc in docs:
    if doc is None:
        continue

    # Required top-level fields
    for field in ('apiVersion', 'kind', 'metadata', 'spec'):
        if field not in doc:
            errors.append(f"Missing required field: {field}")

    if not doc.get('apiVersion', '').startswith('apisix.apache.org'):
        errors.append(f"apiVersion must be apisix.apache.org/v2, got: {doc.get('apiVersion')}")

    if doc.get('kind') != 'ApisixRoute':
        errors.append(f"kind must be ApisixRoute, got: {doc.get('kind')}")

    meta = doc.get('metadata', {})
    if not meta.get('name'):
        errors.append("metadata.name is required")
    if not meta.get('namespace'):
        errors.append("metadata.namespace is required")

    spec = doc.get('spec', {})
    http_rules = spec.get('http', [])
    if not http_rules:
        errors.append("spec.http must have at least one rule")

    for rule in http_rules:
        if not rule.get('name'):
            errors.append("Each http rule must have a name")
        match = rule.get('match', {})
        if not match.get('paths'):
            errors.append(f"Rule '{rule.get('name')}' must have match.paths")
        backends = rule.get('backends', [])
        if not backends:
            errors.append(f"Rule '{rule.get('name')}' must have at least one backend")
        for b in backends:
            if not b.get('serviceName'):
                errors.append(f"Rule '{rule.get('name')}' backend missing serviceName")
            if not b.get('servicePort'):
                errors.append(f"Rule '{rule.get('name')}' backend missing servicePort")

if errors:
    print(f"  FAIL: {path}")
    for e in errors:
        print(f"    - {e}")
    sys.exit(1)
else:
    print(f"  PASS: {path}")
PYEOF
}

echo "===> Validating ApisixRoute files"
for f in routes/*.yaml; do
  if validate_route "$f"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "===> Checking for duplicate route names across files"
python3 - routes/*.yaml <<'PYEOF'
import sys, yaml
from collections import defaultdict

names = defaultdict(list)
for path in sys.argv[1:]:
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if doc and doc.get('kind') == 'ApisixRoute':
                for rule in doc.get('spec', {}).get('http', []):
                    name = rule.get('name', '')
                    names[name].append(path)

dupes = {k: v for k, v in names.items() if len(v) > 1}
if dupes:
    print("  FAIL: Duplicate rule names found:")
    for name, files in dupes.items():
        print(f"    '{name}' in: {', '.join(files)}")
    sys.exit(1)
else:
    print("  PASS: No duplicate route names")
PYEOF

echo ""
echo "===> Checking zimma /zimma/api/auth/ paths stay explicit (F1 static guard)"
# N2 (PR #33 round-2 review): F1 was a CRITICAL auth bypass — a wildcard on
# the unprotected zimma-api-app rule shadowed the exact, openid-connect-
# protected SSO rule for case/trailing-slash variants of
# /zimma/api/auth/sso. The fix (explicit login/signup paths, no wildcard)
# lives only in routes/zimma-api.yaml; nothing before this check enforced it
# structurally. validate-routes.sh only checks CRD schema + duplicate names,
# and the local Docker smoke stack (docker/apisix/setup-routes.sh +
# tests/smoke/smoke-test-local.sh) is a HAND-MAINTAINED MIRROR that CLAUDE.md
# explicitly says does not auto-sync with routes/*.yaml — so restoring the
# wildcard in routes/zimma-api.yaml ALONE would reintroduce the bypass in
# production with all four CI jobs still green. This check reads the real
# production file directly: no rule lacking the openid-connect plugin may
# claim any path under /zimma/api/auth/ other than the explicit,
# already-reviewed login/signup forms.
python3 - routes/zimma-api.yaml <<'PYEOF'
import sys, yaml

AUTH_PREFIX = "/zimma/api/auth/"
ALLOWED_UNPROTECTED_PATHS = {
    "/zimma/api/auth/login",
    "/zimma/api/auth/login/",
    "/zimma/api/auth/signup",
    "/zimma/api/auth/signup/",
}

violations = []
for path in sys.argv[1:]:
    with open(path) as f:
        docs = list(yaml.safe_load_all(f))
    for doc in docs:
        if not doc or doc.get('kind') != 'ApisixRoute':
            continue
        for rule in doc.get('spec', {}).get('http', []) or []:
            plugins = rule.get('plugins', []) or []
            plugin_names = {p.get('name') for p in plugins if isinstance(p, dict)}
            if 'openid-connect' in plugin_names:
                continue  # protected rules may claim whatever they need under this prefix
            for p in (rule.get('match', {}) or {}).get('paths') or []:
                if p.startswith(AUTH_PREFIX) and p not in ALLOWED_UNPROTECTED_PATHS:
                    violations.append(
                        f"{path}: rule '{rule.get('name', '<unnamed>')}' claims path "
                        f"'{p}' under {AUTH_PREFIX} WITHOUT the openid-connect plugin, "
                        f"and '{p}' is not one of the explicit allowed paths "
                        f"{sorted(ALLOWED_UNPROTECTED_PATHS)} — this is the F1 auth-bypass "
                        f"shape (PR #33). Either add openid-connect to this rule or remove "
                        f"the path."
                    )

if violations:
    print("  FAIL: F1 static guard — unprotected rule claims a non-explicit auth path:")
    for v in violations:
        print(f"    - {v}")
    sys.exit(1)
else:
    print("  PASS: no unprotected rule claims a non-explicit path under /zimma/api/auth/")
PYEOF

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All route files are valid."
echo "========================================================"
