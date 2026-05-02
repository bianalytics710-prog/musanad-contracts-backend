/**
 * UAE Pass provider abstraction (decisions.md G3).
 *
 * Two implementations:
 *   - mock (default): returns a synthetic identity for dev. No external IdP.
 *   - live (stub): comprehensive TODO[uae-pass-integration] markers; throws
 *     NotImplementedError until the real federation work lands before go-live.
 *
 * Selected via UAE_PASS_PROVIDER=mock|live env var.
 *
 * NOTE: These endpoints are NOT in the original M0 OpenAPI spec — they
 * were added per the developer decisions record (G3). When the live
 * integration is wired, regenerate api-contracts.json + types.ts to
 * include them as first-class.
 */
export interface UAEPassIdentity {
  /**
   * UAE Pass `sub` (subject) identifier — opaque, persistent per user
   * within a UAE Pass tenant.
   */
  sub: string;
  emiratesId?: string | null;
  fullNameEn?: string | null;
  fullNameAr?: string | null;
  email?: string | null;
  phone?: string | null;
  /** Trust level: 'sop1' | 'sop2' | 'sop3' for live; mock returns 'mock'. */
  trustLevel: string;
  /** Raw provider payload — kept for audit/debug; sensitive (do not log). */
  raw: Record<string, unknown>;
}

export interface UAEPassProvider {
  readonly name: 'mock' | 'live';
  /**
   * Build the URL the FE redirects the browser to. `state` is the CSRF token
   * the caller generated; the callback handler validates it on return.
   */
  initiateAuth(state: string): { authorizeUrl: string };
  /**
   * Exchange the IdP authorization `code` (and confirm `state`) for an
   * identity payload. Throws on any verification failure.
   */
  handleCallback(code: string, state: string): Promise<UAEPassIdentity>;
}

import { env } from '../../utils/env-validation.util';
import { MockUAEPassProvider } from './mock.provider';
import { LiveUAEPassProvider } from './live.provider';

let _instance: UAEPassProvider | null = null;

export const getUAEPassProvider = (): UAEPassProvider => {
  if (_instance) return _instance;
  const e = env();
  if (e.UAE_PASS_PROVIDER === 'live') {
    _instance = new LiveUAEPassProvider();
  } else {
    _instance = new MockUAEPassProvider();
  }
  return _instance;
};

export const _resetUAEPassProvider = (): void => {
  _instance = null;
};
