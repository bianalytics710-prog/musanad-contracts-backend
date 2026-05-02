/**
 * Global error middleware. Translates ApiError into JSON; everything else
 * becomes a generic 500 with the error logged but not exposed.
 *
 * Response shape (matches types/api.types.ts ErrorResponse):
 *   { success: false, error: { code, message, details? }, requestId }
 */
import type { ErrorRequestHandler, NextFunction, Request, Response } from 'express';
import { ZodError } from 'zod';
import { ApiError, ValidationError } from '../utils/errors.util';

const formatZodError = (err: ZodError): ValidationError => {
  const fields: Record<string, string> = {};
  for (const issue of err.issues) {
    const path = issue.path.length > 0 ? issue.path.join('.') : '_root';
    if (!(path in fields)) {
      fields[path] = issue.message;
    }
  }
  return new ValidationError('Request validation failed', fields);
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const errorMiddleware: ErrorRequestHandler = (
  err: unknown,
  req: Request,
  res: Response,
  _next: NextFunction,
): void => {
  // Already-typed Zod error from validate.middleware (we wrap there too,
  // but be defensive in case a controller calls schema.parse() directly).
  let apiErr: ApiError;
  if (err instanceof ZodError) {
    apiErr = formatZodError(err);
  } else if (err instanceof ApiError) {
    apiErr = err;
  } else {
    // Unknown — log full detail, return generic
    req.logger?.error(
      {
        action: 'error.unhandled',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        message: err instanceof Error ? err.message : String(err),
        stack: err instanceof Error ? err.stack : undefined,
      },
      'Unhandled error reached error middleware',
    );
    res.status(500).json({
      success: false,
      error: {
        code: 'INTERNAL_ERROR',
        message: 'An unexpected error occurred',
      },
      requestId: req.requestId,
    });
    return;
  }

  // Log ApiError at warn level (4xx) or error level (5xx)
  const isServerError = apiErr.statusCode >= 500;
  const logLevel = isServerError ? 'error' : 'warn';
  req.logger?.[logLevel](
    {
      action: 'error.api',
      statusCode: apiErr.statusCode,
      errorCode: apiErr.code,
    },
    apiErr.message,
  );

  res.status(apiErr.statusCode).json({
    success: false,
    error: {
      code: apiErr.code,
      message: apiErr.message,
      ...(apiErr.fields ? { details: apiErr.fields } : {}),
    },
    requestId: req.requestId,
  });
};
