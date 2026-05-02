/**
 * Live UAE Pass provider — STUB.
 *
 * TODO[uae-pass-integration]: Wire to the real UAE Pass IdP before go-live.
 *
 * This is a deliberate stub so a misconfigured UAE_PASS_PROVIDER=live
 * deployment fails fast and obviously rather than silently returning a
 * synthetic identity.
 *
 * INTEGRATION CHECKLIST (see also docs/uae-pass-integration.md when written):
 *
 *   1. Obtain UAE Pass production credentials:
 *        - client_id, client_secret (from UAE Pass developer portal)
 *        - SAML signing certificate (or OIDC well-known config URL)
 *        - approved redirect_uri matching UAE_PASS_REDIRECT_URI env var
 *
 *   2. Set the live env vars (env-validation.util.ts already requires them
 *      when UAE_PASS_PROVIDER=live):
 *        - UAE_PASS_CLIENT_ID
 *        - UAE_PASS_CLIENT_SECRET
 *        - UAE_PASS_AUTHORIZE_URL    (e.g. https://id.uaepass.ae/idshub/authorize)
 *        - UAE_PASS_TOKEN_URL        (e.g. https://id.uaepass.ae/idshub/token)
 *        - UAE_PASS_USERINFO_URL     (e.g. https://id.uaepass.ae/idshub/userinfo)
 *        - UAE_PASS_REDIRECT_URI
 *
 *   3. Implement initiateAuth(state) to:
 *        - generate PKCE code_verifier + code_challenge (S256)
 *        - persist code_verifier server-side keyed by state (Redis / DB)
 *        - construct authorize URL with: response_type=code, client_id,
 *          redirect_uri, state, scope=urn:uae:digitalid:profile:general,
 *          acr_values=urn:safelayer:tws:policies:authentication:level:high,
 *          code_challenge, code_challenge_method=S256
 *
 *   4. Implement handleCallback(code, state) to:
 *        - retrieve + delete the persisted code_verifier
 *        - POST to TOKEN_URL with grant_type=authorization_code, code,
 *          redirect_uri, client_id, client_secret, code_verifier
 *        - validate id_token signature against UAE Pass JWKS, validate
 *          aud, iss, exp, nonce
 *        - GET USERINFO_URL with the access_token
 *        - map response → UAEPassIdentity (sub, emiratesId, fullName*,
 *          email, phone, trustLevel from acr claim)
 *        - return identity (controller maps to local user via sub)
 *
 *   5. Audit + logging:
 *        - never log id_token, access_token, refresh_token, code_verifier
 *        - log only: action, sub (post-success), trustLevel, request_id
 *
 *   6. Tests:
 *        - mock UAE Pass discovery + token endpoints (nock or msw)
 *        - assert PKCE code_verifier is consumed exactly once
 *        - assert state mismatch rejects with 401
 */
import { NotImplementedError } from '../../utils/errors.util';
import type { UAEPassIdentity, UAEPassProvider } from './index';

export class LiveUAEPassProvider implements UAEPassProvider {
  public readonly name = 'live' as const;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  initiateAuth(_state: string): { authorizeUrl: string } {
    throw new NotImplementedError(
      'UAE_PASS_PROVIDER=live not yet implemented. See src/integrations/uae-pass/live.provider.ts TODO checklist or docs/uae-pass-integration.md.',
    );
  }

  async handleCallback(_code: string, _state: string): Promise<UAEPassIdentity> {
    throw new NotImplementedError(
      'UAE_PASS_PROVIDER=live not yet implemented. See src/integrations/uae-pass/live.provider.ts TODO checklist or docs/uae-pass-integration.md.',
    );
  }
}
