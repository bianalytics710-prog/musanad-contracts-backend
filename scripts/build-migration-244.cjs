'use strict';
const fs = require('fs');
const bodies = JSON.parse(fs.readFileSync('fn_bodies_temp.json', 'utf-8'));

function applySubstitutions(body, fnName) {
  let result = body;
  let count = 0;

  if (fnName === 'fn_risk_score_compute') {
    const r1 = result.replace(/calculated_at >= NOW\(\) - INTERVAL '60 seconds'/g,
      "calculated_at >= fn_demo_now() - INTERVAL '60 seconds'");
    if (r1 !== result) { count++; result = r1; }
    const r2 = result.replace(
      /v_weights_version, NOW\(\), p_triggered_by, 'demo', NOW\(\), v_actor_id/,
      "v_weights_version, fn_demo_now(), p_triggered_by, 'demo', NOW(), v_actor_id"
    );
    if (r2 !== result) { count++; result = r2; }
    const r3 = result.replace(/'calculatedAt', NOW\(\)/g, "'calculatedAt', fn_demo_now()");
    if (r3 !== result) { count++; result = r3; }
    return { result, count };
  }

  if (fnName === 'fn_notification_send') {
    const r1 = result.replace(/THEN NOW\(\) \+ INTERVAL '0 seconds'/g,
      "THEN fn_demo_now() + INTERVAL '0 seconds'");
    if (r1 !== result) { count++; result = r1; }
    return { result, count };
  }

  if (fnName === 'fn_notification_dispatch_retry_due') {
    const r1 = result.replace(/next_retry_at <= NOW\(\)/g, 'next_retry_at <= fn_demo_now()');
    if (r1 !== result) { count++; result = r1; }
    return { result, count };
  }

  if (fnName === 'fn_risk_score_history') {
    const r1 = result.replace(/calculated_at >= NOW\(\) - \(p_window_days/g,
      'calculated_at >= fn_demo_now() - (p_window_days');
    if (r1 !== result) { count++; result = r1; }
    return { result, count };
  }

  if (fnName === 'fn_avar_aggregate') {
    const r1 = result.replace(/v_window_from := NOW\(\) -/g, 'v_window_from := fn_demo_now() -');
    if (r1 !== result) { count++; result = r1; }
    const r2 = result.replace(/calculated_at >= NOW\(\) - \(2 \* p_window_days/g,
      'calculated_at >= fn_demo_now() - (2 * p_window_days');
    if (r2 !== result) { count++; result = r2; }
    const r3 = result.replace(/calculated_at < NOW\(\) - \(p_window_days/g,
      'calculated_at < fn_demo_now() - (p_window_days');
    if (r3 !== result) { count++; result = r3; }
    return { result, count };
  }

  // All 10 dashboard fns: replace ALL NOW() - all are time-sensitive window math/asOf
  const dashboards = [
    'fn_dashboard_admin','fn_dashboard_approver','fn_dashboard_drafter','fn_dashboard_executive',
    'fn_dashboard_legal_counsel','fn_dashboard_recipient','fn_dashboard_operations',
    'fn_dashboard_finance_treasury','fn_dashboard_compliance_esg','fn_dashboard_procurement_supplier_risk'
  ];
  if (dashboards.includes(fnName)) {
    count = (result.match(/NOW\(\)/g) || []).length;
    result = result.replace(/NOW\(\)/g, 'fn_demo_now()');
    return { result, count };
  }

  return { result, count };
}

const parts = [];
const report = [];
const fnList = Object.keys(bodies);

for (const fn of fnList) {
  const { result, count } = applySubstitutions(bodies[fn], fn);
  report.push({ fn, count });
  if (count === 0) {
    report[report.length - 1].note = 'WARN: 0 replacements made';
  }
  // pg_get_functiondef() does not include trailing semicolon; add it
  parts.push(result + ';');
  parts.push('');
  parts.push('REVOKE ALL ON FUNCTION ' + fn + ' FROM PUBLIC;');
  parts.push('GRANT EXECUTE ON FUNCTION ' + fn + ' TO neondb_owner;');
  parts.push("COMMENT ON FUNCTION " + fn + " IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';");
  parts.push('');
}

const header = [
  '-- Migration 244: CR-I+J DEBT-CRIJ-1 -- 18-fn time-freeze refactor',
  '-- Replaces time-sensitive NOW() calls with fn_demo_now() in 15 fns.',
  '-- 3 fns (fn_signature_invitation_expire_due, fn_obligations_derive_from_clause, fn_source_health_record)',
  '--   contain only audit timestamps (created_at/updated_at/checked_at) -- SKIPPED.',
  '',
  "INSERT INTO schema_migrations (version, description, applied_at)",
  "VALUES (244, 'CR-I+J DEBT-CRIJ-1 -- 18-fn time-freeze refactor', now());",
  ''
].join('\n');

const migration = header + parts.join('\n');
fs.writeFileSync('database/migrations/244_crij_time_freeze_refactor_18_fns.sql', migration);
console.log('Written migration 244');
console.log('Report:');
for (const r of report) {
  const note = r.note ? ' [' + r.note + ']' : '';
  console.log('  ' + r.fn + ' -> ' + r.count + ' replacement(s)' + note);
}
