// ============================================================
// M0 — User / Role / Permission Zod schemas
// Mirror of workspace schemas.ts (user subset).
// ============================================================
import { z } from 'zod';

/**
 * Strong-password rule — enforced ONLY on createUserSchema (not loginSchema).
 * ≥8 chars, ≥1 upper, ≥1 lower, ≥1 digit, ≥1 symbol. Matches BE bcrypt(12) flow.
 */
const passwordSchema = z
  .string()
  .min(8, 'Password must be at least 8 characters')
  .max(128, 'Password must be at most 128 characters')
  .regex(/[A-Z]/, 'Password must contain an uppercase letter')
  .regex(/[a-z]/, 'Password must contain a lowercase letter')
  .regex(/[0-9]/, 'Password must contain a digit')
  .regex(/[^A-Za-z0-9]/, 'Password must contain a symbol');

const emailSchema = z
  .string()
  .trim()
  .min(1, 'Email is required')
  .max(255, 'Email is too long')
  .email('Invalid email address');

const idSchema = z.coerce.number().int().positive();

const pageSchema = z.coerce.number().int().min(1).default(1);
const userListLimitSchema = z.coerce.number().int().min(1).max(100).default(20);
const catalogLimitSchema = z.coerce.number().int().min(1).max(200).default(50);

// ----- Create / Update / Param schemas -------------------------------------

export const createUserSchema = z
  .object({
    email: emailSchema,
    password: passwordSchema,
    firstName: z.string().trim().min(1, 'First name is required').max(100),
    lastName: z.string().trim().min(1, 'Last name is required').max(100),
    roleId: z.number().int().positive(),
  })
  .strict();
export type CreateUserInput = z.infer<typeof createUserSchema>;

export const updateUserSchema = z
  .object({
    email: emailSchema.optional(),
    firstName: z.string().trim().min(1).max(100).optional(),
    lastName: z.string().trim().min(1).max(100).optional(),
    roleId: z.number().int().positive().optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'At least one field must be provided',
  });
export type UpdateUserInput = z.infer<typeof updateUserSchema>;

export const userIdParamSchema = z.object({ id: idSchema });
export type UserIdParam = z.infer<typeof userIdParamSchema>;

export const listUsersQuerySchema = z.object({
  page: pageSchema.optional(),
  limit: userListLimitSchema.optional(),
  search: z.string().trim().min(1).max(100).optional(),
  roleId: z.coerce.number().int().positive().optional(),
});
export type ListUsersQueryInput = z.infer<typeof listUsersQuerySchema>;

// ----- Catalog query schemas -----------------------------------------------

export const listRolesQuerySchema = z.object({
  page: pageSchema.optional(),
  limit: catalogLimitSchema.optional(),
});
export type ListRolesQueryInput = z.infer<typeof listRolesQuerySchema>;

export const listPermissionsQuerySchema = z.object({
  page: pageSchema.optional(),
  limit: catalogLimitSchema.optional(),
  roleId: z.coerce.number().int().positive().optional(),
});
export type ListPermissionsQueryInput = z.infer<typeof listPermissionsQuerySchema>;

// ----- Bundled export ------------------------------------------------------

export const userSchemas = {
  createUserSchema,
  updateUserSchema,
  userIdParamSchema,
  listUsersQuerySchema,
  listRolesQuerySchema,
  listPermissionsQuerySchema,
} as const;
