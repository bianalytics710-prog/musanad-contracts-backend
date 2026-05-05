/**
 * Mount all /api/v1 routers.
 */
import { Router } from 'express';
import authRouter from './auth.routes';
import userRouter from './user.routes';
import roleRouter from './role.routes';
import permissionRouter from './permission.routes';
import contractsRouter from './contracts.routes';
import importBatchesRouter from './import-batches.routes';
import aiRouter from './ai.routes';
import approvalsRouter from './approvals.routes';
import adminRouter from './admin';
import signRouter from './sign.routes';
import signaturePartiesRouter from './signature-parties.routes';
import signatureInvitationsRouter from './signature-invitations.routes';
import {
  regulationsRouter,
  regulatoryUpdatesRouter,
  regulatoryImpactsRouter,
  impactCategoriesRouter,
} from './regulatory.routes';
import dashboardsRouter from './dashboards.routes';

const v1Router = Router();

v1Router.use('/auth', authRouter);
v1Router.use('/users', userRouter);
v1Router.use('/roles', roleRouter);
v1Router.use('/permissions', permissionRouter);
v1Router.use('/contracts', contractsRouter);

// M1c — Bulk & Manual Import
v1Router.use('/import-batches', importBatchesRouter);
// M1c — NEW /api/v1/ai/* namespace (Q3-OI-E / collision-report MD-4).
// M4 will append additional AI endpoints to ai.routes.ts.
v1Router.use('/ai', aiRouter);

// M2 — Approval Workflows (Q3-OI-E)
v1Router.use('/approvals', approvalsRouter);
v1Router.use('/admin', adminRouter);

// M3 — Signatures + Signer Q&A AI
//   /sign is the verify_jwt=false token-bearer namespace (S3, S4, S5,
//   S11, S12). The other two M3 namespaces are JWT-authenticated (S7, S8).
v1Router.use('/sign', signRouter);
v1Router.use('/signature-parties', signaturePartiesRouter);
v1Router.use('/signature-invitations', signatureInvitationsRouter);

// M5 — Regulatory Radar (15 endpoints across four resources). All
// JWT-authenticated; zero new PUBLIC fn_'s (Q1 confirmed). See
// src/routes/v1/regulatory.routes.ts header for permission code mapping.
v1Router.use('/regulations', regulationsRouter);
v1Router.use('/regulatory-updates', regulatoryUpdatesRouter);
v1Router.use('/regulatory-impacts', regulatoryImpactsRouter);
v1Router.use('/impact-categories', impactCategoriesRouter);

// M6 — Dashboards & Reporting (9 endpoints under /dashboards/*; the 10th
// — admin observability health probe — is mounted under /admin/health
// from admin/index.ts). All JWT-authenticated; zero new PUBLIC fn_'s
// (Q1 confirmed); zero new auth modes. See
// src/routes/v1/dashboards.routes.ts header for the per-endpoint
// permission / role-gate strategy.
v1Router.use('/dashboards', dashboardsRouter);

export default v1Router;
