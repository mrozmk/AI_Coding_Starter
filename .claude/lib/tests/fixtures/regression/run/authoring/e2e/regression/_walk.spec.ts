// Regression inventory walk — the walk.spec.ts template with its placeholders filled (fixture).
import { test } from '../fixtures';
import { loadRunManifest } from '../../.claude/lib/regression/guard.mjs';
import { walkGroup } from '../../.claude/lib/regression/walk.mjs';

const manifest = loadRunManifest();

for (const group of manifest.walk?.groups ?? []) {
  test.describe(() => {
    test.use({ account: group.account });
    test(`${group.key} — ${group.account ?? 'anonymous'}`, async ({ page }, testInfo) => {
      test.setTimeout(manifest.walk.timeout_ms);
      await walkGroup({ page, manifest, group, testInfo });
    });
  });
}
