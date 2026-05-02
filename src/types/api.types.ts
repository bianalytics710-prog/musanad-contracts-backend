// ============================================================
// M0 — Foundation — TypeScript Type Definitions
// Project: Musanad Contracts Hub (musanad-contracts)
// Derived from: db-design.md v1.1 (Agent 4 output, post Stage-2 micro-revision)
// Generator: Agent 5 — Contract Generator
//
// Stack targets:
//   - Backend: Express + TypeScript strict (regenerated to v2.6 default)
//   - Frontend: TanStack Start + React 19 + TS strict (Lovable preserve-stack)
//
// Conventions:
//   - JSONB keys are camelCase (matches fn_ output) — TS keys mirror those
//   - Date/time fields are ISO-8601 strings — frontend uses formatDateTime
//     (Asia/Dubai per project.config.json) for display; backend leaves them raw
//   - No `any`. Where a flexible JSON is needed: Record<string, unknown>
//   - Sensitive fields (per project.config.json sensitiveFields) are NEVER
//     exported on any response/entity type. The single exception is the
//     internal LoginUserRecord type used only by the auth controller's
//     login flow; passwordHash is stripped before any external surface.
//
// Do not edit manually — regenerate via Agent 5 if DB design changes.
// ============================================================

// ------------------------------------------------------------
// 1. Common envelope / shared types
// ------------------------------------------------------------

/**
 * Standard JSON success envelope returned by every controller.
 * BE Implementation Agent wraps fn_ JSONB output in this shape.
 */
export interface ApiResponse<T> {
  success: true;
  data: T;
  requestId?: string;
}

/**
 * Standard JSON error envelope. Pino-redacted before logging.
 * Raw PostgreSQL errors are NEVER passed through to `message` —
 * BE controllers translate them to safe messages.
 */
export interface ErrorResponse {
  success: false;
  error: {
    code: string;            // e.g. "VALIDATION_ERROR", "UNAUTHORIZED"
    message: string;         // human-readable, sanitized
    details?: Record<string, unknown> | null;
  };
  requestId?: string;
}

/**
 * Pagination envelope returned by every fn_*_list function.
 * Matches { total, page, limit, totalPages } camelCase shape.
 */
