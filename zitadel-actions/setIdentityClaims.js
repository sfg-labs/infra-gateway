/**
 * Zitadel Action — Complement Token flow, "Pre Userinfo creation" trigger.
 * Order 1 (runs AFTER complementTokenClaims, which is order 0).
 *
 * Resolves suwalka_admin / suwalka_caps / suwalka_identity live from
 * suwalka-org-hr-payroll, for users who have no Zitadel user metadata. This is
 * the dynamic counterpart to complementTokenClaims (which copies static
 * metadata). Users WITH metadata are served by that action; the ~32 users
 * without it depend entirely on this one.
 *
 * This file was reconstructed from the live Action on 2026-08-09 and carries
 * two fixes. It was previously in NO git repo at all — the only copy was in
 * Zitadel's database. The pre-fix original is backed up outside git at
 * ~/.secrets/cantech/zitadel-actions-backup-20260809-0101/setIdentityClaims.js
 *
 * FIX 1 (2026-08-09) — namespace. The URL said `.sfg-labs.svc.cluster.local`,
 * which was correct on DOKS and became NXDOMAIN at the 2026-08-02 Cantech
 * cutover, where the app namespace is `sfg-pos-app`. Zitadel logged
 * `action run failed: ... no such host` on every login for a week. Because
 * the catch below is silent and allowed_to_fail=true, nothing surfaced except
 * face-verified check-in, which hard-fails on a missing suwalka_identity.
 *
 * FIX 2 (2026-08-09) — wrong claim API. The trigger that actually fires is
 * "Pre Userinfo creation", where a claim only reaches the userinfo payload
 * (what APISIX base64s into X-Userinfo, which every backend's readUser()
 * decodes) via api.v1.userinfo.setClaim. This action used ONLY
 * api.v1.claims.setClaim, so even once the fetch succeeded the claims landed
 * nowhere. complementTokenClaims has always written to BOTH — that is why it
 * works and this one did not. setBoth() below mirrors it.
 *
 * Ordering note: complementTokenClaims runs first, so for a user WITH metadata
 * its values win here ("key already exists" — swallowed by the try/catch) and
 * behaviour for those users is unchanged. Only users with no metadata change.
 *
 * KNOWN GAP, not fixed here: the resolver returns suwalka_outlet_set and
 * suwalka_dept_set, but this action reads result.suwalka_branch_set, which the
 * endpoint never sends. suwalka_branch_set is therefore always []. The
 * runbook's §8 checklist expects that claim to be populated — decide whether
 * the contract or the action is wrong before changing either.
 *
 * FIX 3 (2026-09-19) — per-environment resolver. Dev and UAT share this
 * Zitadel, and the resolver URL was dev's only, so a UAT login carried DEV's
 * suwalka_admin / suwalka_caps / suwalka_identity. UAT's org-hr then saw a dev
 * super-admin in the claim while its own admin_grants said otherwise: manual
 * attendance failed "Record is outside your outlet scope" (org-hr #1016 is the
 * service-side guard). The resolver is now chosen by the client id the token is
 * issued for (ctx.v1.application.getClientId(), Pre Userinfo creation):
 *   389855554874442152 (UAT suwalka-auth)  -> sfg-pos-app-uat, UAT token
 *   378146155789287497 (dev suwalka-auth)  -> sfg-pos-app (dev), dev token
 *   anything else, or no client id          -> dev, and a zitadel/log line
 * Resolver failures (non-200, throw) are logged too; claims stay empty.
 * The client ids are the `oidc-client-id` key of `suwalka-auth-secrets` in each
 * namespace; the two namespaces also have DIFFERENT internal-grant-token values,
 * hence two token lines. A new environment needs a row in RESOLVERS.
 *
 * TO EDIT: Zitadel Console -> Actions -> setIdentityClaims. Requires ORG_OWNER;
 * the mgmt-pat (svc-suwalka-provision) is ORG_USER_MANAGER and gets a 403.
 * Keep the two INTERNAL_TOKEN_* lines exactly as they are in the Console — the
 * real values must never be committed here. Fill them from:
 *   kubectl -n sfg-pos-app     get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
 *   kubectl -n sfg-pos-app-uat get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
 */
