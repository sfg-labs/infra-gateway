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
//
// `nextResponse` may be a function: it is then called, so a check can make the
// fetch throw. `logged` records every logger.log call, so a check can prove a
// failure was REPORTED and not just survived.
let nextResponse;
const logged = [];
const stubLogger = { log: (...args) => { logged.push(args.map(String).join(' ')); } };
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'zitadel/http') {
    return { fetch: () => (typeof nextResponse === 'function' ? nextResponse() : nextResponse) };
  }
  if (request === 'zitadel/log') {
    return stubLogger;
  }
  return originalLoad.apply(this, arguments);
};
// The stub above is what every check except the throwing one needs. Keep a
// handle so that check can put THIS back — restoring `originalLoad` instead
// removes the zitadel/* stub too, and every later require fails.
const stubLoad = Module._load;

// The file declares a bare function and is pasted into a console, so it has no
// exports. Evaluate it and hand back the function.
function loadAction() {
  const src = fs.readFileSync(ACTION_PATH, 'utf8');
  // eslint-disable-next-line no-new-func
  const factory = new Function('require', 'module', 'exports', `${src}\nreturn complementTokenClaims;`);
  return factory(require, { exports: {} }, {});
}

const complementTokenClaims = loadAction();

/**
 * Returns the USERINFO surface, deliberately.
 *
 * `api.v1.claims.setClaim` writes the TOKEN's claims. `api.v1.userinfo.setClaim`
 * writes the userinfo response — and APISIX base64s ONLY the userinfo response
 * into `X-Userinfo`, which is the only thing `readUser()` ever sees. An earlier
 * version of this file stubbed just `claims`, so it asserted the surface no
 * backend reads, and would have passed on an Action that delivered nothing.
 *
 * That is not hypothetical: the live `setIdentityClaims` was in exactly that
 * state — attached, ACTIVE, calling only `claims.setClaim`, contributing
 * nothing to userinfo — for weeks.
 */
function runBoth(result, { status = 200 } = {}) {
  nextResponse = { status, json: () => ({ result }) };
  const userinfo = {};
  const claims = {};
  const api = {
    v1: {
      userinfo: { setClaim: (k, v) => { userinfo[k] = v; } },
      claims: { setClaim: (k, v) => { claims[k] = v; } },
    },
  };
  const ctx = { v1: { getUser: () => ({ id: 'sub-1' }) } };
  complementTokenClaims(ctx, api);
  return { userinfo, claims };
}

function run(result, opts) {
  return runBoth(result, opts).userinfo;
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
  try {
    assert.doesNotThrow(() => fresh(ctx, api));
    assert.deepStrictEqual(set, {});
  } finally {
    // RESTORE. This check replaces the module loader globally, and without
    // putting it back every later check runs against a fetch that throws — so
    // they observe no claims and fail for a reason that has nothing to do with
    // what they assert. Found when two checks appended after this one failed
    // with an empty claim set.
    Module._load = stubLoad;
  }
});

// --- BOTH surfaces, because only one of them reaches a backend ---

check('every claim lands on the USERINFO surface, which is what X-Userinfo carries', () => {
  const { userinfo } = runBoth({
    suwalka_admin: ['super'],
    suwalka_caps: ['hrms:org'],
    suwalka_identity: { employeeId: 'e1' },
    suwalka_outlet_set: ['o1'],
    suwalka_dept_set: ['d1'],
    suwalka_grant_caps: [],
    suwalka_levels: [],
  });
  for (const key of ['suwalka_admin', 'suwalka_caps', 'suwalka_identity',
                     'suwalka_outlet_set', 'suwalka_dept_set',
                     'suwalka_grant_caps', 'suwalka_levels']) {
    assert.ok(key in userinfo, `${key} never reached userinfo — X-Userinfo would not carry it`);
  }
});

check('the token surface receives exactly the same set — neither is favoured', () => {
  const payload = {
    suwalka_admin: ['super'],
    suwalka_caps: ['hrms:org'],
    suwalka_grant_caps: [{ module: 'hrms', scope: 'org' }],
    suwalka_levels: [{ module: 'hrms', level: 'approve' }],
  };
  const { userinfo, claims } = runBoth(payload);
  assert.deepStrictEqual(Object.keys(userinfo).sort(), Object.keys(claims).sort());
  for (const k of Object.keys(userinfo)) assert.deepStrictEqual(claims[k], userinfo[k]);
});

