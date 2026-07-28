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
echo "===> Checking public rules nested inside a protected prefix pin their path (preflight-shadowing guard)"
# 2026-07-28. A PUBLIC rule that sits INSIDE a JWT-protected wildcard prefix and
# lists OPTIONS does not merely serve its own path — with a higher `priority` it
# wins the OPTIONS match for EVERY deeper path under that prefix, and answers the
# CORS preflight for its AUTHENTICATED siblings with its own narrow
# `allow_methods`. Browsers then refuse to send the real request, while curl,
# jest and Bruno — none of which preflight — stay green.
#
# That is exactly what `suwalka-gatepass-public` (/api/recruitment/gatepass/*,
# priority 10, GET+OPTIONS, cors allow_methods "GET,OPTIONS") did to
# `POST /api/recruitment/gatepass/{id}/send` and `.../revoke` in production.
# Measured live 2026-07-28: the preflight for both returned
# `access-control-allow-methods: GET,OPTIONS`, so admin-web's "Send QR gatepass"
# and "Revoke" buttons could not fire at all.
#
# The fix is a `match.exprs` Path RegexMatch pinning the exact path shape the
# public rule owns, so deeper siblings fall through to the protected rule. This
# check enforces that structurally: nothing else does, and the failure mode is
# invisible to every non-browser test in the estate.
#
# NOTE: the preferred design is still a dedicated prefix nothing else claims
# (/api/public/<feature>/*, as suwalka-assessment-public and
# suwalka-resume-public use) — such a rule is not nested and never trips this
# check. The exprs pin is for the case where the public path is already issued
# to the outside world and cannot be moved.
python3 - routes/*.yaml <<'PYEOF'
import sys, yaml

def load_rules(paths):
    out = []
    for path in paths:
        with open(path) as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get('kind') != 'ApisixRoute':
                    continue
                for rule in doc.get('spec', {}).get('http', []) or []:
                    match = rule.get('match', {}) or {}
                    plugins = rule.get('plugins', []) or []
                    names = {p.get('name') for p in plugins if isinstance(p, dict)}
                    out.append({
                        'file': path,
                        'name': rule.get('name', '<unnamed>'),
                        'hosts': set(match.get('hosts') or []),
                        'paths': list(match.get('paths') or []),
                        # No `methods` key means EVERY method, OPTIONS included.
                        'methods': set(m.upper() for m in (match.get('methods') or [])) or None,
                        'protected': 'openid-connect' in names,
                        'path_pinned': any(
                            (e.get('subject') or {}).get('scope') == 'Path'
                            for e in (match.get('exprs') or [])
                        ),
                    })
    return out

def prefixes(rule):
    """Wildcard prefixes this rule claims, e.g. '/api/recruitment/*' -> '/api/recruitment/'."""
    return [p[:-1] for p in rule['paths'] if p.endswith('*')]

rules = load_rules(sys.argv[1:])
protected = [r for r in rules if r['protected'] and prefixes(r)]

violations = []
for pub in rules:
    if pub['protected'] or pub['path_pinned']:
        continue
    # Only rules that answer OPTIONS can steal a preflight.
    if pub['methods'] is not None and 'OPTIONS' not in pub['methods']:
        continue
    for pub_prefix in prefixes(pub):
        for prot in protected:
            if not (pub['hosts'] & prot['hosts']):
                continue
            for prot_prefix in prefixes(prot):
                # Strictly nested: the public prefix lives INSIDE the protected one.
                if pub_prefix != prot_prefix and pub_prefix.startswith(prot_prefix):
                    violations.append(
                        f"{pub['file']}: PUBLIC rule '{pub['name']}' claims '{pub_prefix}*' "
                        f"with OPTIONS, nested inside PROTECTED rule '{prot['name']}' "
                        f"({prot['file']}) which claims '{prot_prefix}*'. It will answer the "
                        f"CORS preflight for every authenticated endpoint deeper than "
                        f"'{pub_prefix}' with its own allow_methods, and browsers will block "
                        f"those calls while curl/jest/Bruno stay green. Either move the public "
                        f"path to a prefix nothing else claims (preferred), or add a "
                        f"match.exprs entry with subject.scope: Path pinning the exact path "
                        f"this rule owns (see suwalka-gatepass-public in routes/public.yaml)."
                    )

if violations:
    print("  FAIL: preflight-shadowing guard — a public rule is nested in a protected prefix:")
    for v in sorted(set(violations)):
        print(f"    - {v}")
    sys.exit(1)
else:
    print("  PASS: every public rule nested in a protected prefix pins its path with match.exprs")
PYEOF

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All route files are valid."
echo "========================================================"
