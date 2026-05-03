import { defineConfig } from 'vitest/config';
import path from 'node:path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    setupFiles: ['./tests/helpers/setup.ts'],
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'html'],
      include: ['src/**/*.ts'],
      exclude: [
        'src/**/*.d.ts',
        'src/types/**',
        'src/server.ts',
        'src/utils/telemetry.util.ts',
        // M0 / foundation boilerplate that the M1a feature suite is not
        // responsible for covering. Each is exercised by its own suite or is
        // a CLI entry point with no unit-test surface.
        'src/database/migrate.ts',
        'src/integrations/ai/**',
        'src/integrations/mail/**',
        'src/integrations/uae-pass/factory.ts',
        'src/integrations/uae-pass/live.provider.ts',
        'src/integrations/uae-pass/mock.provider.ts',
        'src/integrations/uae-pass/index.ts',
        'src/middleware/rls.middleware.ts',
      ],
      thresholds: {
        lines: 60,
        functions: 60,
        branches: 50,
        statements: 60,
      },
    },
    testTimeout: 30000,
    hookTimeout: 30000,
    pool: 'forks',
    poolOptions: {
      forks: { singleFork: true },
    },
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});
