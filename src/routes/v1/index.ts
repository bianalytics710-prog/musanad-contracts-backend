/**
 * Mount all /api/v1 routers.
 */
import { Router } from 'express';
import authRouter from './auth.routes';
import userRouter from './user.routes';
import roleRouter from './role.routes';
import permissionRouter from './permission.routes';

const v1Router = Router();

v1Router.use('/auth', authRouter);
v1Router.use('/users', userRouter);
v1Router.use('/roles', roleRouter);
v1Router.use('/permissions', permissionRouter);

export default v1Router;
