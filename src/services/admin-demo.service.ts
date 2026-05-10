/**
 * CR-C — Demo data purge + classification summary service (S6, S7).
 *
 * Thin db.callFunction passthroughs. The Super Admin role check + permission
 * gate live inside fn_demo_data_purge body (compound — both required).
 */
import { db } from '../database/client';
import type {
  DemoPurgeResult,
  DataClassificationSummary,
} from '../types/admin-demo.types';

export const purgeDemoData = (
  actorId: number,
  dryRun: boolean,
): Promise<DemoPurgeResult> =>
  db.callFunction<DemoPurgeResult>(
    'fn_demo_data_purge',
    [dryRun],
    { actorId },
  );

export const getDataClassificationSummary = (
  actorId: number,
): Promise<DataClassificationSummary> =>
  db.callFunction<DataClassificationSummary>(
    'fn_data_classification_summary',
    [],
    { actorId },
  );
