/**
 * Zitadel Action — Complement Token flow, "Pre Userinfo creation" trigger.
 *
 * Mints suwalka_admin / suwalka_caps / suwalka_identity / suwalka_outlet_set /
 * suwalka_dept_set custom claims into the userinfo response (which APISIX's
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
  var sub = ctx.v1.getUser().id;
  var http = require('zitadel/http');
  var logger = require('zitadel/log');

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
  if (!result) return;

  if (result.suwalka_admin && result.suwalka_admin.length) {
    api.v1.claims.setClaim('suwalka_admin', result.suwalka_admin);
  }
  if (result.suwalka_caps && result.suwalka_caps.length) {
    api.v1.claims.setClaim('suwalka_caps', result.suwalka_caps);
  }
  if (result.suwalka_identity) {
    api.v1.claims.setClaim('suwalka_identity', result.suwalka_identity);
  }
  if (result.suwalka_outlet_set && result.suwalka_outlet_set.length) {
    api.v1.claims.setClaim('suwalka_outlet_set', result.suwalka_outlet_set);
  }
  if (result.suwalka_dept_set && result.suwalka_dept_set.length) {
    api.v1.claims.setClaim('suwalka_dept_set', result.suwalka_dept_set);
  }
}
