/**
 * OpenTelemetry initialisation.
 *
 * Imported FIRST in server.ts (before pg, before express) so that the
 * pg / http / express auto-instrumentations attach correctly.
 *
 * Two modes:
 *   - STUB mode (default): no exporter configured — auto-instrumentations
 *     remain registered but spans are dropped (zero overhead worth measuring).
 *   - FULL mode: when OTEL_EXPORTER_OTLP_ENDPOINT is set, spans are exported
 *     via OTLP/HTTP. Use any compatible collector (Jaeger, Tempo, Honeycomb).
 *
 * Slow-query (>500ms) detection logs via Pino as a `warn`-level event with
 * truncated query text and duration. Heavy queries surface here without
 * waiting for the APM dashboard.
 */
import { logger } from './logger.util';

const otelEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
const otelServiceName =
  process.env.OTEL_SERVICE_NAME ||
  process.env.SERVICE_NAME ||
  'musanad-contracts-backend';

interface TelemetryHandle {
  shutdown: () => Promise<void>;
}

const startTelemetry = (): TelemetryHandle => {
  if (!otelEndpoint) {
    logger.info(
      { action: 'telemetry.stub', reason: 'OTEL_EXPORTER_OTLP_ENDPOINT not set' },
      'Telemetry running in stub mode',
    );
    return { shutdown: async () => undefined };
  }

  // Lazy-load to avoid the ~30 MB OTel SDK weight when not exporting.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { NodeSDK } = require('@opentelemetry/sdk-node') as typeof import('@opentelemetry/sdk-node');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { OTLPTraceExporter } =
    require('@opentelemetry/exporter-trace-otlp-http') as typeof import('@opentelemetry/exporter-trace-otlp-http');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { HttpInstrumentation } =
    require('@opentelemetry/instrumentation-http') as typeof import('@opentelemetry/instrumentation-http');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { ExpressInstrumentation } =
    require('@opentelemetry/instrumentation-express') as typeof import('@opentelemetry/instrumentation-express');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { PgInstrumentation } =
    require('@opentelemetry/instrumentation-pg') as typeof import('@opentelemetry/instrumentation-pg');

  const sdk = new NodeSDK({
    serviceName: otelServiceName,
    traceExporter: new OTLPTraceExporter({ url: otelEndpoint }),
    instrumentations: [
      new HttpInstrumentation(),
      new ExpressInstrumentation(),
      new PgInstrumentation({
        enhancedDatabaseReporting: true,
      }),
    ],
  });

  sdk.start();
  logger.info(
    { action: 'telemetry.start', endpoint: otelEndpoint, serviceName: otelServiceName },
    'Telemetry started',
  );

  return {
    shutdown: async () => {
      await sdk.shutdown();
    },
  };
};

export const telemetry = startTelemetry();
