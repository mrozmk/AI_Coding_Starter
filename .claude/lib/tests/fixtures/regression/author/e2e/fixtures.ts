// Fixture fixtures module: guard-integrated; exempt from the network and process rules.
import { test as base, expect } from '@playwright/test';
import { installGuard } from '../.claude/lib/regression/guard.mjs';

export const test = base.extend({
  context: async ({ context }, use, testInfo) => {
    await installGuard(context, JSON.parse(process.env.REGRESSION_RUN ?? '{}'), { testInfo });
    await use(context);
  },
});

export { expect };