function setIdentityClaims(ctx, api) {
  var INTERNAL_TOKEN_DEV = '<set-me-in-the-zitadel-console-only>';
  var INTERNAL_TOKEN_UAT = '<set-me-in-the-zitadel-console-only>';
  var RESOLVER_PATH = '/api/hr/internal/admin-grants/by-sub';
  var DEV = { name: 'dev', url: 'http://suwalka-org-hr-payroll.sfg-pos-app.svc.cluster.local:3001' + RESOLVER_PATH, token: INTERNAL_TOKEN_DEV };
  var UAT = { name: 'uat', url: 'http://suwalka-org-hr-payroll.sfg-pos-app-uat.svc.cluster.local:3001' + RESOLVER_PATH, token: INTERNAL_TOKEN_UAT };
  // client id -> resolver. Anything not listed falls back to dev (today's
  // behaviour) but is LOGGED: a UAT client id that stops matching (rotation,
  // typo) would otherwise silently hand UAT logins dev's claims again.
  var RESOLVERS = {
    '378146155789287497': DEV,
    '389855554874442152': UAT
  };
  var logger = require('zitadel/log');
  var sub = '';
  try {
    sub = ctx.v1.getUser().id;              // Zitadel sub is numeric -> safe to concat
  } catch (e) {
    logger.log('setIdentityClaims: getUser() threw; claims left empty; err=' + e);
  }

  var clientId = '';
  try {
    clientId = (ctx.v1.application && ctx.v1.application.getClientId()) || '';
  } catch (e) {
    logger.log('setIdentityClaims: getClientId() threw, using dev resolver; sub=' + sub + ' err=' + e);
    clientId = '';
  }
  var resolver = Object.prototype.hasOwnProperty.call(RESOLVERS, clientId) ? RESOLVERS[clientId] : null;
  if (!resolver) {
    logger.log('setIdentityClaims: unmapped client id "' + clientId + '", using dev resolver; sub=' + sub);
    resolver = DEV;
  }
  var RESOLVER_URL = resolver.url;
  var INTERNAL_TOKEN = resolver.token;

  var admin = [];
  var caps = [];
  var identity = null;   // object { employeeId, divisionId, departmentId, orgId } or null
  var branchSet = [];

  try {
    if (!sub) throw new Error('no sub');
    var http = require('zitadel/http');

    var res = http.fetch(RESOLVER_URL + '?sub=' + sub, {
      method: 'GET',
      headers: { 'X-Internal-Token': INTERNAL_TOKEN }
    });

    if (res && res.status === 200) {
      var body = res.json();
      var result = (body && body.result) || {};
      if (Array.isArray(result.suwalka_admin)) admin = result.suwalka_admin;
      if (Array.isArray(result.suwalka_caps)) caps = result.suwalka_caps;
      if (result.suwalka_identity && typeof result.suwalka_identity === 'object') {
        identity = result.suwalka_identity;
      }
      if (Array.isArray(result.suwalka_branch_set)) branchSet = result.suwalka_branch_set;
    } else {
      // Fail-open, but never silently (the 2026-08-09 outage was a silent catch).
      logger.log('setIdentityClaims: ' + resolver.name + ' resolver returned ' + (res ? res.status : 'no response') + '; claims left empty; sub=' + sub);
    }
  } catch (e) {
    logger.log('setIdentityClaims: ' + resolver.name + ' resolver call failed; claims left empty; sub=' + sub + ' err=' + e);
    admin = []; caps = []; identity = null; branchSet = [];
  }

  // Write to BOTH: userinfo is what APISIX forwards as X-Userinfo; claims is the
  // use_jwks/token path. Each is wrapped because a key already set by
  // complementTokenClaims raises "key already exists", and an uncaught raise here
  // aborts the run before the remaining claims are set.
  function setBoth(key, value) {
    try { api.v1.userinfo.setClaim(key, value); } catch (e1) {}
    try { api.v1.claims.setClaim(key, value); } catch (e2) {}
  }

  setBoth('suwalka_admin', admin);
  setBoth('suwalka_caps', caps);
  setBoth('suwalka_identity', identity);
  setBoth('suwalka_branch_set', branchSet);
}
