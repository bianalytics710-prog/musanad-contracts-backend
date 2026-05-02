# UAE Pass Live Integration Checklist

> **Status in M0:** mocked. `UAE_PASS_PROVIDER=mock` returns a synthetic SAML/OIDC identity. `live` provider stub throws `NotImplementedError`.
> **This doc:** the runbook for the team that wires up real UAE Pass federation before go-live.
> **Generated:** 2026-05-02

UAE Pass is the federal-level digital identity platform for the UAE government and accredited private services. Live integration requires registering as a Service Provider with TDRA (Telecommunications and Digital Government Regulatory Authority), receiving credentials, and implementing OpenID Connect / SAML 2.0 with PKCE.

---

## 1. Prerequisites

- [ ] Service Provider registration approved by TDRA / UAE Pass program office.
- [ ] Staging credentials issued (`client_id`, `client_secret`, redirect URIs registered).
- [ ] Production credentials issued (separate from staging - never share).
- [ ] Service Provider certificate issued (for SAML signature verification, if SAML is used).
- [ ] Whitelisted redirect URIs match the deployed domain exactly (no trailing slashes mismatch).

---

## 2. Required env vars

Add to `musanad-contracts-backend/.env.example` (placeholders) and the production secret manager (real values):

```bash
# --- UAE Pass (LIVE) ---
UAE_PASS_PROVIDER=live

# OAuth/OIDC client credentials (issued by UAE Pass)
UAE_PASS_CLIENT_ID=
UAE_PASS_CLIENT_SECRET=

# Endpoints — STAGING vs PRODUCTION (use the right one for the env)
# Staging:
#   UAE_PASS_AUTHORIZE_URL=https://stg-id.uaepass.ae/idshub/authorize
#   UAE_PASS_TOKEN_URL=https://stg-id.uaepass.ae/idshub/token
#   UAE_PASS_USERINFO_URL=https://stg-id.uaepass.ae/idshub/userinfo
#   UAE_PASS_LOGOUT_URL=https://stg-id.uaepass.ae/idshub/logout
# Production:
#   UAE_PASS_AUTHORIZE_URL=https://id.uaepass.ae/idshub/authorize
#   UAE_PASS_TOKEN_URL=https://id.uaepass.ae/idshub/token
#   UAE_PASS_USERINFO_URL=https://id.uaepass.ae/idshub/userinfo
#   UAE_PASS_LOGOUT_URL=https://id.uaepass.ae/idshub/logout
# IMPORTANT: confirm exact URLs from your TDRA-issued onboarding pack — they may
# differ by tenant/release.
UAE_PASS_AUTHORIZE_URL=
UAE_PASS_TOKEN_URL=
UAE_PASS_USERINFO_URL=
UAE_PASS_LOGOUT_URL=

# Redirect URI (must EXACTLY match the value registered with UAE Pass)
UAE_PASS_REDIRECT_URI=https://your-production-domain.example.com/auth/uae-pass/callback

# Optional: SAML SP metadata + certs (if SAML is used in addition to / instead of OIDC)
UAE_PASS_SAML_ENTITY_ID=
UAE_PASS_SAML_CERT_PATH=/etc/secrets/uae-pass/sp-cert.pem
UAE_PASS_SAML_KEY_PATH=/etc/secrets/uae-pass/sp-key.pem
UAE_PASS_SAML_IDP_CERT_PATH=/etc/secrets/uae-pass/idp-cert.pem
```

> **Reminder:** secrets do not belong in `.env.example` - put placeholders only.

---

## 3. State-store: move out of memory

The mock implementation uses an in-memory `Map` (`src/integrations/uae-pass/state-store.ts`) for CSRF state with a 5-minute TTL. **This must change** before multi-replica or multi-process production deployment.

Pick one:

### Option A - Redis-backed state store

```typescript
// pseudo-code
await redis.set(`uaepass:state:${state}`, JSON.stringify(payload), 'EX', 300);
const raw = await redis.getdel(`uaepass:state:${state}`);  // single-use
```

Already viable - `ioredis` is in dep list (used by `rate-limiter-flexible`).

### Option B - DB-backed state store

```sql
CREATE TABLE IF NOT EXISTS uae_pass_state (
  state TEXT PRIMARY KEY,
  redirect_after TEXT,
  pkce_code_verifier TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_uae_pass_state_expires ON uae_pass_state(expires_at);
-- Cleanup: DELETE FROM uae_pass_state WHERE expires_at < now();
```

`fn_uae_pass_state_consume(p_state)` returns + deletes atomically. Append-only audit handled by inserting into `audit_log` if you want the trail.

Either way: replace `src/integrations/uae-pass/state-store.ts` to use the chosen backend. Keep the public API (`store(state, payload, ttlSeconds)`, `consume(state)`) identical so call sites do not change.

---

## 4. PKCE support

UAE Pass requires PKCE (Proof Key for Code Exchange) for OAuth/OIDC flows. The current mock skips PKCE. Add to `live.provider.ts`:

1. **At `/initiate`:** generate `code_verifier` (43-128 char URL-safe random string), compute `code_challenge = BASE64URL(SHA256(code_verifier))`, persist `code_verifier` next to the state, return only `code_challenge` + `code_challenge_method=S256` in the authorize URL.
2. **At `/callback`:** look up `code_verifier` by state, include it in the token-exchange request to `UAE_PASS_TOKEN_URL`.

