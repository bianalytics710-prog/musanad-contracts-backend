/**
 * internal-system-probe.service.ts
 *
 * Lightweight HTTP probe for the test-connection endpoint on
 * /admin/internal-systems. v1 is intentionally simple: HEAD the URL with a
 * short timeout and translate the HTTP status into one of:
 *   - healthy       (HTTP 2xx)
 *   - unauthorised  (HTTP 401 / 403)
 *   - degraded      (HTTP 5xx that returns within timeout)
 *   - failing       (network error / DNS / timeout / non-HTTP scheme)
 *
 * No credentials are sent (we don't have them in Postgres — they live in
 * vault references). A real "authenticated probe" is a future enhancement.
 *
 * For demo purposes we also accept URLs that don't resolve (e.g.
 * adnoc.service-now.com may not exist outside the corp network) and report
 * `failing` with a clean error message, so the admin sees realistic state
 * without crashing.
 */
import { logger } from '../utils/logger.util';

const TIMEOUT_MS = 5_000;

export type ProbeStatus = 'healthy' | 'degraded' | 'failing' | 'unauthorised';

export interface ProbeInput {
  baseUrl: string | null;
  apiEndpoint: string | null;
}

export interface ProbeResult {
  status: ProbeStatus;
  httpStatus: number | null;
  durationMs: number;
  error: string | null;
}

const isHttpUrl = (u: string): boolean => /^https?:\/\//i.test(u);

export async function probeInternalSystem(input: ProbeInput): Promise<ProbeResult> {
  const start = Date.now();
  const url = input.apiEndpoint || input.baseUrl;

  if (!url || !isHttpUrl(url)) {
    return {
      status: 'failing',
      httpStatus: null,
      durationMs: 0,
      error: 'No HTTP(S) URL configured.',
    };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    // HEAD avoids downloading bodies + plays nicer with vendor systems.
    const resp = await fetch(url, {
      method: 'HEAD',
      signal: controller.signal,
      // Don't follow auth redirects to login pages — those would mask 401s.
      redirect: 'manual',
    });
    const durationMs = Date.now() - start;

    if (resp.status >= 200 && resp.status < 300) {
      return { status: 'healthy', httpStatus: resp.status, durationMs, error: null };
    }
    if (resp.status === 401 || resp.status === 403) {
      return {
        status: 'unauthorised',
        httpStatus: resp.status,
        durationMs,
        error: `HTTP ${resp.status} ${resp.statusText || ''}`.trim(),
      };
    }
    if (resp.status >= 500) {
      return {
        status: 'degraded',
        httpStatus: resp.status,
        durationMs,
        error: `HTTP ${resp.status} ${resp.statusText || ''}`.trim(),
      };
    }
    // 3xx / 4xx — treat as degraded so admin sees something actionable.
    return {
      status: 'degraded',
      httpStatus: resp.status,
      durationMs,
      error: `HTTP ${resp.status} ${resp.statusText || ''}`.trim(),
    };
  } catch (err) {
    const durationMs = Date.now() - start;
    const msg = err instanceof Error ? err.message : String(err);
    logger.info(
      { action: 'internalSystem.probe', url, errorMessage: msg },
      'Probe failed',
    );
    return {
      status: 'failing',
      httpStatus: null,
      durationMs,
      error: msg.slice(0, 240),
    };
  } finally {
    clearTimeout(timer);
  }
}
