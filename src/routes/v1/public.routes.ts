/**
 * Public (pre-auth) routes. These endpoints are reachable without a valid
 * session — the login page itself calls them before the user has signed in.
 *
 *   GET /api/v1/public/dev-login-personas — fn_dev_login_personas_get
 */
import { Router } from 'express';
import { devLoginPersonasController } from '../../controllers/dev-login-personas.controller';

const router = Router();

router.get('/dev-login-personas', devLoginPersonasController.get);

export default router;
