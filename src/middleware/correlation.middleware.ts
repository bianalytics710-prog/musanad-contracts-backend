/**
 * Correlation middleware. Attaches a UUID to every request, sets the
 * X-Request-ID response header, and creates a child Pino logger with the
 * requestId bound. Every downstream log line in this request's lifecycle
 * inherits the requestId automatically.
 */
import type { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { logger } from '../utils/logger.util';

export const correlationMiddleware = (
  req: Request,
  res: Response,
  next: NextFunction,
): void => {
  // Honour an inbound X-Request-ID if the caller supplied one (e.g. nginx,
  // or a frontend that wants traceability). Otherwise generate.
  const headerName = (process.env.REQUEST_ID_HEADER ?? 'X-Request-ID').toLowerCase();
  const inbound = req.headers[headerName];
  const requestId =
    typeof inbound === 'string' && inbound.length > 0 && inbound.length <= 128
      ? inbound
      : uuidv4();

  req.requestId = requestId;
  req.logger = logger.child({ requestId });

  res.setHeader(process.env.REQUEST_ID_HEADER ?? 'X-Request-ID', requestId);

  next();
};
