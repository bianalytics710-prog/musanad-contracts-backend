/**
 * Pino logger with sensitive-field redaction.
 * Redact paths cover all 15 sensitive fields from project.config.json,
 * the LoginUserRecord.passwordHash carrier (per Contract Generator handoff),
 * the M1a bilingual body fields (bodyEn / bodyAr), and the M1c extractedText
 * AI-payload alias (S8 AC-S8-06).
 *
 * Codex BE round-1 patch (M1): each sensitive field ships with explicit
 * top-level + req.body.* + req.body.*.* + req.query.* + req.params.* paths
 * in addition to the original `*.field` and `*.*.field` wildcards. Pino
 * wildcards match exactly one nesting level, so wildcard-only coverage
 * leaves top-level and direct-nested keys unredacted.
 *
 * Pretty print in development; JSON in production.
 */
import pino from 'pino';
import type { Logger } from 'pino';

const isDevelopment = process.env.NODE_ENV !== 'production';

/**
 * Sensitive-field redaction paths.
 *
 * Pino redaction paths are LITERAL: a `*` wildcard matches exactly ONE
 * property-name level. So `*.password` covers `foo.password` but NOT
 * `password` at the top level, NOT `req.body.password` (two levels deep),
 * and NOT `req.body.user.password` (three levels deep).
 *
 * Codex BE round-1 finding M1: the original list was wildcard-only. The
 * M1c AI stub controller logs derived metadata (textLength, fileSize) and
 * NOT req.body — but as a safety net every sensitive field now ships with
 * a complementary set of explicit paths covering the routes pino redact
 * cannot infer from a single-segment wildcard:
 *
 *   - exact top-level key            (`password`)
 *   - `req.body.<key>`               (controller logs req.body)
 *   - `req.body.*.<key>`             (controller logs an array/object inside body)
 *   - `req.query.<key>`              (controller logs req.query)
 *   - `req.params.<key>`             (controller logs req.params)
 *   - `*.<key>`                      (one-level wildcard — original M0 coverage)
 *   - `*.*.<key>`                    (two-level wildcard for envelope-wrapped logs)
 *
 * Mirrors:
 *   - project.config.json sensitiveFields (15 entries — snake_case DB
 *     column names; we list camelCase API-surface variants alongside)
 *   - LoginUserRecord.passwordHash (BE Impl handoff in
 *     contracts-summary.json `beImplementation`)
 *   - tokenHash (TokenBlacklistEntry @internal type)
 *   - M1c S8 AC-S8-06 extractedText (ai_prompt_payload alias)
 *
 * pino-redact docs:
 *   https://github.com/pinojs/pino/blob/main/docs/redaction.md
 */
