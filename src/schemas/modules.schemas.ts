/**
 * CR-V — Zod request body schemas for Admin Module Toggle endpoints.
 *
 * Used by:
 *   PATCH /api/v1/admin/modules/:key          — PatchModuleBodySchema
 *   PATCH /api/v1/admin/bundles/:code         — PatchBundleBodySchema
 *   PATCH /api/v1/admin/role-modules/:roleId/:moduleKey — PatchRoleModuleBodySchema
 */
import { z } from 'zod';

// ─── PATCH /admin/modules/:key ────────────────────────────────────────────────

export const PatchModuleBodySchema = z.object({
  isEnabled: z.boolean({
    required_error: 'isEnabled is required',
    invalid_type_error: 'isEnabled must be a boolean',
  }),
  reason: z
    .string()
    .trim()
    .max(500, 'reason must be at most 500 characters')
    .optional(),
}).strict();

export type PatchModuleBodyInferred = z.infer<typeof PatchModuleBodySchema>;

// ─── PATCH /admin/bundles/:code ───────────────────────────────────────────────

export const PatchBundleBodySchema = z.object({
  isEnabled: z.boolean({
    required_error: 'isEnabled is required',
    invalid_type_error: 'isEnabled must be a boolean',
  }),
  reason: z
    .string()
    .trim()
    .max(500, 'reason must be at most 500 characters')
    .optional(),
}).strict();

export type PatchBundleBodyInferred = z.infer<typeof PatchBundleBodySchema>;

// ─── PATCH /admin/role-modules/:roleId/:moduleKey ─────────────────────────────
// isAllowed: true = explicit allow, false = explicit deny, null = clear override

export const PatchRoleModuleBodySchema = z.object({
  isAllowed: z
    .boolean()
    .nullable()
    .default(null),
  reason: z
    .string()
    .trim()
    .max(500, 'reason must be at most 500 characters')
    .optional(),
}).strict();

export type PatchRoleModuleBodyInferred = z.infer<typeof PatchRoleModuleBodySchema>;
