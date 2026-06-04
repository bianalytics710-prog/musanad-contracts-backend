/**
 * M22 / CR-MIG-DRIVE — Google Drive connector service.
 *
 * Public surface:
 *   - buildAuthUrl()      — generates the Google consent URL + HMAC-signed state.
 *   - parseState()        — verifies + decodes HMAC state on callback.
 *   - exchangeCodeForTokens() — code → { accessToken, refreshToken, expiresAt }.
 *   - listFiles()         — paginated file enumeration inside a folder.
 *   - downloadFile()      — single-file download as Buffer.
 *   - getCachedClient()   — lazily builds an OAuth2 client bound to an
 *                           external_connection row (auto-refreshes on 401).
 *
 * Scope policy: drive.readonly. Never request write scopes (audit posture).
 *
 * Sensitive surface: any caller that touches token blobs must use
 * token-cipher.service. This module receives decrypted tokens IN-MEMORY only
 * and produces decrypted access tokens (caller persists encrypted via DEFINER fn).
 */
import { google, drive_v3 } from 'googleapis';
import { OAuth2Client } from 'google-auth-library';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { env } from '../utils/env-validation.util';
import { logger } from '../utils/logger.util';
import { InternalError, ValidationError } from '../utils/errors.util';

const SCOPES = ['https://www.googleapis.com/auth/drive.readonly'];

// ----------------------------------------------------------------
// OAuth2 client factory
// ----------------------------------------------------------------

function makeOAuthClient(): OAuth2Client {
  const e = env();
  if (!e.GOOGLE_CLIENT_ID || !e.GOOGLE_CLIENT_SECRET) {
    throw new InternalError(
      'GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET required for Google Drive connector',
    );
  }
  return new google.auth.OAuth2({
    clientId: e.GOOGLE_CLIENT_ID,
    clientSecret: e.GOOGLE_CLIENT_SECRET,
    redirectUri: e.GOOGLE_OAUTH_REDIRECT_URI,
  });
}

// ----------------------------------------------------------------
// HMAC-signed state token (CSRF protection)
// ----------------------------------------------------------------

interface StatePayload {
  tenantId: string;
  userId: number;
  returnPath: string;
  /** Issued-at epoch seconds. */
  iat: number;
}

const STATE_MAX_AGE_S = 600; // 10 minutes

function stateSecret(): string {
  const s = env().OAUTH_STATE_HMAC_SECRET;
  if (!s) throw new InternalError('OAUTH_STATE_HMAC_SECRET required for Drive OAuth state');
  return s;
}

function b64url(buf: Buffer | string): string {
  return Buffer.from(buf).toString('base64url');
}

function unb64url(s: string): Buffer {
  return Buffer.from(s, 'base64url');
}

/** Signs a JSON payload as `<base64url(JSON)>.<hex(HMAC-SHA256)>`. */
function signState(payload: StatePayload): string {
  const json = JSON.stringify(payload);
  const body = b64url(json);
  const mac = createHmac('sha256', stateSecret()).update(body).digest('hex');
  return `${body}.${mac}`;
}

/** Verifies + decodes a state token. Throws ValidationError on tamper / expiry. */
export function parseState(token: string): StatePayload {
  if (typeof token !== 'string' || !token.includes('.')) {
    throw new ValidationError('OAuth state malformed');
  }
  const [body, mac] = token.split('.');
  if (!body || !mac) throw new ValidationError('OAuth state malformed');
  const expected = createHmac('sha256', stateSecret()).update(body).digest('hex');
  const a = Buffer.from(expected, 'hex');
  const b = Buffer.from(mac, 'hex');
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    throw new ValidationError('OAuth state HMAC mismatch');
  }
  let payload: StatePayload;
  try {
    payload = JSON.parse(unb64url(body).toString('utf8')) as StatePayload;
  } catch {
    throw new ValidationError('OAuth state payload not JSON');
  }
  const ageS = Math.floor(Date.now() / 1000) - payload.iat;
  if (ageS > STATE_MAX_AGE_S || ageS < -60) {
    throw new ValidationError('OAuth state expired');
  }
  return payload;
}

/**
 * Generate the Google consent URL the FE redirects the popup to.
 * `state` is HMAC-signed and round-trips through Google to our callback.
 */
export function buildAuthUrl(args: {
  tenantId: string;
  userId: number;
  returnPath?: string;
}): { url: string; state: string } {
  const client = makeOAuthClient();
  const state = signState({
    tenantId: args.tenantId,
    userId: args.userId,
    returnPath: args.returnPath ?? '/app/admin/migration',
    iat: Math.floor(Date.now() / 1000),
  });
  const url = client.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent', // force refresh_token issuance on every consent
    scope: SCOPES,
    state,
    include_granted_scopes: true,
  });
  return { url, state };
}

