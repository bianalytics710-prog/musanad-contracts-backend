/* eslint-disable no-console */
import { Pool } from "pg";

const db = new Pool({ connectionString: process.env.DATABASE_URL });

async function main() {
  const probes: { name: string; sql: string; params?: any[] }[] = [
    { name: "schema_version", sql: "SELECT MAX(version) AS v FROM schema_migrations" },

    { name: "contract_count_by_type_emirate",
      sql: `SELECT contract_type, emirate, COUNT(*) FROM contract WHERE is_active GROUP BY 1,2 ORDER BY 1,2` },

    { name: "risk_score_count_total",
      sql: `SELECT COUNT(*) FROM risk_score` },

    { name: "risk_score_distinct_contracts",
      sql: `SELECT COUNT(DISTINCT contract_id) AS scored, (SELECT COUNT(*) FROM contract WHERE is_active) AS total_contracts FROM risk_score` },

    { name: "latest_risk_score_by_contract_type",
      sql: `SELECT c.contract_type, c.emirate, COUNT(DISTINCT lrs.contract_id) AS n, SUM(lrs.mar_value) AS mar
            FROM latest_risk_score lrs JOIN contract c ON c.id = lrs.contract_id
            GROUP BY 1,2 ORDER BY 1,2` },

    { name: "party_sample",
      sql: `SELECT id, name_en, name_ar, party_type FROM party ORDER BY id LIMIT 15` },

    { name: "contract_drafted_by_distribution",
      sql: `SELECT c.drafted_by, u.first_name, u.last_name, r.name AS role_name, COUNT(*) AS n
            FROM contract c
            LEFT JOIN "user" u ON u.id = c.drafted_by
            LEFT JOIN role r ON r.id = u.role_id
            WHERE c.is_active
            GROUP BY 1,2,3,4
            ORDER BY n DESC LIMIT 10` },

    { name: "signature_party_signer_distribution",
      sql: `SELECT sp.signer_user_id, u.first_name, u.last_name, r.name AS role_name, COUNT(*) AS n
            FROM signature_party sp
            LEFT JOIN "user" u ON u.id = sp.signer_user_id
            LEFT JOIN role r ON r.id = u.role_id
            GROUP BY 1,2,3,4
            ORDER BY n DESC LIMIT 10` },

    { name: "user_personas",
      sql: `SELECT u.id, u.email, u.first_name, u.last_name, r.name AS role_name
            FROM "user" u JOIN role r ON r.id = u.role_id
            WHERE u.email LIKE '%@musanad.local' ORDER BY u.id` },

    { name: "audit_log_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'audit_log' ORDER BY ordinal_position` },

    { name: "risk_case_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'risk_case' ORDER BY ordinal_position` },

    { name: "regulatory_cascade_run_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'regulatory_cascade_run' ORDER BY ordinal_position` },

    { name: "demo_scenario_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'demo_scenario' ORDER BY ordinal_position` },

    { name: "trade_position_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'trade_position' ORDER BY ordinal_position` },

    { name: "commodity_price_tables",
      sql: `SELECT table_name FROM information_schema.tables WHERE table_name LIKE '%price%' OR table_name LIKE '%osp%' OR table_name LIKE '%commodity%' OR table_name LIKE '%benchmark%' ORDER BY 1` },

    { name: "executive_events_table_search",
      sql: `SELECT table_name FROM information_schema.tables WHERE table_name LIKE '%event%' OR table_name LIKE '%activity%' OR table_name LIKE '%signal%' ORDER BY 1` },

    { name: "activity_type_constraint",
      sql: `SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname LIKE '%activity_type%'` },
    { name: "contract_activity_sample",
      sql: `SELECT activity_type, count(*) FROM contract_activity GROUP BY 1 ORDER BY 2 DESC` },
    { name: "signature_party_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'signature_party' ORDER BY ordinal_position` },
    { name: "price_benchmark_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'price_benchmark' ORDER BY ordinal_position` },
    { name: "price_benchmark_data",
      sql: `SELECT benchmark_code, latest_price_usd, latest_price_currency, latest_price_unit FROM price_benchmark LIMIT 5` },
    { name: "current_state_osp",
      sql: `SELECT * FROM price_benchmark WHERE benchmark_code LIKE 'murban%'` },
    { name: "tradeposition_data",
      sql: `SELECT id, position_ref, side, grade, pricing_basis FROM trade_position ORDER BY id LIMIT 10` },
    { name: "fn_demo_now_check",
      sql: `SELECT proname FROM pg_proc WHERE proname IN ('fn_demo_now', 'fn_demo_scenario_trigger', 'fn_demo_time_freeze_set')` },
    { name: "regulation_data",
      sql: `SELECT id, title_en, jurisdiction FROM regulation` },
    { name: "regulatory_cascade_runs",
      sql: `SELECT id, regulation_ref, status, affected_contractor_count, total_penalty_min_aed, total_penalty_max_aed, run_at FROM regulatory_cascade_run ORDER BY run_at DESC LIMIT 10` },
    { name: "impact_signal_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'impact_signal' ORDER BY ordinal_position` },
    { name: "impact_signal_categories",
      sql: `SELECT signal_kind, count(*) FROM impact_signal GROUP BY 1 ORDER BY 2 DESC LIMIT 20` },
    { name: "osint_signal_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'osint_signal' ORDER BY ordinal_position` },
    { name: "contract_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'contract' AND column_name IN ('id', 'tenant_id', 'value_aed', 'counterparty_id', 'contract_type', 'emirate', 'drafted_by', 'template_id', 'current_version', 'ai_risk_score', 'status') ORDER BY ordinal_position` },
    { name: "impact_signal_category_sample",
      sql: `SELECT category, count(*) FROM impact_signal GROUP BY 1 ORDER BY 2 DESC` },
    { name: "impact_signal_recent",
      sql: `SELECT id, category, source, severity, title_en FROM impact_signal ORDER BY id DESC LIMIT 20` },
    { name: "risk_score_columns",
      sql: `SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'risk_score' ORDER BY ordinal_position` },
    { name: "risk_score_sample",
      sql: `SELECT contract_id, mar_value, health_score, contributing_correlations, tenant_id, calculated_at FROM risk_score ORDER BY id DESC LIMIT 5` },
    { name: "demo_scenario_data",
      sql: `SELECT id, scenario_id, display_name_en, event_injection_payload FROM demo_scenario LIMIT 12` },
    { name: "trade_margin_summary_sample",
      sql: `SELECT side, count(*) FROM trade_position WHERE is_active GROUP BY side` },
    { name: "auditlog_actions",
      sql: `SELECT action, table_name, count(*) FROM audit_log WHERE changed_at >= NOW() - INTERVAL '14 days' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20` },

    { name: "fn_dashboard_executive_signature",
      sql: `SELECT pg_get_function_identity_arguments(oid), pg_get_function_result(oid)
            FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 5` },

    { name: "fn_avar_aggregate_args",
      sql: `SELECT pg_get_function_identity_arguments(oid), pg_get_function_result(oid)
            FROM pg_proc WHERE proname = 'fn_avar_aggregate' LIMIT 5` },

    { name: "audit_log_event_types",
      sql: `SELECT DISTINCT event_type FROM audit_log ORDER BY event_type LIMIT 100` },
  ];

  for (const p of probes) {
    try {
      const res = await db.query(p.sql, p.params ?? []);
      console.log(`\n=== ${p.name} (${res.rowCount}) ===`);
      console.log(JSON.stringify(res.rows.slice(0, 30), null, 2));
    } catch (e: any) {
      console.log(`\n=== ${p.name} ERROR ===`);
      console.log(e.message);
    }
  }

  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
