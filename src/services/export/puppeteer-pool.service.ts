/**
 * Puppeteer browser pool — Codex BE-M1b-003 fix.
 *
 * The original `renderContractPdf` launched a fresh Chromium process per
 * request. Ten concurrent requests = ten Chromium instances = OOM in any
 * realistic container budget. Codex flagged this as a DoS surface that the
 * 30/min/user export rate limiter does not cover (multiple users, or
 * per-user limit lifted in stress tests).
 *
 * Design:
 *   - Singleton `Browser` instance, lazily created on first use via
 *     `getBrowser()`. Subsequent renders share the browser; per-request
 *     work is `newPage()` → `setContent` → `pdf()` → `page.close()`.
 *   - Concurrency cap via p-limit(N). Default 2; override with
 *     `PUPPETEER_MAX_CONCURRENT`. Excess requests await their slot.
 *   - Browser closed exactly once on SIGTERM/SIGINT/uncaughtException via
 *     `closeBrowser()` (wired into server.ts's existing shutdown handler).
 *   - Crash recovery: if the underlying Browser process disconnects (e.g.
 *     OOM-killed, crashed), the next `getBrowser()` call detects via
 *     `browser.connected` and re-launches.
 *
 * Why singleton + p-limit (not a full pool of N browsers): one Chromium
 * process can serve many tabs; gating concurrency at the page level keeps
 * memory bounded without paying N × launch cost.
 */
import puppeteer, { type Browser, type LaunchOptions, type Page } from 'puppeteer';
import pLimit from 'p-limit';
import { logger } from '../../utils/logger.util';

let _browser: Browser | null = null;
let _launching: Promise<Browser> | null = null;

const parseConcurrency = (): number => {
  const raw = process.env.PUPPETEER_MAX_CONCURRENT;
  if (raw === undefined || raw === '') return 2;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 1) return 2;
  // Hard upper bound — protects against config foot-guns.
  return Math.min(n, 16);
};

const _limit = pLimit(parseConcurrency());

/**
 * Build the Puppeteer launch options. PUPPETEER_EXECUTABLE_PATH overrides
 * the bundled Chromium when set (alpine / restricted-network builds).
 *
 * Exported so contract-pdf.service can verify the option set if needed and
 * so unit tests can spy on it.
 */
export const launchOptions = (): LaunchOptions => {
  const opts: LaunchOptions = {
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  };
  const exec = process.env.PUPPETEER_EXECUTABLE_PATH;
  if (exec && exec.length > 0) {
    opts.executablePath = exec;
  }
  return opts;
};

/**
 * Get the shared Browser instance, launching it on first call. Concurrent
 * callers during the launch race share a single in-flight launch promise.
 */
export const getBrowser = async (): Promise<Browser> => {
  // Disconnected (crashed) browsers are discarded so the next caller can
  // re-launch. `connected` was added in puppeteer 22.
  if (_browser && (_browser as { connected?: boolean }).connected === false) {
    _browser = null;
  }
  if (_browser !== null) return _browser;
  if (_launching !== null) return _launching;
  _launching = (async (): Promise<Browser> => {
    try {
      const b = await puppeteer.launch(launchOptions());
      _browser = b;
      return b;
    } finally {
      _launching = null;
    }
  })();
  return _launching;
};

/**
 * Acquire the semaphore, run `fn(page)`, close the page, return the result.
 * The shared browser is reused across calls. Concurrency is bounded by
 * PUPPETEER_MAX_CONCURRENT.
 */
export const withPage = async <T>(fn: (page: Page) => Promise<T>): Promise<T> => {
  return _limit(async () => {
    const browser = await getBrowser();
    const page = await browser.newPage();
    try {
      return await fn(page);
    } finally {
      try {
        await page.close();
      } catch {
        /* swallow — browser will reclaim on close anyway */
      }
    }
  });
};

/**
 * Close the shared browser. Called from the SIGTERM/SIGINT handler in
 * server.ts. Idempotent — repeated calls are no-ops.
 */
export const closeBrowser = async (): Promise<void> => {
  const b = _browser;
  _browser = null;
  if (!b) return;
  try {
    await b.close();
  } catch (err) {
    logger.warn(
      {
        action: 'puppeteer.closeBrowser',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'browser.close() threw during shutdown',
    );
  }
};

/** Test helpers — not used by production code. */
export const __testReset = async (): Promise<void> => {
  await closeBrowser();
};
