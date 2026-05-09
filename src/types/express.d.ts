/**
 * Express Request augmentation. Pulled in by tsconfig include glob.
 */
import type { Logger } from 'pino';

export interface AuthUserContext {
  id: number;
  role: string;
  email: string;
  /** permission codes from fn_user_get_by_id; used by authorise() */
  permissions: string[];
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      requestId: string;
      logger: Logger;
      user?: AuthUserContext;
      /**
       * Optional helper holding the access-token's `sub` claim before user
       * lookup completes. RLS middleware uses it as a fallback so the GUC
       * is set even if downstream code does not populate `req.user`.
       */
      authUserId?: number;
      /**
       * M7 — tenant context derived from JWT `tenantId` claim (when present)
       * or ADNOC seed UUID fallback (Q-DA4 single-tenant demo). Set by
       * rls.middleware after JWT verification. Used by every M7 controller
       * to inject `app.current_tenant_id` GUC via db.callFunction({ tenantId }).
       */
      tenantId?: string;
    }
  }
}

export {};
