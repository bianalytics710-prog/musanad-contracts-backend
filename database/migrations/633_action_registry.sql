-- MIGRATION: 633_action_registry.sql
-- Date: 2026-06-12
-- Module: AI Chat Actions (Prompt-driven actions via floating chatbot)
-- Description:
--   System catalog of "actions" the AI Chat Orchestrator can propose on
--   behalf of the user. Each row declares one action — its slug, the
--   human-readable label, the natural-language description the LLM reads
--   to decide when to invoke it, the JSON-Schema for its parameters, the
--   required permission, and the handler key the BE resolves to a code
--   function.
--
--   Two kinds:
--     - resolver   : read-only helper the LLM calls to disambiguate
--                    references during the tool loop (e.g. lookup_contract_by_number).
--                    Server-executes inline, feeds result back to the model,
--                    does NOT require user confirmation.
--     - write_action : a mutating action (e.g. request_similar_contract).
--                    LLM tool_call short-circuits the loop, persists as
--                    a proposal in action_invocation_log (mig 635),
--                    waits for the user to click Confirm in the proposal
--                    card, then executes the handler.
--
--   This is a SYSTEM catalog — no tenant_id, no RLS. Reads are open to
--   any authenticated session (the chat orchestrator filters out actions
--   the caller lacks permission for at runtime). Writes happen only via
--   migrations or the platform_admin /admin/ai-actions UI (which only
--   toggles is_enabled per-tenant — see mig 634).
--
--   Seed:
--     4 resolvers + 2 write actions, all driven by EXISTING permissions
--     (work.create / work.read.assigned / contract.read / user.read).
--     No new permissions invented — the LLM sees only what each caller's
--     role already grants them via REST.

BEGIN;

