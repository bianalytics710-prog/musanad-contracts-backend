// ============================================================
// M0 — Auth Zod schemas
// Mirror of workspace schemas.ts (auth subset). `.strict()` on
// every incoming DTO to reject unknown keys (defense-in-depth
// against schema drift / privilege escalation).
// ============================================================
import { z } from 'zod';

const emailSchema = z
  .string()
  .trim()
  .min(1, 'Email is required')
  .max(255, 'Email is too long')
  .email('Invalid email address');

/**
 * POST /api/v1/auth/login
 * Note: login uses plain z.string() for password (NOT the strong-password
 * rule) — login validates against the stored hash, not against complexity.
 * Forcing complexity at login would block legacy/test passwords.
 */
export const loginSchema = z
  .object({
    email: emailSchema,
    password: z.string().min(1, 'Password is required').max(128),
  })
  .strict();
export type LoginInput = z.infer<typeof loginSchema>;

/**
 * POST /api/v1/auth/refresh
 */
export const refreshTokenSchema = z
  .object({
    refreshToken: z.string().min(1, 'Refresh token is required'),
  })
  .strict();
export type RefreshTokenInput = z.infer<typeof refreshTokenSchema>;

/**
 * POST /api/v1/auth/logout
 */
export const logoutSchema = z
  .object({
    refreshToken: z.string().min(1, 'Refresh token is required'),
  })
  .strict();
export type LogoutInput = z.infer<typeof logoutSchema>;

// ----- UAE Pass (mocked for dev) ---------------------------------------
// These endpoints are NOT in the original M0 OpenAPI spec — they were added
// per decisions.md G3. See src/integrations/uae-pass/ for implementation.

/**
 * POST /api/v1/auth/uae-pass/initiate — body optional (returns auth URL).
 */
export const uaePassInitiateSchema = z
  .object({
    redirectAfter: z.string().url().optional(),
  })
  .strict();
export type UaePassInitiateInput = z.infer<typeof uaePassInitiateSchema>;

/**
 * POST /api/v1/auth/uae-pass/callback — code + state from UAE Pass IdP.
 * In mock mode, code/state can be any non-empty strings.
 */
export const uaePassCallbackSchema = z
  .object({
    code: z.string().min(1, 'Authorization code is required'),
    state: z.string().min(1, 'state is required'),
  })
  .strict();
export type UaePassCallbackInput = z.infer<typeof uaePassCallbackSchema>;
