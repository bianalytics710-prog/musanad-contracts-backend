/**
 * CR-C — Branding upload Zod schemas (S11).
 *
 * The actual file blob is parsed by multer (memoryStorage). The schema here
 * validates the `kind` form field. File-type / size validation is performed
 * in the controller (multer's fileFilter cannot easily emit 400 envelopes).
 */
import { z } from 'zod';
import { BRANDING_ASSET_KINDS } from '../types/admin-branding.types';

export const brandingUploadFormSchema = z
  .object({
    kind: z.enum(BRANDING_ASSET_KINDS as unknown as [string, ...string[]]),
  })
  // multer attaches the file via req.file — schema only covers req.body fields.
  .passthrough();

export const brandingPatchBodySchema = z
  .object({
    colorPrimary: z
      .string()
      .regex(/^#[0-9A-Fa-f]{6}$/, 'must be a valid hex color')
      .optional(),
    colorAccent: z
      .string()
      .regex(/^#[0-9A-Fa-f]{6}$/, 'must be a valid hex color')
      .optional(),
    footerEn: z.string().max(500).optional(),
    footerAr: z.string().max(500).optional(),
    logoUri: z.string().max(1000).optional(),
    faviconUri: z.string().max(1000).optional(),
  })
  .strict()
  .refine(
    (val) => Object.keys(val).length > 0,
    'At least one field must be provided for update',
  );

export type BrandingUploadFormInferred = z.infer<typeof brandingUploadFormSchema>;
export type BrandingPatchBodyInferred = z.infer<typeof brandingPatchBodySchema>;
