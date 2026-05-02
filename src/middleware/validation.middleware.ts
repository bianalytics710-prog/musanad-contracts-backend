/**
 * Zod validation middleware. Returns a per-source middleware that:
 *   - parses req[source] against the schema
 *   - on success: replaces req[source] with the parsed (typed, coerced) value
 *   - on failure: forwards a ValidationError with field-level details
 *
 * Usage:
 *   router.post('/', validate(createUserSchema, 'body'), userController.create);
 *   router.get('/:id', validate(userIdParamSchema, 'params'), userController.getById);
 */
import type { NextFunction, Request, Response } from 'express';
import { ZodError, type ZodSchema } from 'zod';
import { ValidationError } from '../utils/errors.util';

type ValidationSource = 'body' | 'query' | 'params';

export const validate =
  <T>(schema: ZodSchema<T>, source: ValidationSource = 'body') =>
  (req: Request, _res: Response, next: NextFunction): void => {
    try {
      const result = schema.parse(req[source]);
      // Replace the parsed source on the request. Using assignment is safe
      // because we never trust the original shape past this point.
      // (Express `req.query` is technically a getter on some Node versions —
      // Object.defineProperty avoids the read-only trap.)
      Object.defineProperty(req, source, { value: result, writable: true });
      next();
    } catch (err) {
      if (err instanceof ZodError) {
        const fields: Record<string, string> = {};
        for (const issue of err.issues) {
          const path = issue.path.length > 0 ? issue.path.join('.') : '_root';
          if (!(path in fields)) fields[path] = issue.message;
        }
        next(new ValidationError('Request validation failed', fields));
        return;
      }
      next(err);
    }
  };
