/**
 * Unit test for zitadel-actions/complementTokenClaims.js.
 *
 * That file runs inside Zitadel's own JS runtime, so nothing in CI executes it —
 * the YAML/shell/Helm jobs do not look at it, and the Docker integration stack
 * exercises APISIX, not the IdP Action. A syntax error or an inverted guard here
 * would therefore ship green and only surface as a claim silently missing from
 * every token, which is exactly how suwalka_grant_caps went unnoticed from
 * 2026-08-03 until 2026-08-24.
 *
 * So this stubs the two Zitadel modules and the api/ctx objects, runs the real
 * function, and asserts which claims get set and with what values.
 *
 * Run: node tests/zitadel-action-claims.test.js
 */
'use strict';

const assert = require('assert');
const Module = require('module');
const path = require('path');
const fs = require('fs');

const ACTION_PATH = path.join(__dirname, '..', 'zitadel-actions', 'complementTokenClaims.js');

// The Action calls require('zitadel/http') and require('zitadel/log'), neither of
// which exists outside Zitadel. Intercept just those two.
let nextResponse;
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'zitadel/http') {
    return { fetch: () => nextResponse };
  }
  if (request === 'zitadel/log') {
    return { log: () => {} };
  }
  return originalLoad.apply(this, arguments);
};

// The file declares a bare function and is pasted into a console, so it has no
// exports. Evaluate it and hand back the function.
function loadAction() {
  const src = fs.readFileSync(ACTION_PATH, 'utf8');
  // eslint-disable-next-line no-new-func
  const factory = new Function('require', 'module', 'exports', `${src}\nreturn complementTokenClaims;`);
  return factory(require, { exports: {} }, {});
}

const complementTokenClaims = loadAction();

function run(result, { status = 200 } = {}) {
  nextResponse = { status, json: () => ({ result }) };
  const set = {};
  const api = { v1: { claims: { setClaim: (k, v) => { set[k] = v; } } } };
  const ctx = { v1: { getUser: () => ({ id: 'sub-1' }) } };
  complementTokenClaims(ctx, api);
  return set;
}

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

// --- suwalka_grant_caps: THREE-state. The empty array is the whole point. ---

check('grant_caps [] is SENT, not dropped — "covers nothing" must not become "covers everything"', () => {
  const set = run({ suwalka_grant_caps: [] });
  assert.ok('suwalka_grant_caps' in set, 'claim was dropped; absent reads as pre-matrix = unrestricted');
  assert.deepStrictEqual(set.suwalka_grant_caps, []);
});

check('grant_caps null is NOT sent — absent is the deliberate pre-matrix fail-open', () => {
  const set = run({ suwalka_grant_caps: null });
  assert.ok(!('suwalka_grant_caps' in set));
});

check('grant_caps rows pass through verbatim', () => {
  const rows = [{ module: 'hrms', scope: 'department', targetId: 'd1' }];
  assert.deepStrictEqual(run({ suwalka_grant_caps: rows }).suwalka_grant_caps, rows);
});

// --- suwalka_levels: absent means DENY, so the empty array must still be sent. ---

check('levels [] is SENT', () => {
  const set = run({ suwalka_levels: [] });
  assert.ok('suwalka_levels' in set);
  assert.deepStrictEqual(set.suwalka_levels, []);
});

check('levels rows pass through verbatim', () => {
  const rows = [{ module: 'hrms', level: 'approve', scope: 'outlet' }];
  assert.deepStrictEqual(run({ suwalka_levels: rows }).suwalka_levels, rows);
});

check('levels absent from the payload sets nothing', () => {
  assert.ok(!('suwalka_levels' in run({ suwalka_caps: ['hrms:org'] })));
});

// --- the five pre-existing claims keep their exact behaviour ---

check('the original five still set when populated', () => {
  const set = run({
    suwalka_admin: ['super'],
    suwalka_caps: ['hrms:org'],
    suwalka_identity: { employeeId: 'e1' },
    suwalka_outlet_set: ['o1'],
    suwalka_dept_set: ['d1'],
  });
  assert.deepStrictEqual(set.suwalka_admin, ['super']);
  assert.deepStrictEqual(set.suwalka_caps, ['hrms:org']);
  assert.deepStrictEqual(set.suwalka_identity, { employeeId: 'e1' });
  assert.deepStrictEqual(set.suwalka_outlet_set, ['o1']);
  assert.deepStrictEqual(set.suwalka_dept_set, ['d1']);
});

check('the original five keep dropping empties — unchanged by this work', () => {
  const set = run({ suwalka_admin: [], suwalka_caps: [], suwalka_outlet_set: [], suwalka_dept_set: [] });
  ['suwalka_admin', 'suwalka_caps', 'suwalka_outlet_set', 'suwalka_dept_set'].forEach((k) => {
    assert.ok(!(k in set), `${k} should still be omitted when empty`);
  });
});

// --- fail-open on the login path is not negotiable ---

check('a non-200 sets no claims and does not throw', () => {
  assert.deepStrictEqual(run({ suwalka_caps: ['hrms:org'] }, { status: 503 }), {});
});

check('a fetch that throws does not block login', () => {
  const set = {};
  const api = { v1: { claims: { setClaim: (k, v) => { set[k] = v; } } } };
  const ctx = { v1: { getUser: () => ({ id: 'sub-1' }) } };
  nextResponse = null;
  Module._load = function (request) {
    if (request === 'zitadel/http') return { fetch: () => { throw new Error('unreachable'); } };
    if (request === 'zitadel/log') return { log: () => {} };
    return originalLoad.apply(this, arguments);
  };
  const fresh = loadAction();
  assert.doesNotThrow(() => fresh(ctx, api));
  assert.deepStrictEqual(set, {});
});

let failed = 0;
for (const [name, fn] of checks) {
  try {
    fn();
    console.log(`  ok   ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`  FAIL ${name}\n       ${err.message}`);
  }
}
console.log(`\n${checks.length - failed}/${checks.length} passed`);
process.exit(failed === 0 ? 0 : 1);