Library suggestion: `pkce-challenge` (small, no deps) or `openid-client` (full OIDC RP - covers PKCE, discovery, token validation).

---

## 5. SAML signature verification (if SAML federation is used)

UAE Pass supports SAML 2.0 federation in addition to / sometimes instead of OIDC. If your onboarding chooses SAML:

- [ ] Verify the IdP signature on every assertion using `UAE_PASS_SAML_IDP_CERT_PATH`.
- [ ] Sign your SP requests using `UAE_PASS_SAML_KEY_PATH`.
- [ ] Validate `Issuer`, `Audience`, `NotBefore`, `NotOnOrAfter`, and the assertion `InResponseTo` matches your SP request id.
- [ ] Reject replays - cache `Assertion ID` for at least the lifetime of `NotOnOrAfter`.

Library suggestion: `@node-saml/node-saml` (active maintenance) or `samlify`.

If you stick with OIDC only, this section is N/A but verify with the UAE Pass program office which protocol your tenant uses.

---

## 6. Certificate management

- [ ] Document where SP certificate / key are stored (filesystem path mounted from secret manager? KMS-decrypted at startup?).
- [ ] Document rotation policy. UAE Pass typically allows 1-2 years per cert.
- [ ] Document the cutover plan: register the new cert with UAE Pass, update SP env vars, deploy. Run both certs in parallel during the rollover window if UAE Pass allows multiple registered certs (some tenants do).
- [ ] Add a calendar reminder 60 days before cert expiry.

---

## 7. Identity claim mapping

UAE Pass returns rich identity claims. Map them to internal user records:

| UAE Pass claim | Internal field | Notes |
|---|---|---|
| `sub` | external identifier | Treat as opaque; never derive from email. |
| `email` | `"user".email` | Use as the join key when linking to existing accounts. |
| `firstname_en` / `firstname_ar` | `"user".first_name` | Default to EN; AR available for bilingual UI. |
| `lastname_en` / `lastname_ar` | `"user".last_name` | Same. |
| `idn` (Emirates ID) | `[SENSITIVE]` - if stored, must be in the redacted-fields list (already is - `emirates_id`). | Probably do not store unless required for compliance. |
| `mobile` | optional - if stored, redact in logs (`signer_phone` is already in the redact list). | |
| `acr` (assurance level) | `trust_level` (SOP1 / SOP2 / SOP3) | Persist for audit; gate sensitive actions on minimum SOP2. |
| `amr` (authentication method) | optional log field | |

**Account linking flow:**
- New email -> create `"user"` row with `is_active=true`, default role (`User`).
- Existing email -> link UAE Pass `sub` to existing account (consider a separate `user_external_identity` table mapping `(provider, sub, user_id)` so multiple federations are supported).

---

## 8. Endpoints to update

- `src/integrations/uae-pass/live.provider.ts` - replace the `throw NotImplementedError` with the OIDC discovery + token exchange + userinfo flow.
- `src/integrations/uae-pass/factory.ts` - already returns the live provider when `UAE_PASS_PROVIDER=live`.
- `src/controllers/auth.controller.ts` - the `/initiate` and `/callback` handlers are provider-agnostic; the live provider plugs in via the factory. Verify the controller still: (a) generates state via state-store, (b) passes it to the provider's `getAuthorizeUrl`, (c) calls `provider.exchangeCode(code, state)` on callback, (d) issues the local JWT pair on success.
- `src/database/migrations/NNN_*.sql` - if Option B (DB-backed state store), add the migration.

---

## 9. Mock-to-live cutover

Pre-cutover:
- [ ] Real env vars in production secret manager.
- [ ] Real UAE Pass test account from TDRA available for verification.
- [ ] Redirect URIs registered with both staging and prod entries.
- [ ] State-store moved to Redis or DB (Section 3).
- [ ] PKCE implemented (Section 4).
- [ ] SAML signature verification, if applicable (Section 5).
- [ ] Certificates installed and access controls in place (Section 6).
- [ ] Identity claim mapping logic deployed (Section 7).

Cutover:
1. Deploy new code with `UAE_PASS_PROVIDER=live` in staging only.
2. Run end-to-end test with the UAE Pass test account: `/initiate` -> redirect to UAE Pass staging IdP -> consent -> callback -> JWT issued -> `GET /api/v1/users/me` returns the federated user.
3. Verify state replay rejection: present an already-consumed state -> expect 401.
4. Verify expired state rejection: wait > 5 minutes -> expect 401.
5. Promote to production with production-tier env vars.
6. Smoke test in production with a known test account.

Rollback:
- Set `UAE_PASS_PROVIDER=mock` (falls back to mock provider). Existing federated sessions remain valid until refresh expires (7d) - clear them via `TRUNCATE token_blacklist` or per-user `is_active=false` if needed.

---

## 10. References

- UAE Pass Service Provider integration manual - issued by TDRA upon SP registration.
- OpenID Connect Core 1.0 - https://openid.net/specs/openid-connect-core-1_0.html
- RFC 7636 (PKCE) - https://datatracker.ietf.org/doc/html/rfc7636
- SAML 2.0 spec - https://docs.oasis-open.org/security/saml/v2.0/

---

*Generated by Documentation Generator. Owner of this checklist when execution starts: the engineer who picks up the UAE Pass live-integration ticket. Cross-reference: `dev-handoff.md` Section 6, `lovable-handoff.md` Section 3 G3.*
