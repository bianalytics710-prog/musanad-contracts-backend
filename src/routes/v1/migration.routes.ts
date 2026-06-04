/**
 * M22 / CR-MIG-DRIVE — /api/v1/migration/* routes.
 *
 *   POST   /batches                                 migration.batch.trigger
 *   GET    /batches                                 migration.batch.read.all
 *   GET    /batches/:id                             migration.batch.read.all
 *   GET    /batches/:id/records                     migration.batch.read.all
 *   GET    /batches/:id/progress                    migration.batch.read.all
 *   POST   /batches/:id/rollback                    migration.batch.rollback
 *   GET    /batches/:id/coverage-report             migration.batch.read.all
 */
import { Router } from 'express';
import { migrationController } from '../../controllers/migration.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);

router.post(
  '/batches',
  authorise(['migration.batch.trigger']),
  migrationController.createBatch,
);

router.get(
  '/batches',
  authorise(['migration.batch.read.all']),
  migrationController.listBatches,
);

router.get(
  '/batches/:id/records',
  authorise(['migration.batch.read.all']),
  migrationController.listBatchRecords,
);

router.get(
  '/batches/:id/progress',
  authorise(['migration.batch.read.all']),
  migrationController.getBatchProgress,
);

router.get(
  '/batches/:id/coverage-report',
  authorise(['migration.batch.read.all']),
  migrationController.getCoverageReport,
);

router.post(
  '/batches/:id/rollback',
  authorise(['migration.batch.rollback']),
  migrationController.rollbackBatch,
);

router.get(
  '/batches/:id',
  authorise(['migration.batch.read.all']),
  migrationController.getBatch,
);

export default router;