check('one surface throwing does not suppress the other', () => {
  // On a trigger where only one surface exists, Zitadel throws on the other.
  // A single try around both would silently drop the one that WAS available.
  nextResponse = { status: 200, json: () => ({ result: { suwalka_caps: ['hrms:org'] } }) };
  const claims = {};
  const api = {
    v1: {
      userinfo: { setClaim: () => { throw new Error('no userinfo on this trigger'); } },
      claims: { setClaim: (k, v) => { claims[k] = v; } },
    },
  };
  complementTokenClaims({ v1: { getUser: () => ({ id: 'sub-1' }) } }, api);
  assert.deepStrictEqual(claims.suwalka_caps, ['hrms:org']);
});

// --- suwalka_dealer: an OBJECT or absent. Absent = no dealership access. ---

const DEALER = {
  v: 1, pack: 'teamlead', fn: ['customer-care'],
  m: { 'dealer-voice': ['subtree', 'edit', 1] },
  x: [{ m: 'dealer-leads', outlet: '11111111-2222-3333-4444-555555555555', from: '2026-11-01', to: '2026-11-14', a: 'edit', f: [] }],
};

// The claim as received, plus `at`. Returns `at` so callers can bound it.
function assertDealerWithAt(got, label) {
  assert.ok(got && typeof got === 'object', `${label}: suwalka_dealer missing`);
  const { at, ...rest } = got;
  assert.deepStrictEqual(rest, DEALER, `${label}: claim body was reshaped`);
  assert.ok(Number.isInteger(at), `${label}: at must be integer epoch seconds, got ${at}`);
  return at;
}

check('dealer object reaches BOTH surfaces as received, plus `at` = mint time in integer seconds', () => {
  const before = Math.floor(Date.now() / 1000);
  const { userinfo, claims } = runBoth({ suwalka_dealer: DEALER });
  const after = Math.floor(Date.now() / 1000);
  for (const [label, got] of [['userinfo', userinfo.suwalka_dealer], ['claims', claims.suwalka_dealer]]) {
    const at = assertDealerWithAt(got, label);
    assert.ok(at >= before && at <= after, `${label}: at ${at} not within [${before}, ${after}]`);
  }
  assert.ok(!('at' in DEALER), 'the resolver payload must not be mutated');
});

check('dev Action: a setClaim that throws is LOGGED, not swallowed', () => {
  logged.length = 0;
  nextResponse = { status: 200, json: () => ({ result: { suwalka_dealer: DEALER } }) };
  const api = {
    v1: {
      userinfo: { setClaim: () => { throw new Error('value rejected'); } },
      claims: { setClaim: () => {} },
    },
  };
  complementTokenClaims({ v1: { getUser: () => ({ id: 'sub-1' }) } }, api);
  assert.ok(logged.some((l) => l.includes('userinfo.setClaim(suwalka_dealer) failed') && l.includes('value rejected')),
    `no log line for the failed setClaim; got ${JSON.stringify(logged)}`);
});

// Runs the dev Action with a custom `api.v1` and returns what was logged.
function runDevWith(v1, result) {
  logged.length = 0;
  nextResponse = { status: 200, json: () => (result === undefined ? { error: false } : { result }) };
  assert.doesNotThrow(() => complementTokenClaims({ v1: { getUser: () => ({ id: 'sub-1' }) } }, { v1 }),
    'the dev Action must never block login');
  return logged.slice();
}

check('dev Action: a 200 without `result` sets nothing and LOGS it', () => {
  const set = {};
  const log = runDevWith({ userinfo: { setClaim: (k, v) => { set[k] = v; } } }, undefined);
  assert.deepStrictEqual(set, {});
  assert.ok(log.some((l) => l.includes('200 without a result field') && l.includes('sub-1')), JSON.stringify(log));
});

check('dev Action: a surface ABSENT on this trigger is quiet, the other still set', () => {
  const claims = {};
  const log = runDevWith({ claims: { setClaim: (k, v) => { claims[k] = v; } } }, { suwalka_caps: ['hrms:org'] });
  assert.deepStrictEqual(claims.suwalka_caps, ['hrms:org']);
  assert.ok(!log.some((l) => l.includes('setClaim')), `expected no setClaim log; got ${JSON.stringify(log)}`);
});

check('dev Action: "already exists" is quiet (metadata wins); the other surface still set', () => {
  const claims = {};
  const log = runDevWith({
    userinfo: { setClaim: () => { throw new Error('key already exists'); } },
    claims: { setClaim: (k, v) => { claims[k] = v; } },
  }, { suwalka_dealer: DEALER });
  assertDealerWithAt(claims.suwalka_dealer, 'claims after userinfo refused');
  assert.ok(!log.some((l) => l.includes('setClaim')), `expected no setClaim log; got ${JSON.stringify(log)}`);
});

check('dev Action: a present surface whose setClaim is not callable is LOGGED, not skipped', () => {
  const log = runDevWith({ userinfo: {}, claims: { setClaim: () => {} } }, { suwalka_caps: ['hrms:org'] });
  assert.ok(log.some((l) => l.includes('userinfo.setClaim(suwalka_caps) failed')), JSON.stringify(log));
});

