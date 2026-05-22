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
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All route files are valid."
echo "========================================================"