// ----------------------------------------------------------------
// Token exchange
// ----------------------------------------------------------------

export interface ExchangeResult {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: Date;
  scopes: string[];
}

export async function exchangeCodeForTokens(code: string): Promise<ExchangeResult> {
  const client = makeOAuthClient();
  let tokens;
  try {
    const res = await client.getToken(code);
    tokens = res.tokens;
  } catch (err) {
    logger.error(
      { action: 'googleDrive.exchangeCode.failed', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'Google token exchange failed',
    );
    throw new InternalError('Google token exchange failed');
  }
  const accessToken = tokens.access_token;
  if (!accessToken) {
    throw new InternalError('Google did not return access_token');
  }
  const expiresMs = tokens.expiry_date ?? Date.now() + 60 * 60_000;
  return {
    accessToken,
    refreshToken: tokens.refresh_token ?? null,
    expiresAt: new Date(expiresMs),
    scopes: tokens.scope?.split(' ').filter(Boolean) ?? SCOPES,
  };
}

// ----------------------------------------------------------------
// Token refresh (worker uses this directly with decrypted refresh token)
// ----------------------------------------------------------------

export async function refreshAccessToken(
  refreshToken: string,
): Promise<Pick<ExchangeResult, 'accessToken' | 'expiresAt'>> {
  const client = makeOAuthClient();
  client.setCredentials({ refresh_token: refreshToken });
  let res;
  try {
    res = await client.refreshAccessToken();
  } catch (err) {
    logger.warn(
      { action: 'googleDrive.refresh.failed', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'Google refresh failed',
    );
    throw new InternalError('Google token refresh failed');
  }
  const t = res.credentials;
  if (!t.access_token) throw new InternalError('refresh response missing access_token');
  return {
    accessToken: t.access_token,
    expiresAt: new Date(t.expiry_date ?? Date.now() + 60 * 60_000),
  };
}

// ----------------------------------------------------------------
// Drive client factory (single-shot — caller refreshes on 401)
// ----------------------------------------------------------------

function makeDriveClient(accessToken: string): drive_v3.Drive {
  const auth = makeOAuthClient();
  auth.setCredentials({ access_token: accessToken });
  return google.drive({ version: 'v3', auth });
}

// ----------------------------------------------------------------
// List files in a folder
// ----------------------------------------------------------------

export interface DriveFileMeta {
  id: string;
  name: string;
  mimeType: string;
  size: number;
  modifiedTime: string;
  md5Checksum: string | null;
}

export async function listFiles(args: {
  accessToken: string;
  folderId: string;
}): Promise<DriveFileMeta[]> {
  const drive = makeDriveClient(args.accessToken);
  const files: DriveFileMeta[] = [];
  let pageToken: string | undefined;
  const q = [
    `'${args.folderId}' in parents`,
    `mimeType != 'application/vnd.google-apps.folder'`,
    `trashed = false`,
  ].join(' and ');
  let pages = 0;
  do {
    const res = await drive.files.list({
      q,
      pageSize: 100,
      pageToken,
      fields: 'nextPageToken, files(id,name,mimeType,size,modifiedTime,md5Checksum)',
      spaces: 'drive',
    });
    for (const f of res.data.files ?? []) {
      files.push({
        id: f.id ?? '',
        name: f.name ?? '',
        mimeType: f.mimeType ?? 'application/octet-stream',
        size: f.size ? Number(f.size) : 0,
        modifiedTime: f.modifiedTime ?? new Date().toISOString(),
        md5Checksum: f.md5Checksum ?? null,
      });
    }
    pageToken = res.data.nextPageToken ?? undefined;
    pages += 1;
    if (pages > 50) {
      logger.warn({ action: 'googleDrive.listFiles.pageCap', pages, folderId: args.folderId },
        'Drive file listing exceeded 50 pages — truncating');
      break;
    }
  } while (pageToken);
  return files;
}

// ----------------------------------------------------------------
// Download a single file as Buffer
// ----------------------------------------------------------------

export async function downloadFile(args: {
  accessToken: string;
  fileId: string;
}): Promise<Buffer> {
  const drive = makeDriveClient(args.accessToken);
  const res = await drive.files.get(
    { fileId: args.fileId, alt: 'media' },
    { responseType: 'arraybuffer' },
  );
  // arraybuffer response → data is ArrayBuffer
  const data = res.data as unknown as ArrayBuffer | Buffer;
  return Buffer.isBuffer(data) ? data : Buffer.from(data);
}
