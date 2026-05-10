/**
 * CR-C — Notification Templates types (S12, S13).
 *
 * Mirrors workspace types.ts §6. Tenant-scoped via app.current_tenant_id GUC.
 * templateId + channel are immutable post-create per AC-S12-05.
 */
import type { ApiResponse, PaginationMeta } from './api.types';
import type { DataClassification } from './admin-demo.types';

export type NotificationTemplateChannel =
  | 'email'
  | 'in_app'
  | 'teams_capture'
  | 'slack_capture';

export const NOTIFICATION_TEMPLATE_CHANNELS: ReadonlyArray<NotificationTemplateChannel> =
  ['email', 'in_app', 'teams_capture', 'slack_capture'] as const;

export type RenderLocale = 'en' | 'ar';

export const RENDER_LOCALES: ReadonlyArray<RenderLocale> = ['en', 'ar'] as const;

/**
 * Full template detail returned by fn_notification_template_get_by_id +
 * fn_notification_template_update.
 */
export interface NotificationTemplate {
  id: number;
  /** UUID — references tenant.id. Tenant-scoped via app.current_tenant_id GUC. */
  tenantId: string;
  /** Stable code-side identifier (e.g. 'signature.invitation.email'). Immutable. */
  templateId: string;
  /** Immutable after create per AC-S12-05. */
  channel: NotificationTemplateChannel;
  /** NULL for in_app channel. */
  subjectEn: string | null;
  /** NULL for in_app channel. */
  subjectAr: string | null;
  bodyEn: string;
  bodyAr: string;
  /** Declared placeholder names + types. */
  parameterSchema: Record<string, string>;
  /** concat_ws(' ', first_name, last_name) — survives half-populated names (W3). */
  lastModifiedByName: string | null;
  dataClassification: DataClassification;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
}

/**
 * Light projection used by fn_notification_template_list (no body fields,
 * no parameter_schema).
 */
export interface NotificationTemplateListItem {
  id: number;
  templateId: string;
  channel: NotificationTemplateChannel;
  subjectEn: string | null;
  subjectAr: string | null;
  lastModifiedByName: string | null;
  dataClassification: DataClassification;
  isActive: boolean;
  updatedAt: string;
}

export interface ListNotificationTemplatesResponse {
  data: NotificationTemplateListItem[];
  pagination: PaginationMeta;
}

/**
 * PATCH /api/v1/admin/notification-templates/:id body. All optional (partial
 * update). templateId and channel are silently ignored if forwarded (defence-
 * in-depth at fn signature) AND rejected by Zod schema with 400
 * { field: 'templateId', message: 'immutable_field' } per AC-S12-05.
 */
export interface NotificationTemplateUpdateDto {
  subjectEn?: string | null;
  subjectAr?: string | null;
  bodyEn?: string;
  bodyAr?: string;
  parameterSchema?: Record<string, string>;
}

/**
 * POST /api/v1/admin/notification-templates/render body.
 *
 * `parameters` values are HTML-escaped before substitution to prevent XSS
 * injection (AC-S13-07).
 */
export interface NotificationTemplateRenderRequest {
  templateId: string;
  channel: NotificationTemplateChannel;
  locale: RenderLocale;
  parameters: Record<string, string | number | boolean>;
}

/**
 * fn_notification_template_render JSONB output.
 *
 * `subject` is null for in_app channel (no subject lines).
 * `missingParameters` — declared in parameter_schema but absent from
 *                        `parameters`. Substitution leaves the literal
 *                        `{{paramName}}` placeholder intact (AC-S13-03).
 * `extraParameters` — supplied in `parameters` but not declared in
 *                      parameter_schema. Informational only (AC-S13-04).
 */
export interface NotificationTemplateRenderResult {
  subject: string | null;
  body: string;
  missingParameters: string[];
  extraParameters: string[];
}

export type ListNotificationTemplatesApiResponse =
  ApiResponse<ListNotificationTemplatesResponse>;
export type NotificationTemplateApiResponse = ApiResponse<NotificationTemplate>;
export type NotificationTemplateRenderApiResponse =
  ApiResponse<NotificationTemplateRenderResult>;
