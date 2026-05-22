#!/usr/bin/env bash
# Lints all YAML files and shell scripts in the repo.
# Requires: yamllint (pip install yamllint), shellcheck (brew install shellcheck)
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "    PASS: $1"; ((PASS++)); }
fail() { echo "    FAIL: $1 — $2"; ((FAIL++)); }

echo "===> [1/2] YAML lint"
if command -v yamllint &>/dev/null; then
  for f in routes/*.yaml helm/apisix/values.yaml helm/zitadel/values.yaml; do
    if yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' "$f" &>/dev/null; then
      pass "$f"
    else
      yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' "$f"
      fail "$f" "yamllint errors above"
    fi
  done
else
  echo "    SKIP: yamllint not installed (pip install yamllint)"
fi

echo ""
echo "===> [2/2] Shell script lint (shellcheck)"
if command -v shellcheck &>/dev/null; then
  for f in k3s/*.sh helm/deploy.sh tests/*.sh tests/smoke/*.sh; do
    if shellcheck "$f" &>/dev/null; then
      pass "$f"
    else
      shellcheck "$f"
      fail "$f" "shellcheck errors above"
    fi
  done
else
  echo "    SKIP: shellcheck not installed (brew install shellcheck)"
fi

echo ""
echo "========================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All lint checks passed."
echo "========================================================"
