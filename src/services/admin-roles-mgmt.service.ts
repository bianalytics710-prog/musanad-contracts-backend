/**
 * CR-C — Roles & Permissions Editor service (S15, S16).
 *
 * Thin db.callFunction passthroughs. All permission gates + business logic
 * live inside the fn_ bodies. Built-in role names (per OPEN-DECISION-E) are
 * protected at the DB layer with P0001 'cannot_rename_system_role' /
 * 'cannot_delete_system_role' / 'cannot_revoke_system_grant'.
 */
import { db } from '../database/client';
import type {
  RoleCreateResult,
  RoleUpdateResult,
  RoleDeleteResult,
  RolePermissionGrantResult,
  RolePermissionRevokeResult,
  CreateRoleDto,
  UpdateRoleDto,
} from '../types/admin-roles-mgmt.types';

export const createRole = (
  actorId: number,
  dto: CreateRoleDto,
): Promise<RoleCreateResult> =>
  db.callFunction<RoleCreateResult>(
    'fn_role_create',
    [dto.name, dto.description ?? null],
    { actorId },
  );

export const updateRole = (
  actorId: number,
  id: number,
  dto: UpdateRoleDto,
): Promise<RoleUpdateResult> =>
  db.callFunction<RoleUpdateResult>(
    'fn_role_update',
    [id, dto.name ?? null, dto.description ?? null],
    { actorId },
  );

export const deleteRole = (
  actorId: number,
  id: number,
): Promise<RoleDeleteResult> =>
  db.callFunction<RoleDeleteResult>('fn_role_delete', [id], { actorId });

export const grantRolePermission = (
  actorId: number,
  roleId: number,
  permissionId: number,
): Promise<RolePermissionGrantResult> =>
  db.callFunction<RolePermissionGrantResult>(
    'fn_role_permission_grant',
    [roleId, permissionId],
    { actorId },
  );

export const revokeRolePermission = (
  actorId: number,
  roleId: number,
  permissionId: number,
): Promise<RolePermissionRevokeResult> =>
  db.callFunction<RolePermissionRevokeResult>(
    'fn_role_permission_revoke',
    [roleId, permissionId],
    { actorId },
  );
