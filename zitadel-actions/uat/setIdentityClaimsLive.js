/**
 * setIdentityClaimsLive — UAT instance only (https://sfg-labs-uat.faithandgamble.in,
 * org "Suwalka UAT"). Live since 2026-09-19 ~09:50Z, Action id 391438409203188823.
 *
 * Resolves suwalka_identity / suwalka_admin / suwalka_caps / suwalka_outlet_set /
 * suwalka_dept_set / suwalka_grant_caps from UAT org-hr on every token, by sub.
 *
 * Why it exists: the two Actions copied onto the UAT instance at cut-over
 * (complementTokenClaims, setIdentityClaimsUat) only copy claims out of the user's
 * Zitadel METADATA. The live resolver (zitadel-actions/setIdentityClaims.js) was
 * deliberately not copied, and its UAT-only replacement (cut-over plan step 2.4)
 * never landed. So any login without suwalka_identity metadata — including every
 * login suwalka-auth provisions, which only stamps suwalka_env + suwalka_employee_id —
 * got a token with no orgId. org-hr did not notice (UAT runs RESOLVE_IDENTITY_BY_SUB),
 * but suwalka-ai-services reads the tenant only from the token, so
 * POST /v1/timesheet/voice-parse answered 401 for those users.
 *
 * Bound on flow "Complement Token", triggers Pre Userinfo creation AND Pre access
 * token creation, LAST — after complementTokenClaims and setIdentityClaimsUat.
 * Zitadel refuses to overwrite a claim that is already set, so metadata-seeded
 * claims win; this only fills what is missing. It sets a claim only when the
 * resolver returned a value, so a resolver failure changes nothing (fail-open,
 * logged), and allowedToFail=true keeps login working if the Action itself throws.
 *
 * TO EDIT: there is no working Console login on this instance (Login V2 is required
 * by suwalka-auth and the v2 login app is not deployed — do NOT turn Login V2 off,
 * that makes every UAT login 502). Use the Management API with the instance-admin
 * PAT: ~/.secrets/cantech/zitadel-system-suwalka-uat/06-add-live-identity-action.sh
 * creates or updates this Action and binds it.
 * The INTERNAL_TOKEN line must never be committed with a real value. It is
 * org-hr's INTERNAL_GRANT_TOKEN:
 *   kubectl -n sfg-pos-app-uat get secret suwalka-auth-secrets -o jsonpath='{.data.internal-grant-token}' | base64 -d
 */
function setIdentityClaimsLive(ctx, api) {
  var INTERNAL_TOKEN = '<set-me-via-the-management-api-only>';
  var URL = 'http://suwalka-org-hr-payroll.sfg-pos-app-uat.svc.cluster.local:3001/api/hr/internal/admin-grants/by-sub';
  var logger = { log: function () {} };
  try { logger = require('zitadel/log'); } catch (e) {}

  var sub = '';
  try { sub = ctx.v1.getUser().id; } catch (e) { logger.log('setIdentityClaimsLive: getUser() threw; err=' + e); return; }
  if (!sub) return;

  var result = null;
  try {
    var http = require('zitadel/http');
    var res = http.fetch(URL + '?sub=' + sub, { method: 'GET', headers: { 'X-Internal-Token': INTERNAL_TOKEN } });
    if (res && res.status === 200) {
      var body = res.json();
      result = (body && body.result) || null;
    } else {
      logger.log('setIdentityClaimsLive: resolver returned ' + (res ? res.status : 'no response') + '; sub=' + sub);
    }
  } catch (e) {
    logger.log('setIdentityClaimsLive: resolver call failed; sub=' + sub + ' err=' + e);
  }
  if (!result) return;

  // userinfo is what APISIX forwards as X-Userinfo; claims is the use_jwks/token path.
  // Each is wrapped: a key already set by an earlier Action raises "key already exists".
  function setBoth(key, value) {
    try { api.v1.userinfo.setClaim(key, value); } catch (e1) {}
    try { api.v1.claims.setClaim(key, value); } catch (e2) {}
  }
  if (result.suwalka_identity && typeof result.suwalka_identity === 'object') setBoth('suwalka_identity', result.suwalka_identity);
  if (Array.isArray(result.suwalka_admin) && result.suwalka_admin.length) setBoth('suwalka_admin', result.suwalka_admin);
  if (Array.isArray(result.suwalka_caps) && result.suwalka_caps.length) setBoth('suwalka_caps', result.suwalka_caps);
  if (Array.isArray(result.suwalka_outlet_set) && result.suwalka_outlet_set.length) setBoth('suwalka_outlet_set', result.suwalka_outlet_set);
  if (Array.isArray(result.suwalka_dept_set) && result.suwalka_dept_set.length) setBoth('suwalka_dept_set', result.suwalka_dept_set);
  if (result.suwalka_grant_caps && typeof result.suwalka_grant_caps === 'object') setBoth('suwalka_grant_caps', result.suwalka_grant_caps);
}
