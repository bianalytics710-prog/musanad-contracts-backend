/**
 * TPA — Third-Party Agreement Assessment routes.
 *
 * Mounted under /api/v1/tpa from routes/v1/index.ts.
 *
 *   GET    /playbooks                         tpa.review.read
 *   GET    /playbooks/:id                     tpa.review.read
 *   POST   /reviews/upload                    tpa.review.create   (multipart)
 *   GET    /reviews                           tpa.review.read
 *   GET    /reviews/:id                       tpa.review.read
 *   PATCH  /reviews/:id/findings/:findingId   tpa.review.amend
 *   POST   /reviews/:id/status                tpa.review.amend
 *   GET    /reviews/:id/redline.docx          tpa.review.amend
 */
import { Router } from 'express';
import multer from 'multer';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { tpaController } from '../../controllers/tpa.controller';

const router = Router();

const READ = ['tpa.review.read'] as const;
const CREATE = ['tpa.review.create'] as const;
const AMEND = ['tpa.review.amend'] as const;

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }, // 10 MB — NDAs are short
});

// Playbooks
router.get('/playbooks', authenticate, rlsMiddleware, authorise(READ), tpaController.listPlaybooks);
router.get('/playbooks/:id', authenticate, rlsMiddleware, authorise(READ), tpaController.getPlaybook);

// Reviews
router.post(
  '/reviews/upload',
  authenticate,
  rlsMiddleware,
  authorise(CREATE),
  upload.single('file'),
  tpaController.uploadAndAnalyse,
);
router.get('/reviews', authenticate, rlsMiddleware, authorise(READ), tpaController.listReviews);
router.get('/reviews/:id', authenticate, rlsMiddleware, authorise(READ), tpaController.getReview);
router.patch(
  '/reviews/:id/findings/:findingId',
  authenticate,
  rlsMiddleware,
  authorise(AMEND),
  tpaController.updateFinding,
);
router.post(
  '/reviews/:id/status',
  authenticate,
  rlsMiddleware,
  authorise(AMEND),
  tpaController.setStatus,
);
router.get(
  '/reviews/:id/redline.docx',
  authenticate,
  rlsMiddleware,
  authorise(AMEND),
  tpaController.downloadRedline,
);

export default router;