export interface PaginationMeta {
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

/**
 * Generic paginated response wrapper.
 */
export interface Paginated<T> {
  data: T[];
  pagination: PaginationMeta;
}

/**
 * Standard audit columns present on master / business tables.
 * NOTE: For `permission` and `role_permission` only `createdAt`
 * is required by the schema (S2-6 closed-as-accepted warning).
 * See PartialAuditColumns below.
 */
export interface AuditColumns {
  createdAt: string;
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
  isActive: boolean;
}

/**
 * Reduced audit shape for tables with intentional partial audit
 * (permission, role_permission). See db-design.md §1.4 / §1.5
 * and qa-stage2-report.json check S2-6.
 */
export interface PartialAuditColumns {
  createdAt: string;
  updatedAt?: string;
  createdBy?: number | null;
  updatedBy?: number | null;
  isActive?: boolean;
}

// ------------------------------------------------------------
// 2. JWT / auth payload types
// ------------------------------------------------------------

/**
 * Payload signed into both access and refresh JWTs.
 * Standard claims (sub, aud, iss, exp, iat) plus the role name
 * for fast capability checks in middleware. JTI is included for
 * refresh tokens so they can be SHA-256-hashed and blacklisted.
 */
export interface JwtPayload {
  sub: number;          // user.id
  role?: string;        // role.name (access token only)
  aud: string;          // JWT_AUDIENCE — must be validated
  iss: string;          // JWT_ISSUER — must be validated
  iat: number;          // issued-at (seconds)
  exp: number;          // expiry (seconds)
  jti?: string;         // JWT id (used by refresh tokens)
  type: 'access' | 'refresh';
}

// ------------------------------------------------------------
// 3. Entity types — derived from fn_ JSONB output structures
// ------------------------------------------------------------

/**
 * Role — derived from fn_role_list[i] JSONB output (db-design §3.3).
 * Owned by: M0
 */
export interface Role {
  id: number;
  name: string;
  description: string | null;
  permissionCount?: number;   // present in fn_role_list output, absent in nested role on User
}

/**
 * Reduced Role shape used inside other entities (e.g. User.role,
 * AuthUser.role, login response). Matches { id, name } substructure.
 */
export interface RoleRef {
  id: number;
  name: string;
}

/**
 * Permission — derived from fn_permission_list[i] JSONB output
 * (db-design §3.4). Canonical identifier is `code`, NOT `name`
 * (S2-5 / Design Note #2 / DB Architect handoff to Agent 5).
 *
 * Audit columns are PARTIAL on this table (S2-6). The catalog is
 * install-time defined and effectively read-only at runtime, so:
 *   - `createdAt` exists at the DB level but is not returned by
 *     fn_permission_list (catalog read shape strips it).
 *   - `updatedAt`, `createdBy`, `updatedBy`, `isActive` are
 *     intentionally absent.
 * The interface below mirrors the fn_ output shape; if a future
 * fn_permission_get_by_id is added, it will return createdAt only.
 */
export interface Permission {
  id: number;
  code: string;            // e.g. 'user.read.all', 'audit.read'
  module: string;          // e.g. 'user', 'audit', 'role'
  action: string;          // e.g. 'read.all', 'manage'
  description: string | null;
}

/**
 * RolePermission — junction row. PARTIAL audit cols (S2-6):
 * `id, role_id, permission_id, created_at, created_by, is_active`
 * — no updated_at/updated_by because junction rows are immutable
 * except for is_active soft-revoke. Currently no fn_ exposes this
 * row directly to the API; included for completeness so feature
 * modules / role-management UI can import it without redefining.
 */
export interface RolePermission {
  id: number;
  roleId: number;
  permissionId: number;
  createdAt: string;
  createdBy?: number | null;
  isActive?: boolean;
  // updatedAt / updatedBy intentionally absent — see S2-6
}

/**
 * User — derived from fn_user_get_by_id JSONB output (db-design §3.1).
 * Owned by: M0.
 *
 * - `permissions: string[]` is an array of permission `code` values
 *   (NOT permission names) for fast capability checks.
 * - `passwordHash` is INTENTIONALLY ABSENT — fn_user_get_by_id never
 *   returns it. Use LoginUserRecord (internal) for the login flow.
 * - `loginAttempts` / `lockedUntil` are NOT returned by fn_user_get_by_id;
 *   they are present only in LoginUserRecord (login-flow-only shape).
 */
export interface User {
  id: number;
  email: string;
  firstName: string;
  lastName: string;
  isActive: boolean;
  lastLoginAt: string | null;
  createdAt: string;
  updatedAt: string;
  role: RoleRef;
  permissions: string[];        // permission codes
}

/**
 * AuthUser — what the frontend stores in its auth state after login.
 * Equivalent to User minus the passwordHash, lockout, and audit fields
 * the client does not need.
 *
 * NOTE: AuthUser intentionally does NOT contain passwordHash —
 *       passwordHash never crosses the API boundary.
 */
export type AuthUser = Omit<User, 'createdAt' | 'updatedAt' | 'isActive' | 'lastLoginAt'>;

/**
 * UserListItem — a user row inside fn_user_list[].data[i].
 * Lighter shape than full User (no permissions[]) per db-design §3.2.
 */
export interface UserListItem {
  id: number;
  email: string;
  firstName: string;
  lastName: string;
  role: RoleRef;
  isActive: boolean;
  lastLoginAt: string | null;
  createdAt: string;
}

/**
 * LoginUserRecord — INTERNAL ONLY. The shape of fn_auth_get_user_for_login's
 * JSONB return. Contains passwordHash because the login controller needs
 * to bcrypt.compare it. This type MUST NOT be returned by any API endpoint
 * and MUST be added to pino redaction paths (per BE handoff in
 * db-design-summary.json).
 *
 * @internal
 */
export interface LoginUserRecord {
  id: number;
  email: string;
  /** SENSITIVE — bcrypt(12) hash. Pino-redact. Never expose. */
  passwordHash: string;
  firstName: string;
  lastName: string;
  loginAttempts: number;
  lockedUntil: string | null;
  isActive: boolean;
  role: RoleRef;
}

/**
 * TokenBlacklistEntry — token_blacklist row. Direct table access is
 * denied by RLS; this interface is included for completeness only.
 * `tokenHash` is sensitive and must never appear in API responses.
 *
 * @internal
 */
export interface TokenBlacklistEntry {
  id: number;
  /** SENSITIVE — SHA-256 hex digest. Never expose. */
  tokenHash: string;
  userId: number;
  blacklistedAt: string;
  expiresAt: string;
}

/**
 * AuditLogEntry — audit_log row. Reads gated by capability(audit.read)
 * (db-design §6.4). Sensitive field VALUES inside oldValues/newValues
 * are already redacted to the literal string "[REDACTED]" by
 * fn_audit_trigger before insertion (db-design §5.1).
 */
export interface AuditLogEntry {
  id: number;
  tableName: string;
  recordId: number | null;
  action: 'INSERT' | 'UPDATE' | 'DELETE';
  oldValues: Record<string, unknown> | null;
  newValues: Record<string, unknown> | null;
  changedBy: number | null;
  changedAt: string;
}

/**
 * SchemaMigration — schema_migrations row. System table, not exposed
 * via any HTTP endpoint. Included for migration runner typing.
 *
 * @internal
 */
export interface SchemaMigration {
  version: number;
  description: string;
  appliedAt: string;
}

// ------------------------------------------------------------
// 4. Request DTOs — shapes the frontend SENDS to the backend
// ------------------------------------------------------------

/**
 * Body of POST /api/v1/auth/login.
 */
export interface LoginDto {
  email: string;
  password: string;
}

/**
 * Body of POST /api/v1/auth/refresh.
 */
export interface RefreshTokenDto {
  refreshToken: string;
}

/**
 * Body of POST /api/v1/auth/logout. Authorization header carries
 * the access token; body carries the refresh token to be blacklisted.
 */
export interface LogoutDto {
  refreshToken: string;
}

/**
 * Body of POST /api/v1/users — admin creates a user.
 * Maps to fn_user_create p_data payload.
 *
 * NB: `password` (plaintext) is what the FE sends. The BE controller
 * bcrypt-hashes it (12 rounds) before passing to fn_user_create as
 * `passwordHash`. The plaintext password is pino-redacted on the
 * incoming request.
 */
export interface CreateUserDto {
  email: string;
  /** SENSITIVE on the wire — bcrypt'd by BE before storage. */
  password: string;
  firstName: string;
  lastName: string;
  roleId: number;
}

/**
 * Body of PUT /api/v1/users/:id — admin (or self for limited fields)
 * updates a user. All fields optional (partial update via fn_user_update
 * COALESCE pattern). passwordHash NOT updatable here (separate
 * fn_user_set_password reserved for M1+ password reset).
 */
export interface UpdateUserDto {
  email?: string;
  firstName?: string;
  lastName?: string;
  roleId?: number;
}

/**
 * Query parameters for GET /api/v1/users.
 */
export interface ListUsersQuery {
  page?: number;
  limit?: number;
  search?: string;
  roleId?: number;
}

/**
 * Query parameters for GET /api/v1/roles.
 */
export interface ListRolesQuery {
  page?: number;
  limit?: number;
}

/**
 * Query parameters for GET /api/v1/permissions.
 */
export interface ListPermissionsQuery {
  page?: number;
  limit?: number;
  roleId?: number;
}

// ------------------------------------------------------------
// 5. Response payloads — shapes the BE returns to the FE
// ------------------------------------------------------------

/**
 * Body of POST /api/v1/auth/login (200).
 */
export interface LoginResponse {
  accessToken: string;
  refreshToken: string;
  user: AuthUser;
}

/**
 * Body of POST /api/v1/auth/refresh (200).
 *
 * Refresh-token rotation (OWASP / RFC 6749 best practice): the server
 * blacklists the incoming refresh token and issues a NEW pair on every
 * call. Clients MUST replace BOTH tokens; reusing the old refresh token
 * after a rotation will return 401.
 */
export interface RefreshResponse {
  accessToken: string;
  refreshToken: string;
}

/**
 * Body of POST /api/v1/auth/logout (200).
 */
export interface LogoutResponse {
  success: true;
  message?: string;
}

/**
 * Body of GET /api/v1/users (200) — paginated user list.
 */
export type UserListResponse = Paginated<UserListItem>;

/**
 * Body of GET /api/v1/users/:id (200).
 */
export type UserResponse = User;

/**
 * Body of POST /api/v1/users (201) — created user shape matches User.
 */
export type CreateUserResponse = User;

/**
 * Body of PUT /api/v1/users/:id (200).
 */
export type UpdateUserResponse = User;

/**
 * Body of DELETE /api/v1/users/:id (200) — soft-delete success envelope.
 */
export interface DeleteUserResponse {
  success: true;
  message: string;
}

/**
 * Body of GET /api/v1/roles (200) — paginated role list.
 */
export type RoleListResponse = Paginated<Role>;

/**
 * Body of GET /api/v1/permissions (200) — paginated permission catalog.
 */
export type PermissionListResponse = Paginated<Permission>;

/**
 * Body of GET /api/v1/health (200).
 */
export interface HealthResponse {
  status: 'ok';
  uptime: number;        // seconds
  version: string;       // semver
  timestamp: string;     // ISO-8601
}

// ------------------------------------------------------------
// 6. Internal fn_ output helper types (BE-side only — not exposed)
// ------------------------------------------------------------

/**
 * fn_auth_record_login_failure return shape.
 * @internal
 */
export interface RecordLoginFailureResult {
  loginAttempts: number;
  lockedUntil: string | null;
  isLocked: boolean;
}

/**
 * fn_auth_record_login_success return shape.
 * @internal
 */
export interface RecordLoginSuccessResult {
  success: true;
  lastLoginAt: string;
}

/**
 * fn_auth_blacklist_token return shape.
 * @internal
 */
export interface BlacklistTokenResult {
  success: true;
}

/**
 * fn_auth_check_token_blacklist return shape.
 * @internal
 */
export interface CheckTokenBlacklistResult {
  isBlacklisted: boolean;
}

// ------------------------------------------------------------
// 7. Type guards / discriminator helpers
// ------------------------------------------------------------

export function isErrorResponse<T>(r: ApiResponse<T> | ErrorResponse): r is ErrorResponse {
  return r.success === false;
}

export function isSuccessResponse<T>(r: ApiResponse<T> | ErrorResponse): r is ApiResponse<T> {
  return r.success === true;
}

export function hasPermission(user: Pick<User, 'permissions'>, code: string): boolean {
  return user.permissions.includes(code);
}

// ------------------------------------------------------------
// 8. Sensitive-field sentinel (ground-truth list mirrored from
//    project.config.json sensitiveFields). Imported by the BE's
//    pino redaction config and the audit trigger redaction list.
//    Exported as a `const` array so a TS compile error fires if
//    a feature module forgets to extend it when adding a new
//    sensitive column.
// ------------------------------------------------------------

export const SENSITIVE_FIELD_NAMES = [
  'contract_body',
  'signer_email',
  'signer_phone',
  'emirates_id',
  'signature_image',
  'ai_prompt_payload',
  'password',
  'password_hash',          // DB column name (project.config has 'password' as sentinel)
  'token_hash',             // DB column name
  'refresh_token',
  'access_token',
  'openai_api_key',
  'anthropic_api_key',
  'smtp_password',
  'uae_pass_client_secret',
  'supabase_service_role_key',
  'jwt_secret',
] as const;

export type SensitiveFieldName = typeof SENSITIVE_FIELD_NAMES[number];

// ------------------------------------------------------------
// 9. Design notes (for downstream agents)
// ------------------------------------------------------------

/**
 * DESIGN NOTES (carry-forward from db-design.md and qa-stage2-report.json)
 *
 * 1. S2-6 closed-as-accepted: `Permission` and `RolePermission` have
 *    partial audit columns by design. Reflected in this file:
 *      - Permission: no audit cols on the API surface (catalog read shape).
 *      - RolePermission: createdAt required, others optional.
 *
 * 2. permission.code (NOT name) is the canonical identifier. The User
 *    interface carries `permissions: string[]` of codes for fast
 *    capability checks. authorise() middleware must compare against codes.
 *
 * 3. AuthUser is defined as Omit<User, ...non-essential audit fields>.
 *    It NEVER contains passwordHash. The only type that carries
 *    passwordHash is LoginUserRecord, which is marked @internal.
 *
 * 4. Date/time fields are ISO-8601 strings (`string`), not Date objects,
 *    so they serialize cleanly across BE↔FE. The frontend's
 *    formatDateTime utility (Asia/Dubai per project.config.json) parses
 *    these for display.
 *
 * 5. JWT payload `aud` and `iss` are required and MUST be validated on
 *    every token verify (CLAUDE.md §8 security rule).
 */
