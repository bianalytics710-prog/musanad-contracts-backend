/**
 * CR-C — Roles & Permissions Editor types (S15, S16).
 *
 * Mirrors workspace types.ts §5. The 8 BUILT_IN_ROLE_NAMES are immutable per
 * OPEN-DECISION-E — fn_role_update / fn_role_delete reject any change to
 * these names with 422 'cannot_rename_system_role' / 'cannot_delete_system_role'.
 */
import type { ApiResponse } from './api.types';

export type BuiltInRoleName =
  | 'Super Admin'
  | 'Admin'
  | 'User'
  | 'platform_admin'
  | 'executive'
  | 'legal_counsel'
  | 'contract_drafter'
  | 'contract_approver';

export const BUILT_IN_ROLE_NAMES: ReadonlyArray<BuiltInRoleName> = [
  'Super Admin',
  'Admin',
  'User',
  'platform_admin',
  'executive',
  'legal_counsel',
  'contract_drafter',
  'contract_approver',
] as const;

/** POST /api/v1/admin/roles body. */
export interface CreateRoleDto {
  /** Required. Trim-non-empty. UNIQUE — collision returns 409. */
  name: string;
  description?: string | null;
}

/** PATCH /api/v1/admin/roles/:id body. */
export interface UpdateRoleDto {
  /**
   * Optional. Built-in role names reject rename with 422
   * 'cannot_rename_system_role'.
   */
  name?: string;
  description?: string | null;
}

export interface RoleCreateResult {
  id: number;
  name: string;
}

export interface RoleUpdateResult {
  id: number;
  name: string;
  description: string | null;
  isActive: boolean;
}

export interface RoleDeleteResult {
  success: true;
  id: number;
}

/**
 * fn_role_permission_grant JSONB output. Idempotent — re-granting an existing
 * grant returns `granted: true, alreadyExists: true` (no error).
 */
export interface RolePermissionGrantResult {
  granted: true;
  alreadyExists: boolean;
}

/**
 * fn_role_permission_revoke JSONB output. Idempotent — revoking a non-existent
 * grant returns `revoked: true, alreadyAbsent: true` (no error).
 *
 * Super Admin essential grants (8 hard-coded permission codes) reject with
 * 422 'cannot_revoke_system_grant'.
 */
export interface RolePermissionRevokeResult {
  revoked: true;
  alreadyAbsent: boolean;
}

export type RoleCreateApiResponse = ApiResponse<RoleCreateResult>;
export type RoleUpdateApiResponse = ApiResponse<RoleUpdateResult>;
export type RoleDeleteApiResponse = ApiResponse<RoleDeleteResult>;
export type RolePermissionGrantApiResponse =
  ApiResponse<RolePermissionGrantResult>;
export type RolePermissionRevokeApiResponse =
  ApiResponse<RolePermissionRevokeResult>;
