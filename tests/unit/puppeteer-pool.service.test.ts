/**
 * Unit tests — Codex BE-M1b-008 negative regression for the Puppeteer pool.
 *
 * BE-M1b-008 (LOW gap): The round-1 BE-M1b-003 fix introduced a singleton
 * Browser + p-limit(N) semaphore. Existing tests in `contract-pdf.service.test.ts`
 * assert browser reuse (1 launch for N renders). This file additionally
 * asserts the SEMAPHORE CAP — i.e. at most `PUPPETEER_MAX_CONCURRENT`
 * `withPage` callbacks may be in-flight simultaneously.
 *
 * Strategy:
 *   - Mock `puppeteer.launch` so newPage resolves to a fake `Page`.
 *   - Each fake `withPage(fn)` call records a high-water mark of concurrent
 *     in-flight callbacks (active counter +1 / -1 via the fn).
 *   - Issue 10 concurrent `withPage` calls; each callback awaits
 *     `setTimeout(50ms)` before completing.
 *   - Assert max concurrency == PUPPETEER_MAX_CONCURRENT (default 2).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const newPageSpy = vi.fn(async () => ({
  setContent: vi.fn(async () => undefined),
  pdf: vi.fn(async () => Buffer.from('%PDF-1.4 fake')),
  close: vi.fn(async () => undefined),
}));
const closeSpy = vi.fn(async () => undefined);
const launchSpy = vi.fn(async () => ({
  newPage: newPageSpy,
  close: closeSpy,
  connected: true,
}));

vi.mock('puppeteer', () => ({
  default: { launch: launchSpy },
}));

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

describe('puppeteer-pool.service — BE-M1b-008 semaphore cap regression', () => {
  beforeEach(async () => {
    delete process.env.PUPPETEER_MAX_CONCURRENT;
    // p-limit semaphore is captured at module-evaluate via parseConcurrency().
    // To exercise the cap with different env values, we must bust the module
    // cache via vi.resetModules() before each test.
    vi.resetModules();
    // Reset the singleton browser before reading mock counters.
    const pool = await import('../../src/services/export/puppeteer-pool.service');
    await pool.__testReset();
    vi.clearAllMocks();
  });

  afterEach(() => {
    delete process.env.PUPPETEER_MAX_CONCURRENT;
  });

  it('default cap (2): never more than 2 simultaneous in-flight withPage callbacks across 10 concurrent calls', async () => {
    const pool = await import('../../src/services/export/puppeteer-pool.service');

    let active = 0;
    let maxObserved = 0;
    const N = 10;

    const tasks = Array.from({ length: N }, () =>
      pool.withPage(async () => {
        active += 1;
        if (active > maxObserved) maxObserved = active;
        await sleep(50);
        active -= 1;
        return null;
      }),
    );

    const results = await Promise.all(tasks);
    expect(results).toHaveLength(N);
    expect(maxObserved).toBeLessThanOrEqual(2);
    // Lower bound — with 10 concurrent calls and a 50ms sleep, p-limit(2)
    // MUST ramp to exactly 2 in-flight at peak. If maxObserved is 1, the
    // semaphore is over-restricting (regression in the other direction).
    expect(maxObserved).toBe(2);

    // Browser was launched exactly once (BE-M1b-003 reuse assertion repeated
    // here so a regression that breaks both surfaces clearly).
    expect(launchSpy).toHaveBeenCalledTimes(1);
    // One newPage per task, each closed.
    expect(newPageSpy).toHaveBeenCalledTimes(N);
  });

  it('PUPPETEER_MAX_CONCURRENT=4 caps in-flight callbacks at 4, even with 10 concurrent calls', async () => {
    process.env.PUPPETEER_MAX_CONCURRENT = '4';
    // Re-import so parseConcurrency() reads the new env value at module init.
    vi.resetModules();
    const pool = await import('../../src/services/export/puppeteer-pool.service');

    let active = 0;
    let maxObserved = 0;
    const N = 10;

    const tasks = Array.from({ length: N }, () =>
      pool.withPage(async () => {
        active += 1;
        if (active > maxObserved) maxObserved = active;
        await sleep(50);
        active -= 1;
        return null;
      }),
    );

    await Promise.all(tasks);
    expect(maxObserved).toBeLessThanOrEqual(4);
    expect(maxObserved).toBe(4);
  });

  it('hard upper bound 16: PUPPETEER_MAX_CONCURRENT=99 clamps to 16', async () => {
    process.env.PUPPETEER_MAX_CONCURRENT = '99';
    vi.resetModules();
    const pool = await import('../../src/services/export/puppeteer-pool.service');

    let active = 0;
    let maxObserved = 0;
    const N = 32;

    const tasks = Array.from({ length: N }, () =>
      pool.withPage(async () => {
        active += 1;
        if (active > maxObserved) maxObserved = active;
        await sleep(50);
        active -= 1;
        return null;
      }),
    );

    await Promise.all(tasks);
    // The pool clamps to 16 to protect against config foot-guns
    // (puppeteer-pool.service.ts parseConcurrency() — Math.min(n, 16)).
    expect(maxObserved).toBeLessThanOrEqual(16);
  });
});