check('dealer null is NOT sent (no pack = no claim)', () => {
  assert.ok(!('suwalka_dealer' in run({ suwalka_dealer: null })));
});

check('dealer array or string is NOT sent — only an object is a claim', () => {
  assert.ok(!('suwalka_dealer' in run({ suwalka_dealer: [DEALER] })));
  assert.ok(!('suwalka_dealer' in run({ suwalka_dealer: 'teamlead' })));
});

// --- the UAT Action carries the same line ---

function loadNamed(file, fnName) {
  const src = fs.readFileSync(path.join(__dirname, '..', 'zitadel-actions', file), 'utf8');
  // eslint-disable-next-line no-new-func
  return new Function('require', 'module', 'exports', `${src}\nreturn ${fnName};`)(require, { exports: {} }, {});
}

const live = loadNamed('uat/setIdentityClaimsLive.js', 'setIdentityClaimsLive');

// Runs the UAT Action with `response` as the fetch result (or a function to call
// instead, e.g. one that throws). Returns both surfaces and what was logged.
function runLive(response, { userinfoSet, claimsSet } = {}) {
  logged.length = 0;
  nextResponse = response;
  const userinfo = {};
  const claims = {};
  const api = {
    v1: {
      userinfo: { setClaim: userinfoSet || ((k, v) => { userinfo[k] = v; }) },
      claims: { setClaim: claimsSet || ((k, v) => { claims[k] = v; }) },
    },
  };
  assert.doesNotThrow(() => live({ v1: { getUser: () => ({ id: 'sub-1' }) } }, api), 'the UAT Action must never block login');
  return { userinfo, claims, logged: logged.slice() };
}
const ok = (result) => ({ status: 200, json: () => ({ result }) });

check('UAT setIdentityClaimsLive passes suwalka_dealer (+ at) to BOTH surfaces, drops null and arrays', () => {
  const { userinfo, claims } = runLive(ok({ suwalka_identity: { employeeId: 'e1' }, suwalka_dealer: DEALER }));
  assertDealerWithAt(userinfo.suwalka_dealer, 'UAT userinfo');
  assertDealerWithAt(claims.suwalka_dealer, 'UAT claims');
  assert.ok(!('suwalka_dealer' in runLive(ok({ suwalka_identity: { employeeId: 'e1' }, suwalka_dealer: null })).userinfo));
  assert.ok(!('suwalka_dealer' in runLive(ok({ suwalka_identity: { employeeId: 'e1' }, suwalka_dealer: [DEALER] })).userinfo));
});

check('UAT: a non-200 sets nothing and logs the status', () => {
  const r = runLive({ status: 503, json: () => ({ result: { suwalka_dealer: DEALER } }) });
  assert.deepStrictEqual([r.userinfo, r.claims], [{}, {}]);
  assert.ok(r.logged.some((l) => l.includes('resolver returned 503')), JSON.stringify(r.logged));
});

check('UAT: a fetch that throws sets nothing and logs the error', () => {
  const r = runLive(() => { throw new Error('connection refused'); });
  assert.deepStrictEqual([r.userinfo, r.claims], [{}, {}]);
  assert.ok(r.logged.some((l) => l.includes('resolver call failed') && l.includes('connection refused')), JSON.stringify(r.logged));
});

check('UAT: a 200 without `result` sets nothing and logs it', () => {
  const r = runLive({ status: 200, json: () => ({ error: false }) });
  assert.deepStrictEqual([r.userinfo, r.claims], [{}, {}]);
  assert.ok(r.logged.some((l) => l.includes('without a result field')), JSON.stringify(r.logged));
});

check('UAT: "already exists" is quiet (metadata wins); any other setClaim failure is logged', () => {
  const quiet = runLive(ok({ suwalka_identity: { employeeId: 'e1' }, suwalka_dealer: DEALER }), {
    userinfoSet: () => { throw new Error('key already exists'); },
  });
  assert.ok(!quiet.logged.some((l) => l.includes('setClaim')), `expected no setClaim log; got ${JSON.stringify(quiet.logged)}`);
  assertDealerWithAt(quiet.claims.suwalka_dealer, 'claims after userinfo refused');

  const loud = runLive(ok({ suwalka_identity: { employeeId: 'e1' }, suwalka_dealer: DEALER }), {
    claimsSet: () => { throw new Error('invalid claim value'); },
  });
  assert.ok(loud.logged.some((l) => l.includes('claims.setClaim(suwalka_dealer) failed') && l.includes('invalid claim value')),
    JSON.stringify(loud.logged));
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
