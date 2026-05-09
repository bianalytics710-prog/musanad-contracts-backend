/**
 * M7 — Shared fetch helpers for OSINT source adapters.
 *
 * Two roles:
 *   1. attachUserAgent(init?) — add a Musanad-branded User-Agent so endpoints
 *      that gate on UA (EU/Reuters/Platts) don't reject our requests with
 *      a stock-Node UA 403.
 *   2. probeReachable(url) — health-check probe via GET (not HEAD). HEAD is
 *      unreliable in practice: many CDNs reject HEAD with 403/405/404, signed
 *      Azure/AWS URLs only honor GET, and per-route auth gates often allow
 *      GET-with-Range while denying HEAD entirely. We do a GET, immediately
 *      cancel the body, and translate the status to a HealthState.
 */

const MUSANAD_UA =
  'Mozilla/5.0 (compatible; Musanad-OSINT/1.0; +https://musanad.app)';

export const fetchWithUa = (
  url: string,
  init: RequestInit = {},
): Promise<Response> => {
  const headers = new Headers(init.headers ?? {});
  if (!headers.has('User-Agent')) {
    headers.set('User-Agent', MUSANAD_UA);
  }
  if (!headers.has('Accept')) {
    headers.set('Accept', '*/*');
  }
  return fetch(url, { ...init, headers, redirect: init.redirect ?? 'follow' });
};

export type ProbeResult =
  | { state: 'healthy'; status: number }
  | { state: 'unauthorised'; status: number }
  | { state: 'failing'; status: number; error: string }
  | { state: 'failing'; status: -1; error: string };

/**
 * GET-based reachability probe. Cancels the body as soon as the status line
 * lands so we don't download multi-MB sanctions XML during a health check.
 *
 * Range header asks the server to return only the first byte; servers that
 * don't support Range fall back to a normal GET, which we cancel on read.
 */
export const probeReachable = async (url: string): Promise<ProbeResult> => {
  try {
    const res = await fetchWithUa(url, {
      method: 'GET',
      headers: { Range: 'bytes=0-1' },
    });
    // Cancel the body to release the socket; we already have the status.
    void res.body?.cancel().catch(() => undefined);
    if (res.ok || res.status === 206) {
      return { state: 'healthy', status: res.status };
    }
    if (res.status === 401 || res.status === 403) {
      return { state: 'unauthorised', status: res.status };
    }
    return { state: 'failing', status: res.status, error: `HTTP ${res.status}` };
  } catch (err) {
    return {
      state: 'failing',
      status: -1,
      error: err instanceof Error ? err.message : String(err),
    };
  }
};
