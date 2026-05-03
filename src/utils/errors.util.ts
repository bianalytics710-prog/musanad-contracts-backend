/**
 * ApiError class hierarchy. All HTTP-surface errors raised by controllers
 * and middleware extend ApiError. The error middleware (error.middleware.ts)
 * maps these to consistent JSON responses; raw PG errors are NEVER passed
 * through.
 */

export interface ApiErrorFields {
  /** field-level validation errors keyed by field name */
  [field: string]: string | string[] | undefined;
}

export class ApiError extends Error {
  public readonly statusCode: number;
  public readonly code: string;
  public readonly fields?: ApiErrorFields;

  constructor(statusCode: number, code: string, message: string, fields?: ApiErrorFields) {
    super(message);
    this.name = 'ApiError';
    this.statusCode = statusCode;
    this.code = code;
    if (fields !== undefined) {
      this.fields = fields;
    }
    // Restore prototype chain (TS class extending Error gotcha)
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

export class ValidationError extends ApiError {
  constructor(message = 'Validation error', fields?: ApiErrorFields) {
    super(400, 'VALIDATION_ERROR', message, fields);
    this.name = 'ValidationError';
  }
}

export class UnauthorizedError extends ApiError {
  constructor(message = 'Unauthorized') {
    // errorCode 'UNAUTHORIZED' is the canonical value per api-contracts.json
    // globalConventions.authentication.validation. Keeping 'UNAUTHORIZED' for
    // missing/invalid bearer aligns BE with the contract used by FE + tests.
    super(401, 'UNAUTHORIZED', message);
    this.name = 'UnauthorizedError';
  }
}

export class InvalidCredentialsError extends ApiError {
  constructor(message = 'Invalid credentials') {
    super(401, 'INVALID_CREDENTIALS', message);
    this.name = 'InvalidCredentialsError';
  }
}

export class ForbiddenError extends ApiError {
  constructor(message = 'Forbidden') {
    super(403, 'FORBIDDEN', message);
    this.name = 'ForbiddenError';
  }
}

export class NotFoundError extends ApiError {
  constructor(message = 'Resource not found', fields?: ApiErrorFields) {
    super(404, 'NOT_FOUND', message, fields);
    this.name = 'NotFoundError';
  }
}

export class ConflictError extends ApiError {
  constructor(message = 'Conflict', fields?: ApiErrorFields) {
    super(409, 'CONFLICT', message, fields);
    this.name = 'ConflictError';
  }
}

export class UnprocessableEntityError extends ApiError {
  constructor(message = 'Unprocessable entity', fields?: ApiErrorFields) {
    super(422, 'UNPROCESSABLE', message, fields);
    this.name = 'UnprocessableEntityError';
  }
}

export class LockedError extends ApiError {
  constructor(message = 'Account locked') {
    super(423, 'ACCOUNT_LOCKED', message);
    this.name = 'LockedError';
  }
}

export class RateLimitError extends ApiError {
  constructor(message = 'Rate limit exceeded') {
    super(429, 'RATE_LIMITED', message);
    this.name = 'RateLimitError';
  }
}

export class InternalError extends ApiError {
  constructor(message = 'Internal server error') {
    super(500, 'INTERNAL_ERROR', message);
    this.name = 'InternalError';
  }
}

export class NotImplementedError extends ApiError {
  constructor(message = 'Not implemented') {
    super(501, 'NOT_IMPLEMENTED', message);
    this.name = 'NotImplementedError';
  }
}

export class ServiceUnavailableError extends ApiError {
  constructor(message = 'Service unavailable') {
    super(503, 'SERVICE_UNAVAILABLE', message);
    this.name = 'ServiceUnavailableError';
  }
}
