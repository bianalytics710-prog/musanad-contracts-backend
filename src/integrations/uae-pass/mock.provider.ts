/**
 * Mock UAE Pass provider for development.
 *
 * Returns synthetic identities so the rest of the auth flow can be exercised
 * end-to-end without depending on UAE Pass federation. Not suitable for any
 * environment where a real identity must be trusted.
 *
 * Two test identities are wired:
 *   code = 'mock-admin'      → admin@musanad.local (trust sop3, full info)
 *   code = 'mock-employee'   → employee@musanad.local (trust sop2, partial)
 *   code = anything else      → generic synthetic user
 *
 * State handling (CRX-3):
 *   This provider does NOT validate `state` itself — it only checks that the
 *   parameter is present (defense-in-depth assertion). The CSRF state match
 *   is performed by the controller via state-store.consumeState before this
 *   provider is invoked. Earlier comments here claimed mock state was
 *   "intentionally lenient" — removed because that wording understated the
 *   security expectation now that the controller enforces it.
 */
import { env } from '../../utils/env-validation.util';
import type { UAEPassIdentity, UAEPassProvider } from './index';

export class MockUAEPassProvider implements UAEPassProvider {
  public readonly name = 'mock' as const;

  initiateAuth(state: string): { authorizeUrl: string } {
    const e = env();
    // The mock authorize URL is a self-pointed UI page. Real impl would
    // redirect the browser to https://id.uaepass.ae/idshub/authorize?...
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: 'mock',
      redirect_uri: e.UAE_PASS_REDIRECT_URI,
      state,
      scope: 'urn:uae:digitalid:profile:general',
      acr_values: 'urn:safelayer:tws:policies:authentication:level:low',
    });
    return {
      authorizeUrl: `mock://uae-pass/authorize?${params.toString()}`,
    };
  }

  async handleCallback(code: string, state: string): Promise<UAEPassIdentity> {
    if (!code || !state) {
      throw new Error('mock UAE Pass: code and state are required');
    }
    if (code === 'mock-admin') {
      return {
        sub: 'mock-uaepass-sub-admin',
        emiratesId: '784-1990-1234567-1',
        fullNameEn: 'System Admin',
        fullNameAr: 'المسؤول العام',
        email: 'admin@musanad.local',
        phone: '+971-50-1234567',
        trustLevel: 'mock',
        raw: { mock: true, code, state, profile: 'admin' },
      };
    }
    if (code === 'mock-employee') {
      return {
        sub: 'mock-uaepass-sub-employee',
        emiratesId: '784-1991-7654321-2',
        fullNameEn: 'Test Employee',
        fullNameAr: 'موظف الاختبار',
        email: 'employee@musanad.local',
        phone: null,
        trustLevel: 'mock',
        raw: { mock: true, code, state, profile: 'employee' },
      };
    }
    return {
      sub: `mock-uaepass-sub-${code.slice(0, 16)}`,
      emiratesId: null,
      fullNameEn: 'Mock UAE Pass User',
      fullNameAr: null,
      email: null,
      phone: null,
      trustLevel: 'mock',
      raw: { mock: true, code, state },
    };
  }
}
