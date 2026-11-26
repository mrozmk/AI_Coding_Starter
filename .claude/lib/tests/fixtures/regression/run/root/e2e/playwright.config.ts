// Fixture runner config: guard-integrated (the production pre-flight reads the import below).
import { defineConfig } from '@playwright/test';
import { loadRunManifest, runnerOptions } from '../.claude/lib/regression/guard.mjs';

const opts = runnerOptions(loadRunManifest());

export default defineConfig({
  testDir: './regression',
  retries: 0,
  workers: opts.workers,
  reporter: [['json', { outputFile: './.results/report.json' }]],
  use: { baseURL: process.env.REGRESSION_BASE_URL, ...opts.use },
  projects: [
    { name: 'desktop-chrome', grep: opts.grepFor('desktop-chrome') },
    { name: 'mobile-safari', grep: opts.grepFor('mobile-safari') },
  ],
});
