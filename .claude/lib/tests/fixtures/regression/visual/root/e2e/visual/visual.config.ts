// Fixture visual config: visual.config.ts.template with its placeholders filled.
import { defineConfig, devices } from '@playwright/test';
import { loadRunManifest, runnerOptions } from '../../.claude/lib/regression/guard.mjs';
import { visualOptions } from '../../.claude/lib/regression/visual-spec.mjs';

const m = loadRunManifest();
const r = runnerOptions(m);
const v = visualOptions(m);

export default defineConfig({
  testDir: v.testDir,
  testMatch: v.testMatch,
  ignoreSnapshots: false,
  retries: 0,
  workers: r.workers,
  repeatEach: v.repeatEach,
  outputDir: v.outputDir,
  snapshotPathTemplate: v.snapshotPathTemplate,
  updateSnapshots: v.updateSnapshots,
  expect: v.expect,
  reporter: [['json', { outputFile: '../.results/visual-report.json' }]],
  use: { baseURL: process.env.REGRESSION_BASE_URL, ...r.use, ...v.use },
  projects: [
    { name: 'desktop-chrome', grep: r.grepFor('desktop-chrome'), use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile-safari', grep: r.grepFor('mobile-safari'), use: { ...devices['iPhone 13'] } },
  ],
});
