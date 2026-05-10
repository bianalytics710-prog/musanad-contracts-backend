/**
 * CR-C — Roles & Permissions Editor Zod schemas (S15, S16).
 *
 * Trim-non-empty rule for `name` to prevent the FE from accidentally
 * persisting whitespace-only role names. Length cap = 100 (matches DB
 * `role.name TEXT NOT NULL UNIQUE` column with no implicit limit; we cap
 * defensively at the API boundary).
 */
import { z } from 'zod';

export const createRoleBodySchema = z
  .object({
    name: z
      .string({ required_error: 'name_required' })
      .trim()
      .min(1, 'name_required')
      .max(100, 'name_too_long'),
    description: z.string().trim().max(500).nullable().optional(),
  })
  .strict();

export const updateRoleBodySchema = z
  .object({
    name: z.string().trim().min(1, 'name_required').max(100, 'name_too_long').optional(),
    description: z.string().trim().max(500).nullable().optional(),
  })
  .strict()
  .refine(
    (val) => Object.keys(val).length > 0,
    'At least one field must be provided for update',
  );

export const roleIdParamSchema = z.object({
  id: z.coerce.number().int().positive(),
});

export const rolePermissionParamsSchema = z.object({
  id: z.coerce.number().int().positive(),
  permId: z.coerce.number().int().positive(),
});

export type CreateRoleBodyInferred = z.infer<typeof createRoleBodySchema>;
export type UpdateRoleBodyInferred = z.infer<typeof updateRoleBodySchema>;
export type RoleIdParamInferred = z.infer<typeof roleIdParamSchema>;
export type RolePermissionParamsInferred = z.infer<typeof rolePermissionParamsSchema>;