const SENSITIVE_PATHS: string[] = [
  // -- Wire-level: password --
  'password',
  'req.body.password',
  'req.body.*.password',
  'req.query.password',
  'req.params.password',
  '*.password',
  '*.*.password',

  // -- Wire-level: passwordHash / password_hash --
  'passwordHash',
  'req.body.passwordHash',
  'req.body.*.passwordHash',
  'req.query.passwordHash',
  'req.params.passwordHash',
  '*.passwordHash',
  '*.*.passwordHash',
  'password_hash',
  'req.body.password_hash',
  'req.body.*.password_hash',
  'req.query.password_hash',
  'req.params.password_hash',
  '*.password_hash',
  '*.*.password_hash',

  // -- Wire-level: refreshToken / refresh_token --
  'refreshToken',
  'req.body.refreshToken',
  'req.body.*.refreshToken',
  'req.query.refreshToken',
  'req.params.refreshToken',
  '*.refreshToken',
  '*.*.refreshToken',
  'refresh_token',
  'req.body.refresh_token',
  'req.body.*.refresh_token',
  'req.query.refresh_token',
  'req.params.refresh_token',
  '*.refresh_token',
  '*.*.refresh_token',

  // -- Wire-level: accessToken / access_token --
  'accessToken',
  'req.body.accessToken',
  'req.body.*.accessToken',
  'req.query.accessToken',
  'req.params.accessToken',
  '*.accessToken',
  '*.*.accessToken',
  'access_token',
  'req.body.access_token',
  'req.body.*.access_token',
  'req.query.access_token',
  'req.params.access_token',
  '*.access_token',
  '*.*.access_token',

  // -- Wire-level: tokenHash / token_hash (TokenBlacklistEntry @internal) --
  'tokenHash',
  'req.body.tokenHash',
  'req.body.*.tokenHash',
  'req.query.tokenHash',
  'req.params.tokenHash',
  '*.tokenHash',
  '*.*.tokenHash',
  'token_hash',
  'req.body.token_hash',
  'req.body.*.token_hash',
  'req.query.token_hash',
  'req.params.token_hash',
  '*.token_hash',
  '*.*.token_hash',

  // -- Wire-level: jwtSecret / jwt_secret --
  'jwtSecret',
  'req.body.jwtSecret',
  'req.body.*.jwtSecret',
  'req.query.jwtSecret',
  'req.params.jwtSecret',
  '*.jwtSecret',
  '*.*.jwtSecret',
  'jwt_secret',
  'req.body.jwt_secret',
  'req.body.*.jwt_secret',
  'req.query.jwt_secret',
  'req.params.jwt_secret',
  '*.jwt_secret',
  '*.*.jwt_secret',

  // -- Provider keys: openaiApiKey / openai_api_key --
  'openaiApiKey',
  'req.body.openaiApiKey',
  'req.body.*.openaiApiKey',
  'req.query.openaiApiKey',
  'req.params.openaiApiKey',
  '*.openaiApiKey',
  '*.*.openaiApiKey',
  'openai_api_key',
  'req.body.openai_api_key',
  'req.body.*.openai_api_key',
  'req.query.openai_api_key',
  'req.params.openai_api_key',
  '*.openai_api_key',
  '*.*.openai_api_key',

  // -- Provider keys: anthropicApiKey / anthropic_api_key --
  'anthropicApiKey',
  'req.body.anthropicApiKey',
  'req.body.*.anthropicApiKey',
  'req.query.anthropicApiKey',
  'req.params.anthropicApiKey',
  '*.anthropicApiKey',
  '*.*.anthropicApiKey',
  'anthropic_api_key',
  'req.body.anthropic_api_key',
  'req.body.*.anthropic_api_key',
  'req.query.anthropic_api_key',
  'req.params.anthropic_api_key',
  '*.anthropic_api_key',
  '*.*.anthropic_api_key',

  // -- Provider keys: smtpPassword / smtp_password --
  'smtpPassword',
  'req.body.smtpPassword',
  'req.body.*.smtpPassword',
  'req.query.smtpPassword',
  'req.params.smtpPassword',
  '*.smtpPassword',
  '*.*.smtpPassword',
  'smtp_password',
  'req.body.smtp_password',
  'req.body.*.smtp_password',
  'req.query.smtp_password',
  'req.params.smtp_password',
  '*.smtp_password',
  '*.*.smtp_password',

  // -- Provider keys: uaePassClientSecret / uae_pass_client_secret --
  'uaePassClientSecret',
  'req.body.uaePassClientSecret',
  'req.body.*.uaePassClientSecret',
  'req.query.uaePassClientSecret',
  'req.params.uaePassClientSecret',
  '*.uaePassClientSecret',
  '*.*.uaePassClientSecret',
  'uae_pass_client_secret',
  'req.body.uae_pass_client_secret',
  'req.body.*.uae_pass_client_secret',
  'req.query.uae_pass_client_secret',
  'req.params.uae_pass_client_secret',
  '*.uae_pass_client_secret',
  '*.*.uae_pass_client_secret',

  // -- Provider keys: supabaseServiceRoleKey / supabase_service_role_key --
  'supabaseServiceRoleKey',
  'req.body.supabaseServiceRoleKey',
  'req.body.*.supabaseServiceRoleKey',
  'req.query.supabaseServiceRoleKey',
  'req.params.supabaseServiceRoleKey',
  '*.supabaseServiceRoleKey',
  '*.*.supabaseServiceRoleKey',
  'supabase_service_role_key',
  'req.body.supabase_service_role_key',
  'req.body.*.supabase_service_role_key',
  'req.query.supabase_service_role_key',
  'req.params.supabase_service_role_key',
  '*.supabase_service_role_key',
  '*.*.supabase_service_role_key',

  // -- Project-specific: contractBody / contract_body --
  'contractBody',
  'req.body.contractBody',
  'req.body.*.contractBody',
  'req.query.contractBody',
  'req.params.contractBody',
  '*.contractBody',
  '*.*.contractBody',
  'contract_body',
  'req.body.contract_body',
  'req.body.*.contract_body',
  'req.query.contract_body',
  'req.params.contract_body',
  '*.contract_body',
  '*.*.contract_body',

  // -- Project-specific: signerEmail / signer_email --
  'signerEmail',
  'req.body.signerEmail',
  'req.body.*.signerEmail',
  'req.query.signerEmail',
  'req.params.signerEmail',
  '*.signerEmail',
  '*.*.signerEmail',
  'signer_email',
  'req.body.signer_email',
  'req.body.*.signer_email',
  'req.query.signer_email',
  'req.params.signer_email',
  '*.signer_email',
  '*.*.signer_email',

  // -- Project-specific: signerPhone / signer_phone --
  'signerPhone',
  'req.body.signerPhone',
  'req.body.*.signerPhone',
  'req.query.signerPhone',
  'req.params.signerPhone',
  '*.signerPhone',
  '*.*.signerPhone',
  'signer_phone',
  'req.body.signer_phone',
  'req.body.*.signer_phone',
  'req.query.signer_phone',
  'req.params.signer_phone',
  '*.signer_phone',
  '*.*.signer_phone',

  // -- Project-specific: emiratesId / emirates_id --
  'emiratesId',
  'req.body.emiratesId',
  'req.body.*.emiratesId',
  'req.query.emiratesId',
  'req.params.emiratesId',
  '*.emiratesId',
  '*.*.emiratesId',
  'emirates_id',
  'req.body.emirates_id',
  'req.body.*.emirates_id',
  'req.query.emirates_id',
  'req.params.emirates_id',
  '*.emirates_id',
  '*.*.emirates_id',

  // -- Project-specific: signatureImage / signature_image --
  'signatureImage',
  'req.body.signatureImage',
  'req.body.*.signatureImage',
  'req.query.signatureImage',
  'req.params.signatureImage',
  '*.signatureImage',
  '*.*.signatureImage',
  'signature_image',
  'req.body.signature_image',
  'req.body.*.signature_image',
  'req.query.signature_image',
  'req.params.signature_image',
  '*.signature_image',
  '*.*.signature_image',

  // -- Project-specific: aiPromptPayload / ai_prompt_payload --
  'aiPromptPayload',
  'req.body.aiPromptPayload',
  'req.body.*.aiPromptPayload',
  'req.query.aiPromptPayload',
  'req.params.aiPromptPayload',
  '*.aiPromptPayload',
  '*.*.aiPromptPayload',
  'ai_prompt_payload',
  'req.body.ai_prompt_payload',
  'req.body.*.ai_prompt_payload',
  'req.query.ai_prompt_payload',
  'req.params.ai_prompt_payload',
  '*.ai_prompt_payload',
  '*.*.ai_prompt_payload',

  // -- M1a contract body (bilingual): bodyEn / body_en --
  //    See types/contracts.types.ts M1A_SENSITIVE_FIELD_EXTENSIONS.
  'bodyEn',
  'req.body.bodyEn',
  'req.body.*.bodyEn',
  'req.query.bodyEn',
  'req.params.bodyEn',
  '*.bodyEn',
  '*.*.bodyEn',
  'body_en',
  'req.body.body_en',
  'req.body.*.body_en',
  'req.query.body_en',
  'req.params.body_en',
  '*.body_en',
  '*.*.body_en',

  // -- M1a contract body (bilingual): bodyAr / body_ar --
  'bodyAr',
  'req.body.bodyAr',
  'req.body.*.bodyAr',
  'req.query.bodyAr',
  'req.params.bodyAr',
  '*.bodyAr',
  '*.*.bodyAr',
  'body_ar',
  'req.body.body_ar',
  'req.body.*.body_ar',
  'req.query.body_ar',
  'req.params.body_ar',
  '*.body_ar',
  '*.*.body_ar',

  // -- M1c AI extraction stub (S8 AC-S8-06): extractedText / extracted_text --
  //    Treated as ai_prompt_payload alias per project.config.json. The AI
  //    controller already avoids logging req.body, but this acts as the
  //    safety net for any future code path that does.
  'extractedText',
  'req.body.extractedText',
  'req.body.*.extractedText',
  'req.query.extractedText',
  'req.params.extractedText',
  '*.extractedText',
  '*.*.extractedText',
  'extracted_text',
  'req.body.extracted_text',
  'req.body.*.extracted_text',
  'req.query.extracted_text',
  'req.params.extracted_text',
  '*.extracted_text',
  '*.*.extracted_text',

  // -- M2 approval — decisionNote / decision_note --
  //    See approval.types.ts M2_SENSITIVE_FIELD_EXTENSIONS + fn_audit_trigger
  //    redact array (migration 029). decisionNote is on the wire DTO for
  //    fn_approval_decide / fn_approval_delegate / fn_approval_reassign.
  'decisionNote',
  'req.body.decisionNote',
  'req.body.*.decisionNote',
  'req.query.decisionNote',
  'req.params.decisionNote',
  '*.decisionNote',
  '*.*.decisionNote',
  'decision_note',
  'req.body.decision_note',
  'req.body.*.decision_note',
  'req.query.decision_note',
  'req.params.decision_note',
  '*.decision_note',
  '*.*.decision_note',

  // -- M2 approval — matrixSnapshot / matrix_snapshot --
  //    Frozen approval-matrix snapshot stored on approval_chain (immutable
  //    post-creation). Redacted in audit_log + pino logs; surfaces only on
  //    admin / forensic projection (not on the standard chain GET).
  'matrixSnapshot',
  'req.body.matrixSnapshot',
  'req.body.*.matrixSnapshot',
  'req.query.matrixSnapshot',
  'req.params.matrixSnapshot',
  '*.matrixSnapshot',
  '*.*.matrixSnapshot',
  'matrix_snapshot',
  'req.body.matrix_snapshot',
  'req.body.*.matrix_snapshot',
  'req.query.matrix_snapshot',
  'req.params.matrix_snapshot',
  '*.matrix_snapshot',
  '*.*.matrix_snapshot',

  // -- M3 — invitationToken / invitation_token (plaintext + hash) --
  //    The fn_ persists invitation_token_hash only; plaintext is returned
  //    ONCE on creation. Both names redacted here to defeat any code path
  //    that logs the plaintext or the hash.
  'invitationToken',
  'req.body.invitationToken',
  'req.body.*.invitationToken',
  'req.query.invitationToken',
  'req.params.invitationToken',
  '*.invitationToken',
  '*.*.invitationToken',
  'invitation_token',
  'req.body.invitation_token',
  'req.body.*.invitation_token',
  'req.query.invitation_token',
  'req.params.invitation_token',
  '*.invitation_token',
  '*.*.invitation_token',
  'invitationTokenPlaintext',
  'req.body.invitationTokenPlaintext',
  'req.body.*.invitationTokenPlaintext',
  '*.invitationTokenPlaintext',
  '*.*.invitationTokenPlaintext',
  'invitationTokenHash',
  '*.invitationTokenHash',
  '*.*.invitationTokenHash',
  'invitation_token_hash',
  '*.invitation_token_hash',
  '*.*.invitation_token_hash',

  // -- M3 — sessionToken / session_token (plaintext + hash) --
  'sessionToken',
  'req.body.sessionToken',
  'req.body.*.sessionToken',
  'req.query.sessionToken',
  'req.params.sessionToken',
  '*.sessionToken',
  '*.*.sessionToken',
  'session_token',
  'req.body.session_token',
  'req.body.*.session_token',
  'req.query.session_token',
  'req.params.session_token',
  '*.session_token',
  '*.*.session_token',
  'sessionTokenPlaintext',
  'req.body.sessionTokenPlaintext',
  'req.body.*.sessionTokenPlaintext',
  '*.sessionTokenPlaintext',
  '*.*.sessionTokenPlaintext',
  'sessionTokenHash',
  '*.sessionTokenHash',
  '*.*.sessionTokenHash',
  'session_token_hash',
  '*.session_token_hash',
  '*.*.session_token_hash',

  // -- M3 — X-Session-Token header --
  'req.headers.x-session-token',
  'req.headers.X-Session-Token',

  // -- M3 — signatureData / signature_data (typed/drawn payload) --
  //    SENSITIVE — the verbatim signature payload (typed signature text or
  //    base64 canvas data). Never returned by any read path. Audit-log
  //    redacted by fn_audit_trigger via M3 034.
  'signatureData',
  'req.body.signatureData',
  'req.body.*.signatureData',
  'req.query.signatureData',
  'req.params.signatureData',
  '*.signatureData',
  '*.*.signatureData',
  'signature_data',
  'req.body.signature_data',
  'req.body.*.signature_data',
  '*.signature_data',
  '*.*.signature_data',

  // -- M3 — signatureImageUrl / signature_image_url --
  //    SENSITIVE — storage URL of canvas-rendered signature PNG. Distinct
  //    from M1a `signature_image` (already redacted above) — different
  //    column on signature_event. Audit-log redacted in M3 034.
  'signatureImageUrl',
  'req.body.signatureImageUrl',
  'req.body.*.signatureImageUrl',
  'req.query.signatureImageUrl',
  'req.params.signatureImageUrl',
  '*.signatureImageUrl',
  '*.*.signatureImageUrl',
  'signature_image_url',
  'req.body.signature_image_url',
  'req.body.*.signature_image_url',
  '*.signature_image_url',
  '*.*.signature_image_url',

  // -- M3 — userMessage (signer Q&A user prompt — ai_prompt_payload alias) --
  //    AC-S12-09: NEVER logged at controller level. Pino still applies as a
  //    safety net.
  'userMessage',
  'req.body.userMessage',
  'req.body.*.userMessage',
  '*.userMessage',
  '*.*.userMessage',

  // -- Response envelope: passwordHash on res.body / res.user --
  //    Preserved from M0 — covers the auth login response shape.
  'res.body.passwordHash',
  'res.body.*.passwordHash',

  // -- M4 — ai_insight.payload (AI response — may echo contract excerpts) --
  //    Defence-in-depth alongside DB-layer redaction in fn_audit_trigger
  //    (migration 041 added 'payload' to v_redact_fields). Generic key — at
  //    risk of false-positive masking on unrelated 'payload' fields, so we
  //    scope to req.body / req.body.* / response envelope nesting only.
  'req.body.payload',
  'req.body.*.payload',
  '*.payload',
  '*.*.payload',
  'res.body.data.payload',
  'res.body.data.*.payload',

  // -- M4 — ai_request_log.error_message (sanitised at controller before fn_) --
  //    AC-S10-07: pre-redact at controller via Pino. fn_audit_trigger v_redact_fields
  //    extension (migration 041) is defence-in-depth.
  'errorMessage',
  'req.body.errorMessage',
  'req.body.*.errorMessage',
  '*.errorMessage',
  '*.*.errorMessage',
  'error_message',
  'req.body.error_message',
  'req.body.*.error_message',
  '*.error_message',
  '*.*.error_message',

  // -- M4 — signedToken (S5 signed-PDF-token, short-lived JWT) --
  'signedToken',
  'req.body.signedToken',
  'req.body.*.signedToken',
  '*.signedToken',
  '*.*.signedToken',
  'req.headers.x-signed-pdf-token',
  'req.headers.X-Signed-Pdf-Token',

  // -- M4 — selectedText (S1/S2 — verbatim contract excerpt; ai_prompt_payload alias) --
  'selectedText',
  'req.body.selectedText',
  'req.body.*.selectedText',
  '*.selectedText',
  '*.*.selectedText',

  // -- M4 — chatHistory (S2 — multi-turn drafting Q&A; ai_prompt_payload alias) --
  'chatHistory',
  'req.body.chatHistory',
  '*.chatHistory',
  '*.*.chatHistory',

  // -- M4 — draftSummary (S2 — drafter context; ai_prompt_payload alias) --
  'draftSummary',
  'req.body.draftSummary',
  '*.draftSummary',
  '*.*.draftSummary',

  // -- M4 — additions / deletions / modifiedClauses (S6 version-diff inputs;
  //    ai_prompt_payload alias) --
  'additions',
  'req.body.additions',
  '*.additions',
  '*.*.additions',
  'deletions',
  'req.body.deletions',
  '*.deletions',
  '*.*.deletions',
  'modifiedClauses',
  'req.body.modifiedClauses',
  '*.modifiedClauses',
  '*.*.modifiedClauses',

  // -- M4 — summaryEn (S4 regulatory-impact summary input; ai_prompt_payload alias) --
  'summaryEn',
  'req.body.summaryEn',
  '*.summaryEn',
  '*.*.summaryEn',

  // -- M5 — impactPayload / impact_payload (S11 fn_regulatory_impact_create_bulk
  //    AI-generated per-contract envelope; ai_prompt_payload alias).
  //    The whole envelope is SENSITIVE (DN-5 / project.config.json
  //    sensitiveFields covers the class via 'ai_prompt_payload'). This
  //    catches the wrapper key; the inner per-contract noteEn/noteAr/
  //    summaryAr keys are also redacted below as defence-in-depth (the
  //    M4 'summaryEn' path already covers summaryEn). resolutionNote is
  //    NOT redacted (Q8 — admin-bounded; stored verbatim by design).
  'impactPayload',
  'req.body.impactPayload',
  'req.body.*.impactPayload',
  'req.query.impactPayload',
  'req.params.impactPayload',
  '*.impactPayload',
  '*.*.impactPayload',
  'impact_payload',
  'req.body.impact_payload',
  'req.body.*.impact_payload',
  'req.query.impact_payload',
  'req.params.impact_payload',
  '*.impact_payload',
  '*.*.impact_payload',

  // -- M5 — summaryAr / summary_ar (per-contract bulk-detect payload AR
  //    text; ai_prompt_payload alias — mirrors M4 summaryEn coverage).
  'summaryAr',
  'req.body.summaryAr',
  '*.summaryAr',
  '*.*.summaryAr',
  'summary_ar',
  'req.body.summary_ar',
  '*.summary_ar',
  '*.*.summary_ar',

  // -- M5 — noteEn / noteAr / note_en / note_ar (per-contract impact
  //    short-form notes inside impactPayload; ai_prompt_payload alias).
  'noteEn',
  'req.body.noteEn',
  '*.noteEn',
  '*.*.noteEn',
  'note_en',
  'req.body.note_en',
  '*.note_en',
  '*.*.note_en',
  'noteAr',
  'req.body.noteAr',
  '*.noteAr',
  '*.*.noteAr',
  'note_ar',
  'req.body.note_ar',
  '*.note_ar',
  '*.*.note_ar',

  // -- M7 — credentialRef / credential_ref (KMS-style indirection;
  //    AC-S3-04..06 invariant). The fn_source_credential_set request body
  //    contains the literal env:VARNAME or vault:path string; never
  //    returned in any response. Audit-log redacted by fn_audit_trigger
  //    (migration 102 added 'credential_ref' to v_redact_fields). Pino
  //    safety net here covers any controller that ever logs req.body.
  'credentialRef',
  'req.body.credentialRef',
  'req.body.*.credentialRef',
  'req.query.credentialRef',
  'req.params.credentialRef',
  '*.credentialRef',
  '*.*.credentialRef',
  'credential_ref',
  'req.body.credential_ref',
  'req.body.*.credential_ref',
  'req.query.credential_ref',
  'req.params.credential_ref',
  '*.credential_ref',
  '*.*.credential_ref',

  // -- M7 — rawPayload / raw_payload (osint_signal verbatim source XML/CSV
  //    payload — sanctions entries may contain personal names + addresses).
  //    EXPOSED in /api/v1/signals API response per AC-S11; redacted only
  //    at log + audit_log layer.
  'rawPayload',
  'req.body.rawPayload',
  'req.body.*.rawPayload',
  '*.rawPayload',
  '*.*.rawPayload',
  'raw_payload',
  'req.body.raw_payload',
  'req.body.*.raw_payload',
  '*.raw_payload',
  '*.*.raw_payload',

  // -- M7 — lastErrorMessage / last_error_message (source_health upstream
  //    error text — may include 401/403 stack traces with credential
  //    fragments). Truncated to 500 chars by fn_source_health_record but
  //    still redacted at log layer for defence-in-depth.
  'lastErrorMessage',
  'req.body.lastErrorMessage',
  '*.lastErrorMessage',
  '*.*.lastErrorMessage',
  'last_error_message',
  'req.body.last_error_message',
  '*.last_error_message',
  '*.*.last_error_message',

  // -- M9 (CR-B) — aliases (party.aliases JSONB array + body field on
  //    PATCH /parties/:id and POST /admin/parties/sanctions-match).
  //    Aliases may carry UBO personal names; audit-log redacted by
  //    fn_audit_trigger via migration 116. Mirrors that DB redact list at
  //    the log layer.
  'aliases',
  'req.body.aliases',
  'req.body.*.aliases',
  'req.query.aliases',
  'req.params.aliases',
  '*.aliases',
  '*.*.aliases',

  // -- M9 (CR-B) — metadata (party.metadata + party_relationship.metadata
  //    JSONB bag). Pre-emptively redacted; the bag is intentionally
  //    extensible and may carry sensitive auxiliary fields. Audit-log
  //    redacted by fn_audit_trigger via migration 116.
  'metadata',
  'req.body.metadata',
  'req.body.*.metadata',
  'req.query.metadata',
  'req.params.metadata',
  '*.metadata',
  '*.*.metadata',

  // -- M11 (CR-D0) — Document Ingestion sensitive fields --
  //    tesseractText, gpt4oText, finalText — confidential contract OCR/AI content.
  //    ingestionError — may contain partial text or stack traces.
  //    extractedTextUri — Supabase Storage path; signed URLs only, never log raw.
  //    correctedText — reviewer-supplied correction text; SENSITIVE per design.
  'tesseractText',
  'req.body.tesseractText',
  'req.body.*.tesseractText',
  '*.tesseractText',
  '*.*.tesseractText',
  'tesseract_text',
  'req.body.tesseract_text',
  '*.tesseract_text',
  '*.*.tesseract_text',
  'gpt4oText',
  'req.body.gpt4oText',
  'req.body.*.gpt4oText',
  '*.gpt4oText',
  '*.*.gpt4oText',
  'gpt4o_text',
  'req.body.gpt4o_text',
  '*.gpt4o_text',
  '*.*.gpt4o_text',
  'finalText',
  'req.body.finalText',
  'req.body.*.finalText',
  '*.finalText',
  '*.*.finalText',
  'final_text',
  'req.body.final_text',
  '*.final_text',
  '*.*.final_text',
  'ingestionError',
  'req.body.ingestionError',
  '*.ingestionError',
  '*.*.ingestionError',
  'ingestion_error',
  'req.body.ingestion_error',
  '*.ingestion_error',
  '*.*.ingestion_error',
  'extractedTextUri',
  'req.body.extractedTextUri',
  'req.body.*.extractedTextUri',
  '*.extractedTextUri',
  '*.*.extractedTextUri',
  'extracted_text_uri',
  'req.body.extracted_text_uri',
  '*.extracted_text_uri',
  '*.*.extracted_text_uri',
  'correctedText',
  'req.body.correctedText',
  'req.body.*.correctedText',
  '*.correctedText',
  '*.*.correctedText',
  'corrected_text',
  'req.body.corrected_text',
  '*.corrected_text',
  '*.*.corrected_text',

  // -- M12 (CR-D) — Clause extraction sensitive payloads --
  //    parameters: per-clause extracted parameter map (Annex A)
  //    textExcerpts: raw contract text snippets that informed each parameter
  //    summaryEn / summaryAr: LLM-generated clause summaries (may quote contract text)
  //    queryText: semantic-search query string (free-form legal text)
  'parameters',
  'req.body.parameters',
  'req.body.*.parameters',
  '*.parameters',
  '*.*.parameters',
  'textExcerpts',
  'req.body.textExcerpts',
  'req.body.*.textExcerpts',
  '*.textExcerpts',
  '*.*.textExcerpts',
  'text_excerpts',
  'req.body.text_excerpts',
  '*.text_excerpts',
  '*.*.text_excerpts',
  'summaryEn',
  'req.body.summaryEn',
  '*.summaryEn',
  '*.*.summaryEn',
  'summaryAr',
  'req.body.summaryAr',
  '*.summaryAr',
  '*.*.summaryAr',
  'queryText',
  'req.body.queryText',
  '*.queryText',
  '*.*.queryText',
  'query_text',
  'req.body.query_text',
  '*.query_text',
  '*.*.query_text',
  'parametersCorrection',
  'req.body.parametersCorrection',
  '*.parametersCorrection',
  '*.*.parametersCorrection',
  'textExcerptsCorrection',
  'req.body.textExcerptsCorrection',
  '*.textExcerptsCorrection',
  '*.*.textExcerptsCorrection',

  // -- M13 (CR-E) — Correlation rule DSL + evaluation sensitive payloads --
  //    matchYaml / produceYaml: rule DSL source (may encode business logic)
  //    matchEvidence: raw contract/signal text fragments that triggered the rule
  //    matchEntities: entity names from the graph that matched (PII-adjacent)
  //    dismissalReason: free-form text reason for dismissing a correlation
  'matchYaml',
  'req.body.matchYaml',
  '*.matchYaml',
  '*.*.matchYaml',
  'match_yaml',
  'req.body.match_yaml',
  '*.match_yaml',
  '*.*.match_yaml',
  'produceYaml',
  'req.body.produceYaml',
  '*.produceYaml',
  '*.*.produceYaml',
  'produce_yaml',
  'req.body.produce_yaml',
  '*.produce_yaml',
  '*.*.produce_yaml',
  'matchEvidence',
  'req.body.matchEvidence',
  '*.matchEvidence',
  '*.*.matchEvidence',
  'match_evidence',
  'req.body.match_evidence',
  '*.match_evidence',
  '*.*.match_evidence',
  'matchEntities',
  'req.body.matchEntities',
  '*.matchEntities',
  '*.*.matchEntities',
  'match_entities',
  'req.body.match_entities',
  '*.match_entities',
  '*.*.match_entities',
  'dismissalReason',
  'req.body.dismissalReason',
  '*.dismissalReason',
  '*.*.dismissalReason',
  'dismissal_reason',
  'req.body.dismissal_reason',
  '*.dismissal_reason',
  '*.*.dismissal_reason',

  // -- M14 (CR-F) — Risk Scoring sensitive fields --
  //    contributingCorrelations: per-correlation MaR + rule match data (SENSITIVE per DEFECT-3 notes;
  //      redacted in audit_log by fn_audit_trigger migration 173 extension).
  //    explanation: per-dimension reason codes + MaR formula snapshot (SENSITIVE).
  //    marValue: financial exposure amount in AED — never log in plain text.
  //    dimLegal / dimFinancial / dimOperational / dimReputational / dimCompliance:
  //      individual risk dimension scores — financial intelligence, not to be logged.
  //    weightsApplied: admin weight config JSONB — financial configuration, not to be logged.
  'contributingCorrelations',
  'req.body.contributingCorrelations',
  'req.body.*.contributingCorrelations',
  '*.contributingCorrelations',
  '*.*.contributingCorrelations',
  'contributing_correlations',
  'req.body.contributing_correlations',
  '*.contributing_correlations',
  '*.*.contributing_correlations',
  'explanation',
  'req.body.explanation',
  'req.body.*.explanation',
  '*.explanation',
  '*.*.explanation',
  'marValue',
  'req.body.marValue',
  'req.body.*.marValue',
  '*.marValue',
  '*.*.marValue',
  'mar_value',
  'req.body.mar_value',
  '*.mar_value',
  '*.*.mar_value',
  'dimLegal',
  '*.dimLegal',
  '*.*.dimLegal',
  'dim_legal',
  '*.dim_legal',
  '*.*.dim_legal',
  'dimFinancial',
  '*.dimFinancial',
  '*.*.dimFinancial',
  'dim_financial',
  '*.dim_financial',
  '*.*.dim_financial',
  'dimOperational',
  '*.dimOperational',
  '*.*.dimOperational',
  'dim_operational',
  '*.dim_operational',
  '*.*.dim_operational',
  'dimReputational',
  '*.dimReputational',
  '*.*.dimReputational',
  'dim_reputational',
  '*.dim_reputational',
  '*.*.dim_reputational',
  'dimCompliance',
  '*.dimCompliance',
  '*.*.dimCompliance',
  'dim_compliance',
  '*.dim_compliance',
  '*.*.dim_compliance',
  'weightsApplied',
  'req.body.weightsApplied',
  '*.weightsApplied',
  '*.*.weightsApplied',
  'weights_applied',
  'req.body.weights_applied',
  '*.weights_applied',
  '*.*.weights_applied',

  // -- CR-C M10 — email server SMTP secret (S14) --
  //    auth_pass_ref / authPassRef (system_setting key + EmailConfigPatchDto
  //    write-only field). is_secret=true at the DB layer; redacted here as
  //    defence-in-depth across every controller log path.
  'authPassRef',
  'req.body.authPassRef',
  'req.body.*.authPassRef',
  '*.authPassRef',
  '*.*.authPassRef',
  'auth_pass_ref',
  'req.body.auth_pass_ref',
  'req.body.*.auth_pass_ref',
  '*.auth_pass_ref',
  '*.*.auth_pass_ref',
  // smtpPass + smtp_pass alias — historical name; not in the contract but
  // covered defensively in case a future caller forwards the legacy field.
  'smtpPass',
  'req.body.smtpPass',
  '*.smtpPass',
  '*.*.smtpPass',
  'smtp_pass',
  'req.body.smtp_pass',
  '*.smtp_pass',
  '*.*.smtp_pass',

  // -- CR-G M15 — AI Risk Assistant sensitive fields --
  //    query: natural language question — NEVER log verbatim (PII risk).
  //    filters: ACL-narrowing context (contract IDs, emirate, riskKind).
  //    SSE token/citation data in response chunks — never at INFO level.
  //    contextText: LLM context built from clause excerpts (contract content).
  'query',
  'req.body.query',
  '*.query',
  '*.*.query',
  'filters',
  'req.body.filters',
  '*.filters',
  '*.*.filters',
  'contextText',
  'req.body.contextText',
  '*.contextText',
  '*.*.contextText',
  // token — SSE streaming response chunk (contract excerpt risk)
  'token',
  'res.body.token',
  '*.token',
  '*.*.token',

  // -- M16 (CR-H) — Advisory Drafter + Notification Delivery sensitive fields --
  //    Audit trigger redact list extended 43→56 in migration 209.
  //    Pino paths mirror that extension as defence-in-depth.

  // generatedTextEn / generatedTextAr — LLM-generated advisory text
  'generatedTextEn',
  'req.body.generatedTextEn',
  'req.body.*.generatedTextEn',
  '*.generatedTextEn',
  '*.*.generatedTextEn',
  'generatedTextAr',
  'req.body.generatedTextAr',
  'req.body.*.generatedTextAr',
  '*.generatedTextAr',
  '*.*.generatedTextAr',

  // finalTextEn / finalTextAr — approved advisory final text
  'finalTextEn',
  'req.body.finalTextEn',
  'req.body.*.finalTextEn',
  '*.finalTextEn',
  '*.*.finalTextEn',
  'finalTextAr',
  'req.body.finalTextAr',
  'req.body.*.finalTextAr',
  '*.finalTextAr',
  '*.*.finalTextAr',

  // modifiedTextEn / modifiedTextAr — editor-supplied modification
  'modifiedTextEn',
  'req.body.modifiedTextEn',
  'req.body.*.modifiedTextEn',
  '*.modifiedTextEn',
  '*.*.modifiedTextEn',
  'modifiedTextAr',
  'req.body.modifiedTextAr',
  'req.body.*.modifiedTextAr',
  '*.modifiedTextAr',
  '*.*.modifiedTextAr',

  // templateContext — Mustache context JSONB (may contain clause text, counterparty name)
  'templateContext',
  'req.body.templateContext',
  'req.body.*.templateContext',
  '*.templateContext',
  '*.*.templateContext',

  // rejectionReason — free-form rejection rationale (min 10 chars)
  'rejectionReason',
  'req.body.rejectionReason',
  'req.body.*.rejectionReason',
  '*.rejectionReason',
  '*.*.rejectionReason',

  // bodyRendered — pre-rendered notification body (may contain advisory text)
  'bodyRendered',
  'req.body.bodyRendered',
  'req.body.*.bodyRendered',
  '*.bodyRendered',
  '*.*.bodyRendered',
  'res.body.bodyRendered',
  'res.body.data.bodyRendered',

  // dispatchRecipients — array with email addresses + rendered subjects/bodies
  'dispatchRecipients',
  'req.body.dispatchRecipients',
  '*.dispatchRecipients',
  '*.*.dispatchRecipients',

  // recipientAddress — individual email address in notification_dispatch_log
  'recipientAddress',
  'req.body.recipientAddress',
  '*.recipientAddress',
  '*.*.recipientAddress',
  'res.body.recipientAddress',

  // subject — rendered notification email subject line
  'subject',
  'req.body.subject',
  '*.subject',
  '*.*.subject',
  'res.body.subject',

  // ============================================================
  // -- M19 (CR-K) + M20 (CR-L) — Unit 7 sensitive fields --
  //    Mirrors fn_audit_trigger redact extension in mig 251
  //    (+4 net-new DB-level: body, file_uri, parameters, output_uri).
  //    parameters is already redacted above (M12).
  //    body and file_uri / output_uri are net-new here.
  // ============================================================

  // body — risk_case.body free-text narrative (M19). Sensitive — never log.
  // Sub-path scoping: don't redact the top-level Express `req.body` payload
  // wrapper itself (would blanket-redact every controller's req.body log);
  // only redact when `body` appears as a nested key.
  'req.body.body',
  '*.body',
  '*.*.body',
  'res.body.body',

  // fileUri / file_uri — risk_case_attachment.file_uri (Supabase Storage path)
  'fileUri',
  'req.body.fileUri',
  'req.body.*.fileUri',
  '*.fileUri',
  '*.*.fileUri',
  'res.body.fileUri',
  'file_uri',
  'req.body.file_uri',
  'req.body.*.file_uri',
  '*.file_uri',
  '*.*.file_uri',
  'res.body.file_uri',

  // outputUri / output_uri — report_run.output_uri (Supabase Storage path)
  'outputUri',
  'req.body.outputUri',
  'req.body.*.outputUri',
  '*.outputUri',
  '*.*.outputUri',
  'res.body.outputUri',
  'output_uri',
  'req.body.output_uri',
  'req.body.*.output_uri',
  '*.output_uri',
  '*.*.output_uri',
  'res.body.output_uri',

  // errorMessage / error_message — report_run.error_message + every fn_'s
  // OTHERS-handler SQLSTATE re-raise. Already redacted by audit trigger in
  // CR-H mig 041; mirror at the Pino layer.
  'errorMessage',
  'req.body.errorMessage',
  '*.errorMessage',
  '*.*.errorMessage',
  'res.body.errorMessage',

  // -- CR-M — Regulatory Cascade sensitive fields --
  //    Audit trigger redact list extended 58→60 in migration 281.
  //    Pino paths mirror that extension as defence-in-depth.

  // penaltyBasis — internal penalty derivation trace (JSONB) — never log
  'penaltyBasis',
  'req.body.penaltyBasis',
  'req.body.*.penaltyBasis',
  '*.penaltyBasis',
  '*.*.penaltyBasis',
  'penalty_basis',
  'req.body.penalty_basis',
  'req.body.*.penalty_basis',
  '*.penalty_basis',
  '*.*.penalty_basis',

  // remediationNote — free-text remediation note (may contain counterparty-sensitive text)
  'remediationNote',
  'req.body.remediationNote',
  'req.body.*.remediationNote',
  '*.remediationNote',
  '*.*.remediationNote',
  'remediation_note',
  'req.body.remediation_note',
  'req.body.*.remediation_note',
  '*.remediation_note',
  '*.*.remediation_note',

  // justification — fn_risk_case_accept_risk free-form min-10-char rationale
  'justification',
  'req.body.justification',
  '*.justification',
  '*.*.justification',

  // decisionNote / closureNote — narrative fields on transition + close fns
  'decisionNote',
  'req.body.decisionNote',
  '*.decisionNote',
  '*.*.decisionNote',
  'closureNote',
  'req.body.closureNote',
  '*.closureNote',
  '*.*.closureNote',
];

const baseConfig = {
  level: process.env.LOG_LEVEL || 'info',
  base: {
    service: process.env.SERVICE_NAME || 'musanad-contracts-backend',
    env: process.env.NODE_ENV || 'development',
  },
  redact: {
    paths: SENSITIVE_PATHS,
    censor: '[REDACTED]',
    remove: false,
  },
  timestamp: pino.stdTimeFunctions.isoTime,
};

let _logger: Logger | null = null;

const buildLogger = (): Logger => {
  if (isDevelopment) {
    return pino({
      ...baseConfig,
      transport: {
        target: 'pino-pretty',
        options: {
          colorize: true,
          translateTime: 'SYS:standard',
          ignore: 'pid,hostname',
        },
      },
    });
  }
  return pino(baseConfig);
};

export const logger: Logger = (() => {
  if (!_logger) _logger = buildLogger();
  return _logger;
})();

/** Sensitive paths (exported for test assertions / QA verification). */
export const SENSITIVE_REDACT_PATHS: ReadonlyArray<string> = SENSITIVE_PATHS;
