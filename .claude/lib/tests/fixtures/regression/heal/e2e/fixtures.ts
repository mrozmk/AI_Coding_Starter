// Fixture fixtures module: guard-integrated (the production pre-flight reads the import below).
import { test as base, expect } from '@playwright/test';
import { installGuard, stopRun } from '../.claude/lib/regression/guard.mjs';

export const test = base.extend({
  context: async ({ context }, use, testInfo) => {
    await installGuard(context, JSON.parse(process.env.REGRESSION_RUN ?? '{}'), { testInfo });
    await use(context);
  },
});

export { expect, stopRun };
