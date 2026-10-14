/**
 * Zitadel Action — Complement Token flow, "Pre Userinfo creation" trigger.
 *
 * Mints suwalka_admin / suwalka_caps / suwalka_identity / suwalka_outlet_set /
 * suwalka_dept_set / suwalka_grant_caps / suwalka_levels / suwalka_dealer custom claims into the
 * userinfo response (which APISIX's
 * openid-connect plugin forwards to every backend service as the base64 JSON
 * X-Userinfo header, decoded by @suwalka/common's readUser()).
 *
 * Calls suwalka-org-hr-payroll's already-deployed internal endpoint:
 *   GET http://suwalka-org-hr-payroll.sfg-labs.svc.cluster.local:3001/api/hr/internal/admin-grants/by-sub?sub=<zitadel-user-id>
 *   Header: X-Internal-Token: <INTERNAL_GRANT_TOKEN secret>
 * which returns { error, code, message, result: { suwalka_admin, suwalka_caps,
 * suwalka_identity, suwalka_outlet_set, suwalka_dept_set } }.
 *
 * Fail-open by design: an unmapped user (no employee row), a network error, or
 * a non-200 response must NOT block login — it just means the claims stay
 * absent, and every backend controller already treats an absent claim as "no
 * capability" (fail-closed on the authorization side, not the login side).
 *
 * Paste this into: Zitadel Console -> Actions -> Flows -> "Complement Token"
 * flow -> "Pre Userinfo creation" trigger -> Actions -> Add Action.
 * Set the INTERNAL_GRANT_TOKEN value below to the real secret value (get it
 * with: kubectl -n sfg-labs get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d)
 * — do not commit the real secret value into this file.
 */
