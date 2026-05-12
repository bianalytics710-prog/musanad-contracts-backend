# M12 — Clause Taxonomy + Two-Stage Extractor — Lovable-to-Production Handoff

Generated: 2026-05-12T17:00:00Z

---

## Summary

M12 is a net-new module within the Lovable Modernization pipeline. The Lovable prototype did not include clause extraction, pgvector semantic search, or a clause review queue — these surfaces have no Lovable ancestor. All components and routes for M12 were generated fresh following v2.6 production standards. Harden Mode was not applicable.

The backend was fully regenerated (as in all modules). No Supabase-js patterns, supabase.auth.* calls, or edge functions from Lovable were involved in this module.

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| ClauseTaxonomyViewer | — (no Lovable ancestor) | src/features/clauses/ClauseTaxonomyViewer.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T11 |
| ClauseReviewQueue | — (no Lovable ancestor) | src/features/clauses/ClauseReviewQueue.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11 |
| ClauseReviewModal | — (no Lovable ancestor) | src/features/clauses/ClauseReviewModal.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T8, T9, T11 |
| ClauseSemanticSearch | — (no Lovable ancestor) | src/features/clauses/ClauseSemanticSearch.tsx | generated | 0 | T1, T2, T3, T4, T5, T6, T7, T10, T11 |
| ContractClausesTab (extension) | contracts/$id Clauses tab (Lovable ancestor) | src/features/contracts/tabs/ClausesTab.tsx (extended) | extended | 1 | T1, T2, T3, T4 |

---

## Preserved from Lovable

No components for M12 surfaces existed in the Lovable prototype. The one extended surface (contract detail Clauses tab) was extended with extracted-clauses panel alongside the existing library panel. The visual design of the Clauses tab wrapper was preserved; only the inner panel was extended.

---

## Rebuilt from Scratch

All M12-specific surfaces — clause taxonomy admin viewer, review queue, review modal, semantic search input and results — were generated. These are areas where the Lovable prototype had no equivalent screen, so generation was the only path.

The backend is entirely freshly built per all module deliveries in this pipeline:
- All Supabase-js patterns replaced by clause.service.ts + clause-taxonomy.service.ts service layer
- All supabase.auth.* patterns replaced by M0 JWT middleware
- No edge functions — replaced by Express controllers and node-cron worker

---

## Discarded from Lovable

- All supabase-js patterns — replaced by service layer (as in all modules)
- All supabase.auth.* — replaced by M0 JWT
- No Lovable clause-extraction or review-queue existed to discard

---

## Developer Waivers

No waivers — all generated components passed the hardening checklist at generation time. No components were accepted below the 3-cycle threshold.

---

## i18n Keys Added During This Module

+159 net-new keys added across both en.json and ar.json (M11 baseline 4995 → M12+M13 total 5154, per QA Stage 4 C12 check). The M12 share is approximately 80 keys across namespaces:
- `clauses.taxonomy.*` — 50 clause type display names + 8 family names + definitions + identification cues
- `clauses.review.*` — filter chips, confidence band labels, action buttons, modal headings
- `clauses.search.*` — semantic search input, result cards, empty state
- `contracts.clausesTab.*` — extracted-clauses list, confidence pill, family color legend

---

## Design Token Notes

No tokens were adjusted for this module. All color-per-family pairings for the 8 Annex A clause families use semantic tokens (var(--family-force-majeure) etc.) with text labels or icons per WCAG 2.1 AA color-only rule. Token definitions were handled in the Design System agent phase.
