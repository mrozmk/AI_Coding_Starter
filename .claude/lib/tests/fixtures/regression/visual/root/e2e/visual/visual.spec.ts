// Fixture visual spec: visual.spec.ts.template with its placeholders filled.
import { test, expect } from '../fixtures';
import { loadRunManifest } from '../../.claude/lib/regression/guard.mjs';
import { visualTargets, renderTarget } from '../../.claude/lib/regression/visual-spec.mjs';

const manifest = loadRunManifest();

for (const t of visualTargets(manifest)) {
  test(`${t.id} — ${t.title}`, async ({ page, browser }, testInfo) => {
    await renderTarget({ page, browser }, testInfo, t, expect, manifest);
  });
}
