/**
 * M2 — S9 cron driver unit tests.
 *
 * Validates approval-escalation.cron.service.ts behaviour without spinning up
 * a real database or a real cron schedule.
 *
 * Strategy: vi.mock the database/config + approval.service modules so the
 * driver runs against an in-memory candidate list. We assert:
 *   - runEscalationSweep() calls approvalService.escalate exactly once per
 *     candidate row.
 *   - non-fatal errors from one candidate do not stop processing of the next.
 *   - empty candidate set is a no-op.
 *   - startApprovalEscalationCron() short-circuits when NODE_ENV=test
 *     (returns null without calling cron.schedule).
 *   - startApprovalEscalationCron() rejects an invalid cron expression.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Hoist a shared poolMock so the in-place vi.mock factory can return it.
const poolMock = vi.hoisted(() => ({
  query: vi.fn(),
}));
const escalateMock = vi.hoisted(() => vi.fn());
const cronScheduleMock = vi.hoisted(() => vi.fn());
const cronValidateMock = vi.hoisted(() => vi.fn());

vi.mock('../../src/database/config', () => ({
  pool: () => poolMock,
  closePool: vi.fn(),
}));

vi.mock('../../src/services/approval.service', () => ({
  escalate: escalateMock,
}));

vi.mock('node-cron', () => ({
  default: {
    schedule: cronScheduleMock,
    validate: cronValidateMock,
  },
  schedule: cronScheduleMock,
  validate: cronValidateMock,
}));

// Lower log noise.
vi.mock('../../src/utils/logger.util', () => ({
  logger: {
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  },
}));

const ORIGINAL_NODE_ENV = process.env.NODE_ENV;

beforeEach(() => {
  poolMock.query.mockReset();
  escalateMock.mockReset();
  cronScheduleMock.mockReset();
  cronValidateMock.mockReset();
  cronValidateMock.mockReturnValue(true);
});

afterEach(() => {
  process.env.NODE_ENV = ORIGINAL_NODE_ENV;
  vi.resetModules();
});

describe('runEscalationSweep', () => {
  it('returns [] when no candidates match', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const processed = await mod.runEscalationSweep();
    expect(processed).toEqual([]);
    expect(escalateMock).not.toHaveBeenCalled();
  });

  it('calls approvalService.escalate once per candidate and returns processed ids', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [
        {
          id: 11,
          approval_chain_id: 100,
          step_order: 1,
          escalation_role: 'legal_counsel',
          escalation_after_hours: 24,
        },
        {
          id: 12,
          approval_chain_id: 100,
          step_order: 2,
          escalation_role: 'legal_counsel',
          escalation_after_hours: 12,
        },
      ],
    });
    escalateMock
      .mockResolvedValueOnce({ newPeerStepId: 21, decisionId: 31, acted: true })
      .mockResolvedValueOnce({ newPeerStepId: 22, decisionId: 32, acted: true });
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const processed = await mod.runEscalationSweep();
    expect(processed).toEqual([11, 12]);
    expect(escalateMock).toHaveBeenCalledTimes(2);
  });

  it('continues processing when one candidate fails (non-fatal error)', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [
        {
          id: 11,
          approval_chain_id: 100,
          step_order: 1,
          escalation_role: 'legal_counsel',
          escalation_after_hours: 24,
        },
        {
          id: 12,
          approval_chain_id: 100,
          step_order: 2,
          escalation_role: 'legal_counsel',
          escalation_after_hours: 12,
        },
      ],
    });
    escalateMock
      .mockRejectedValueOnce(new Error('escalation_after_hours has not yet elapsed'))
      .mockResolvedValueOnce({ newPeerStepId: 22, decisionId: 32, acted: true });
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const processed = await mod.runEscalationSweep();
    // First failed → not in processed list. Second succeeded.
    expect(processed).toEqual([12]);
    expect(escalateMock).toHaveBeenCalledTimes(2);
  });

  it('returns [] and does not throw when scan query fails', async () => {
    poolMock.query.mockRejectedValueOnce(new Error('connection refused'));
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const processed = await mod.runEscalationSweep();
    expect(processed).toEqual([]);
    expect(escalateMock).not.toHaveBeenCalled();
  });
});

describe('startApprovalEscalationCron', () => {
  it('returns null and does NOT register a job when NODE_ENV=test', async () => {
    process.env.NODE_ENV = 'test';
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const result = mod.startApprovalEscalationCron();
    expect(result).toBeNull();
    expect(cronScheduleMock).not.toHaveBeenCalled();
  });

  it('returns null when APPROVAL_ESCALATION_INTERVAL_CRON is invalid', async () => {
    process.env.NODE_ENV = 'production';
    process.env.APPROVAL_ESCALATION_INTERVAL_CRON = 'not a cron expression';
    cronValidateMock.mockReturnValue(false);
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const result = mod.startApprovalEscalationCron();
    expect(result).toBeNull();
    expect(cronScheduleMock).not.toHaveBeenCalled();
    delete process.env.APPROVAL_ESCALATION_INTERVAL_CRON;
  });

  it('schedules with default expression when env not set', async () => {
    process.env.NODE_ENV = 'production';
    delete process.env.APPROVAL_ESCALATION_INTERVAL_CRON;
    const fakeTask = { stop: vi.fn() };
    cronScheduleMock.mockReturnValueOnce(fakeTask);
    cronValidateMock.mockReturnValue(true);
    const mod = await import('../../src/services/approval-escalation.cron.service');
    const result = mod.startApprovalEscalationCron();
    expect(result).toBe(fakeTask);
    expect(cronScheduleMock).toHaveBeenCalledTimes(1);
    expect(cronScheduleMock.mock.calls[0]![0]).toBe('*/15 * * * *');
    // Cleanup
    mod.stopApprovalEscalationCron();
    expect(fakeTask.stop).toHaveBeenCalledTimes(1);
  });
});
