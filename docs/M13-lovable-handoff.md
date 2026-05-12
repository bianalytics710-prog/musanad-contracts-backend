# M13 — Correlation Rule Engine + DSL — Lovable-to-Production Handoff

Generated: 2026-05-12T17:00:00Z

---

## Summary

M13 is a net-new module within the Lovable Modernization pipeline. The Lovable prototype did not include a correlation rule registry, DSL rule editor, or a correlations list — these surfaces have no Lovable ancestor. All components and routes for M13 were generated fresh following v2.6 production standards. Harden Mode was not applicable.

The backend was fully regenerated. No Supabase-js patterns, supabase.auth.* calls, or edge functions from Lovable were involved in this module.

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| AdminRulesList | — (no Lovable ancestor) | src/features/rules/AdminRulesList.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T10, T11 |
| AdminRuleForm | — (no Lovable ancestor) | src/features/rules/AdminRuleForm.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T8, T9, T11 |
| RuleTestPanel | — (no Lovable ancestor) | src/features/rules/RuleTestPanel.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T11 |
| CorrelationsList | — (no Lovable ancestor) | src/features/correlations/CorrelationsList.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T10, T11 |
| CorrelationDismissModal | — (no Lovable ancestor) | src/features/correlations/CorrelationDismissModal.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T8, T9, T11 |

---

## Preserved from Lovable

No components for M13 surfaces existed in the Lovable prototype. The admin sidebar navigation shell (shared from M0/M_parity) was extended with two new entries (Admin / Rules and Correlations). The sidebar extension was a 3-line additive change; the existing sidebar layout and visual design were preserved.

---

## Rebuilt from Scratch

All M13-specific surfaces — admin rules list, rule create/edit form with friendly form + Advanced YAML tab, test-against-fixture panel, correlations list, and dismiss modal — were generated. These areas had no Lovable equivalent.

The backend is entirely freshly built:
- All Supabase-js patterns replaced by rule.service.ts + correlation.service.ts service layer
- All supabase.auth.* patterns replaced by M0 JWT middleware
- No edge functions — replaced by Express controllers + rule-evaluation.worker.ts

---

## Discarded from Lovable

- All supabase-js patterns — replaced by service layer (as in all modules)
- All supabase.auth.* — replaced by M0 JWT
- No Lovable correlation or rule surfaces existed to discard

---

## Developer Waivers

No waivers — all generated components passed the hardening checklist at generation time.

---

## i18n Keys Added During This Module

The M13 share of the +159 combined M12+M13 net-new keys is approximately 79 keys across namespaces:
- `admin.rules.*` — list page, edit form labels, scenario tags, last-reviewed badge, enabled toggle, test panel, version_hash display
- `correlations.*` — list view, filters, status badges, dismiss dialog, mandatory reason field

Both en.json and ar.json were updated atomically (4995 → 5154 per locale; strict parity verified by QA Stage 4 C12).

---

## Design Token Notes

No tokens were adjusted for this module. All confidence and status indicators (active / dismissed / expired) use semantic tokens paired with text labels per WCAG 2.1 AA requirements.