-- 1. Table -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.action_registry (
  code                  TEXT         PRIMARY KEY,
  kind                  TEXT         NOT NULL
                          CHECK (kind IN ('resolver','write_action')),
  label                 TEXT         NOT NULL,
  description_for_llm   TEXT         NOT NULL,
  parameters_schema     JSONB        NOT NULL,
  required_permission   TEXT         NOT NULL,
  handler_id            TEXT         NOT NULL,
  enabled_by_default    BOOLEAN      NOT NULL DEFAULT TRUE,
  is_destructive        BOOLEAN      NOT NULL DEFAULT FALSE,
  sort_order            INTEGER      NOT NULL DEFAULT 100,
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active             BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE  public.action_registry IS
  'System catalog of AI Chat Orchestrator tools. Resolvers run server-side without confirmation; write_actions short-circuit the LLM loop into a proposal+confirm flow.';
COMMENT ON COLUMN public.action_registry.code IS
  'Stable slug (snake_case). Used as OpenAI tool name and as the FK from action_invocation_log + tenant_action_setting.';
COMMENT ON COLUMN public.action_registry.kind IS
  'resolver: read-only helper run inline during the LLM tool loop. write_action: mutating action that materialises as a proposal pending user confirm.';
COMMENT ON COLUMN public.action_registry.description_for_llm IS
  'The natural-language tool description fed to the model. Should be specific enough that the LLM picks the right action and prompts for missing params, but not leak implementation detail.';
COMMENT ON COLUMN public.action_registry.parameters_schema IS
  'JSON Schema (draft-07) for the action parameters. Becomes the OpenAI tool parameters field verbatim.';
COMMENT ON COLUMN public.action_registry.required_permission IS
  'Existing permission.code the caller must hold (or be granted via role) for this action to appear in their available toolset. Reuse — do not invent new perms here.';
COMMENT ON COLUMN public.action_registry.handler_id IS
  'BE code lookup key — _actions/_registry.ts maps this to an async (params, ctx) => receipt handler.';
COMMENT ON COLUMN public.action_registry.enabled_by_default IS
  'When a tenant has no override row in tenant_action_setting, this is the effective enabled state. Mig 634 layer.';
COMMENT ON COLUMN public.action_registry.is_destructive IS
  'Future-use flag for UI to render extra confirmation friction. v1 actions are non-destructive (only create work_order rows).';

-- No audit trigger — action_registry's PK is `code` (TEXT, no id column),
-- and fn_audit_trigger uses NEW.id / OLD.id. Catalog changes are managed
-- via migrations only (no live admin CRUD on the catalog itself, only on
-- the tenant-override layer in tenant_action_setting), so an audit trail
-- isn't load-bearing here.

-- 2. Seed --------------------------------------------------------------

INSERT INTO public.action_registry
  (code, kind, label, description_for_llm, parameters_schema, required_permission, handler_id, enabled_by_default, is_destructive, sort_order)
VALUES
-- ── RESOLVERS (read-only inline tools) ──────────────────────────────
(
  'lookup_contract_by_number',
  'resolver',
  'Look up a contract by number',
  'Resolve a contract by its human-facing contract_number (e.g. CT-2026-000028). Use this when the user references a contract by number but you do not yet have its internal id. Returns id, title, counterparty and contract type. If the number is not unique or not found, the result will tell you so — surface the disambiguation to the user.',
  '{
    "type":"object",
    "properties":{
      "number":{"type":"string","description":"Contract number such as CT-2026-000028","minLength":1,"maxLength":64}
    },
    "required":["number"],
    "additionalProperties":false
  }'::jsonb,
  'contract.read',
  'lookup_contract_by_number',
  TRUE,
  FALSE,
  10
),
(
  'find_drafters',
  'resolver',
  'Find drafters available to assign work to',
  'List active drafters (contract_drafter role) that the caller can assign work to, sorted by current open workload ascending. Use this when the user wants to assign a draft request but does not name a specific person, or when you need to disambiguate a first-name reference.',
  '{
    "type":"object",
    "properties":{
      "query":{"type":"string","description":"Optional partial name to filter by","maxLength":80}
    },
    "additionalProperties":false
  }'::jsonb,
  'work.create',
  'find_drafters',
  TRUE,
  FALSE,
  20
),
(
  'find_users',
  'resolver',
  'Find users by name',
  'Search active users (any role) by partial name. Use this to resolve the "requestor" / "asked by" reference when the user types something like "Sara asked over WhatsApp".',
  '{
    "type":"object",
    "properties":{
      "query":{"type":"string","description":"Partial name or email","minLength":1,"maxLength":80}
    },
    "required":["query"],
    "additionalProperties":false
  }'::jsonb,
  'work.read.assigned',
  'find_users',
  TRUE,
  FALSE,
  30
),
(
  'find_parties',
  'resolver',
  'Find counterparties (customers / vendors)',
  'Search existing parties (counterparties) by partial name. If the user refers to a brand-new counterparty that does not exist yet, do not pick one of these — instead ask the user whether to create a new prospect, or use a free-text prospect name in the write action.',
  '{
    "type":"object",
    "properties":{
      "query":{"type":"string","description":"Partial party name","minLength":1,"maxLength":120}
    },
    "required":["query"],
    "additionalProperties":false
  }'::jsonb,
  'work.read.assigned',
  'find_parties',
  TRUE,
  FALSE,
  40
),
-- ── WRITE ACTIONS (need user confirmation) ──────────────────────────
(
  'request_similar_contract',
  'write_action',
  'Request a similar contract',
  'Create a work order asking a drafter to produce a new contract modelled on an existing one. Use this when an executive (or anyone with the work.create permission) says something like "Draft a similar MSA for Vibrant Energy based on CT-2026-000028, assign to Hala". Either counterpartyId (existing party) OR counterpartyProspectName (new prospect) must be supplied, never both. instructionNote captures any briefing text the requester adds.',
  '{
    "type":"object",
    "properties":{
      "sourceContractId":{"type":"integer","minimum":1,"description":"Internal id of the contract being modelled. Resolve via lookup_contract_by_number if you only have the contract_number."},
      "assignedDrafterId":{"type":"integer","minimum":1,"description":"Internal user id of the drafter the work is being assigned to."},
      "counterpartyId":{"type":["integer","null"],"minimum":1,"description":"Existing party id. Mutually exclusive with counterpartyProspectName."},
      "counterpartyProspectName":{"type":["string","null"],"description":"Free-text name when the counterparty is a brand-new prospect not yet onboarded. Mutually exclusive with counterpartyId.","maxLength":200},
      "instructionNote":{"type":["string","null"],"description":"Optional briefing the requester wants to communicate to the drafter.","maxLength":2000}
    },
    "required":["sourceContractId","assignedDrafterId"],
    "additionalProperties":false
  }'::jsonb,
  'work.create',
  'request_similar_contract',
  TRUE,
  FALSE,
  100
),
(
  'add_to_my_queue',
  'write_action',
  'Add a task to my work queue',
  'Self-assigned manual work_order entry for tasks that arrived outside the system (email, chat, in person). Used by drafters (and anyone with the work.read.assigned permission). requestType selects what kind of work this is. requestorUserId is the person who asked for the work (NOT the caller — the caller is always the assignee).',
  '{
    "type":"object",
    "properties":{
      "requestType":{"type":"string","enum":["contract_draft_request","contract_returned","comment_response"],"description":"Kind of work being captured."},
      "instructionNote":{"type":"string","minLength":1,"maxLength":2000,"description":"Free-text description of the work."},
      "requestorUserId":{"type":"integer","minimum":1,"description":"User id of the person who asked for the work."},
      "initialStage":{"type":"string","enum":["not_started","in_progress","completed"],"description":"Stage to seed the row at. Defaults to not_started."},
      "sourceContractId":{"type":["integer","null"],"minimum":1,"description":"Optional contract id this work relates to (e.g. a contract to review)."}
    },
    "required":["requestType","instructionNote","requestorUserId"],
    "additionalProperties":false
  }'::jsonb,
  'work.read.assigned',
  'add_to_my_queue',
  TRUE,
  FALSE,
  110
)
ON CONFLICT (code) DO NOTHING;

COMMIT;
