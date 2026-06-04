/**
 * M22 / CR-MIG-DRIVE — /api/v1/integrations/* routes.
 *
 *   GET    /connectors                              integrations.catalog.read
 *   GET    /connections                             migration.connection.manage
 *   DELETE /connections/:id                         migration.connection.manage
 *   POST   /google-drive/auth-url                   migration.connection.manage
 *   GET    /google-drive/callback                   PUBLIC (state HMAC-verified)
 */
import { Router } from 'express';
import { migrationController } from '../../controllers/migration.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';

const router = Router();

// Google OAuth callback is hit by the browser redirect — cannot require JWT.
// The HMAC-signed `state` token re-establishes user identity. Registered
// FIRST so it bypasses the catch-all authenticate below.
router.get('/google-drive/callback', migrationController.handleGoogleCallback);

router.use(authenticate);
router.use(rlsMiddleware);

router.get(
  '/connectors',
  authorise(['integrations.catalog.read']),
  migrationController.listConnectorCatalog,
);

router.get(
  '/connections',
  authorise(['migration.connection.manage']),
  migrationController.listConnections,
);

router.delete(
  '/connections/:id',
  authorise(['migration.connection.manage']),
  migrationController.disconnectConnection,
);

router.post(
  '/google-drive/auth-url',
  authorise(['migration.connection.manage']),
  migrationController.buildGoogleAuthUrl,
);

export default router;