function complementTokenClaims(ctx, api) {
  // ORDER MATTERS, AND IT IS DIAGNOSTIC.
  //
  // `zitadel/log` is required FIRST and an entry line is written before
  // anything else, so the userinfo response carries a
  // `urn:zitadel:iam:action:<name>:log` key the moment this function is
  // entered at all. Without that, "no claims" and "never ran" look identical
  // from the outside — which is precisely how this went unnoticed since
  // 2026-08-03.
  //
  // `zitadel/http` is then required INSIDE a try. If that module is
  // unavailable on this instance, the throw is caught here and reported,
  // instead of escaping the whole function before `logger` exists and being
  // swallowed by `allowedToFail: true`.
  var logger = require('zitadel/log');
  logger.log('entered');

  var sub = ctx.v1.getUser().id;
  var http;
  try {
    http = require('zitadel/http');
  } catch (err) {
    logger.log('zitadel/http unavailable on this instance', err);
    return;
  }

  var INTERNAL_GRANT_TOKEN = '<set-me-in-the-zitadel-console-only>';
  var ORG_HR_BASE_URL = 'http://suwalka-org-hr-payroll.sfg-labs.svc.cluster.local:3001';

  var resp;
  try {
    resp = http.fetch(
      ORG_HR_BASE_URL + '/api/hr/internal/admin-grants/by-sub?sub=' + encodeURIComponent(sub),
      {
        method: 'GET',
        headers: { 'X-Internal-Token': [INTERNAL_GRANT_TOKEN] },
      },
    );
  } catch (err) {
    logger.log('suwalka claim fetch threw', err);
    return;
  }

  if (!resp || resp.status !== 200) {
    logger.log('suwalka claim fetch failed', resp ? resp.status : 'no response');
    return;
  }

  var body;
  try {
    body = resp.json();
  } catch (err) {
    logger.log('suwalka claim response was not JSON', err);
    return;
  }

  var result = body && body.result;
  if (!result) {
    // A 200 with no `result` is a resolver contract break, not "no grants" —
    // say so, or it reads exactly like a user who holds nothing.
    logger.log('suwalka claim resolver 200 without a result field; no claims set; sub=' + sub);
    return;
  }

  // ── WRITE TO BOTH SURFACES. THIS IS THE WHOLE FIX. ──────────────────────
  //
  // Measured against the live instance on 2026-08-27, not inferred:
  //
  //   * `api.v1.claims.setClaim`   -> the TOKEN's claims.
  //   * `api.v1.userinfo.setClaim` -> the USERINFO response.
  //
  // APISIX's openid-connect plugin base64s the USERINFO response into the
  // `X-Userinfo` header, which is the only thing `readUser()` ever sees. So an
  // Action that calls only `claims.setClaim` deploys cleanly, reports success,
  // and delivers nothing to any backend.
  //
  // That is exactly the state the live `setIdentityClaims` was in: attached to
  // both triggers, ACTIVE, calling only `claims.setClaim` — and contributing
  // nothing. Every claim that DID arrive came from the separate
  // `complementTokenClaims` action, which mirrors Zitadel user METADATA and
  // uses `userinfo.setClaim`. The proof is in the userinfo response itself:
  // it carries `urn:zitadel:iam:action:complementTokenClaims:log` and no
  // `setIdentityClaims` log key at all.
  //
  // Each call is wrapped separately: on a trigger where one surface is not
  // available, Zitadel throws, and a single try around both would silently
  // drop the surface that WAS available.
  //
  // Two failures are EXPECTED and stay quiet, so the log is not noise on every
  // login: a surface this trigger does not offer (checked up front rather than
  // provoked as a TypeError), and "already exists" — a key an earlier Action set
  // from metadata, which wins; the UAT Action filters the same string. Any
  // other throw is a REJECTED value and is logged, or it would vanish.
  function setOn(where, surface, key, value) {
    // Only a MISSING surface is skipped. A present one is always called, so a
    // setClaim the runtime does not expose as a plain function throws and is
    // logged below rather than silently skipping every claim.
    if (!surface) return;
    try {
      surface.setClaim(key, value);
    } catch (e) {
      if (String(e).indexOf('already exists') < 0) logger.log(where + '.setClaim(' + key + ') failed', e);
    }
  }
  var v1 = (api && api.v1) || {};
  function setBoth(key, value) {
    setOn('userinfo', v1.userinfo, key, value);
    setOn('claims', v1.claims, key, value);
  }

  if (result.suwalka_admin && result.suwalka_admin.length) {
    setBoth('suwalka_admin', result.suwalka_admin);
  }
  if (result.suwalka_caps && result.suwalka_caps.length) {
    setBoth('suwalka_caps', result.suwalka_caps);
  }
  if (result.suwalka_identity) {
    setBoth('suwalka_identity', result.suwalka_identity);
  }
  if (result.suwalka_outlet_set && result.suwalka_outlet_set.length) {
    setBoth('suwalka_outlet_set', result.suwalka_outlet_set);
  }
  if (result.suwalka_dept_set && result.suwalka_dept_set.length) {
    setBoth('suwalka_dept_set', result.suwalka_dept_set);
  }

  // suwalka_grant_caps — the per-grant permission matrix (2026-08-03).
  //
  // DO NOT add a `.length` guard here. This claim is THREE-state and the empty
  // array is a real, meaningful value:
  //   absent    -> "pre-matrix": the grant is NOT narrowed. Fail-OPEN, and
  //                deliberately so, only so a stale token does not lose access.
  //   []        -> "this caller's grants cover nothing".
  //   [ ...  ]  -> the matrix.
  // Dropping [] would make it absent, i.e. turn "covers nothing" into
  // "covers everything" — the exact inversion readUser's parser warns about.
  // Send it whenever org-hr sent an array; org-hr sends null for pre-matrix.
  if (Array.isArray(result.suwalka_grant_caps)) {
    setBoth('suwalka_grant_caps', result.suwalka_grant_caps);
  }

  // suwalka_levels — the permission-LEVEL axis, approve/delete (#648, 2026-08-27).
  //
  // Also no `.length` guard, for the opposite reason: on this axis an absent
  // claim means DENY, never "everything". Setting it unconditionally keeps the
  // claim's presence a signal that this Action is current, rather than making an
  // undeployed Action indistinguishable from a caller who holds no levels.
  if (Array.isArray(result.suwalka_levels)) {
    setBoth('suwalka_levels', result.suwalka_levels);
  }

  // suwalka_dealer — the dealership access claim (slice 2, 2026-10-14).
  //
  // An OBJECT { v, pack, fn, m, x }, or null when the job title has no access
  // pack. Unlike suwalka_grant_caps there is NO third state: absent means "no
  // dealership access" to every consumer (@suwalka/common readDealerAccess
  // returns null), so null is simply not sent. Pass the object through
  // as received — consumers validate it; the Action must not reshape it —
  // with ONE addition: `at`, the mint time in integer epoch seconds.
  //
  // Why `at`: @suwalka/common refuses a dealer claim older than 1 h (claim
  // staleness, lost-phone window). It cannot use the token's `iat`, because
  // X-Userinfo is the USERINFO response (see above), which carries no `iat`.
  // Userinfo is built per call, so `at` is fresh on each userinfo call — that
  // is fine: it then dates the claim from the org-hr read made in that call.
  if (result.suwalka_dealer && typeof result.suwalka_dealer === 'object' && !Array.isArray(result.suwalka_dealer)) {
    var dealer = {};
    for (var k in result.suwalka_dealer) {
      if (Object.prototype.hasOwnProperty.call(result.suwalka_dealer, k)) dealer[k] = result.suwalka_dealer[k];
    }
    dealer.at = Math.floor(Date.now() / 1000);
    setBoth('suwalka_dealer', dealer);
  }
}
