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

export default v1Router;
