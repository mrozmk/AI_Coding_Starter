import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { RECEIPT, STATE_DIR, STATE_FILE, acknowledgeHooks, hookState, isLegacyReceipt, migrateReceipt, readReceipt, readState, resolveBoundRoot, verifyPackageRoot } from '../../harness-source/scripts/lib/locator.mjs';
import { bindInstalledRoot, checkVersion } from '../../harness-source/scripts/profile.mjs';
import { buildAll } from '../../scripts/build-harness.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const MINI = path.join(import.meta.dirname, 'fixtures/mini-repo');

function install() {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-bind-install-'));
  buildAll(MINI, out);
  return path.join(out, 'packages/claude');
}
const project = () => fs.mkdtempSync(path.join(os.tmpdir(), 'harness bind project-'));

test('bind writes a portable receipt (identity only) and a local, gitignored state (root, timestamp, machine)', () => {
  const root = install();
  const proj = project();
  const preview = bindInstalledRoot({ projectRoot: proj, host: 'claude', pluginRoot: root, consent: false });
  assert.equal(preview.ok, true);
  assert.ok(!fs.existsSync(path.join(proj, RECEIPT)), 'no consent → nothing written');
  const res = bindInstalledRoot({ projectRoot: proj, host: 'claude', pluginRoot: root });
  assert.equal(res.ok, true);
  const receipt = readReceipt(proj);
  assert.equal(receipt.schema_version, 2);
  assert.equal(receipt.name, 'harness');
  assert.deepEqual(Object.keys(receipt.hosts.claude).sort(), ['payload_digest', 'source_digest', 'version']);
  const text = fs.readFileSync(path.join(proj, RECEIPT), 'utf8');
  assert.ok(!text.includes(root) && !text.includes('bound_at') && !text.includes(os.hostname()), 'no machine facts in the committed receipt');
  const state = readState(proj);
  assert.equal(state.hosts.claude.root, fs.realpathSync.native(root));
  assert.match(state.hosts.claude.bound_at, /^\d{4}-/);
  assert.equal(fs.readFileSync(path.join(proj, STATE_DIR, '.gitignore'), 'utf8').includes('*'), true, 'state is gitignored by its own .gitignore');
  assert.equal(checkVersion({ projectRoot: proj, host: 'claude', pluginRoot: root }).ok, true);
});

test('a copied receipt is not an installation: another machine must bind locally; a wrong payload is refused', () => {
  const root = install();
  const proj = project();
  bindInstalledRoot({ projectRoot: proj, host: 'claude', pluginRoot: root });
  const clone = project();
  fs.mkdirSync(path.join(clone, '.agents'), { recursive: true });
  fs.copyFileSync(path.join(proj, RECEIPT), path.join(clone, RECEIPT));
  const res = resolveBoundRoot(clone, 'claude');
  assert.equal(res.ok, false);
  assert.match(res.errors[0], /no local binding.*a committed receipt is not an installation/);
  assert.equal(res.expected.version, '0.0.1');
  const other = install();
  fs.appendFileSync(path.join(other, 'references/demo.md'), 'different bytes');
  const rebuilt = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-bind-other-'));
  fs.cpSync(MINI, rebuilt, { recursive: true });
  fs.writeFileSync(path.join(rebuilt, 'harness-source/references/demo.md'), 'changed source\n');
  buildAll(rebuilt, rebuilt);
  const wrong = bindInstalledRoot({ projectRoot: clone, host: 'claude', pluginRoot: path.join(rebuilt, 'packages/claude') });
  assert.equal(wrong.ok, true, 'binding the other machine to what it has is allowed…');
  const check = resolveBoundRoot(clone, 'claude');
  assert.equal(check.ok, true, '…and the receipt now records that identity');
  fs.copyFileSync(path.join(proj, RECEIPT), path.join(clone, RECEIPT));
  const mismatch = resolveBoundRoot(clone, 'claude');
  assert.equal(mismatch.ok, false, 'the committed expectation and the local package disagree');
  assert.match(mismatch.errors[0], /differs from the version the project expects|source digest differs/);
});

test('a schema-1 receipt is read compatibly and migrated only with consent, never adopting a foreign root', () => {
  const root = install();
  const proj = project();
  const verified = verifyPackageRoot(root, { host: 'claude' });
  fs.mkdirSync(path.join(proj, '.agents'), { recursive: true });
  const legacy = { schema_version: 1, hosts: { claude: { root: verified.root, name: 'harness', version: '0.0.1', source_digest: verified.marker.source_digest, payload_digest: verified.marker.payload_digest, bound_at: '2026-09-01T00:00:00Z' }, codex: { root: '/Users/someone-else/.codex/plugins/harness', name: 'harness', version: '0.0.1', source_digest: verified.marker.source_digest, payload_digest: verified.marker.payload_digest, bound_at: '2026-09-01T00:00:00Z' } } };
  fs.writeFileSync(path.join(proj, RECEIPT), JSON.stringify(legacy));
  assert.ok(isLegacyReceipt(readReceipt(proj)));
  const compat = resolveBoundRoot(proj, 'claude');
  assert.equal(compat.ok, true, 'old receipt still resolves where its root verifies');
  assert.equal(compat.migration_needed, true);
  const foreign = resolveBoundRoot(proj, 'codex');
  assert.equal(foreign.ok, false);
  assert.equal(foreign.migration_needed, true);
  const preview = migrateReceipt(proj);
  assert.equal(preview.migrated, false);
  assert.ok(isLegacyReceipt(readReceipt(proj)), 'no consent → untouched');
  assert.ok(preview.preview.report.some((r) => /codex: recorded root not adopted/.test(r)));
  const done = migrateReceipt(proj, { consent: true });
  assert.equal(done.migrated, true);
  const portable = readReceipt(proj);
  assert.equal(portable.schema_version, 2);
  assert.deepEqual(Object.keys(portable.hosts).sort(), ['claude', 'codex'], 'expectations for both hosts travel');
  assert.ok(!JSON.stringify(portable).includes('/Users/someone-else'));
  const state = readState(proj);
  assert.equal(state.hosts.claude.root, verified.root);
  assert.equal(state.hosts.codex, undefined, 'another machine\'s root is never copied as authority');
  assert.equal(resolveBoundRoot(proj, 'claude').ok, true);
  assert.match(resolveBoundRoot(proj, 'codex').errors[0], /no local binding/);
  assert.deepEqual(migrateReceipt(proj, { consent: true }), { ok: true, migrated: false, reason: 'receipt already schema 2' });
});

test('installed is not trusted: hook trust is a local acknowledgement, consent-gated', () => {
  const root = install();
  const proj = project();
  assert.equal(hookState(proj, 'claude').state, 'unbound');
  bindInstalledRoot({ projectRoot: proj, host: 'claude', pluginRoot: root });
  const untrusted = hookState(proj, 'claude');
  assert.equal(untrusted.state, 'installed-untrusted');
  assert.equal(untrusted.trusted, false);
  const preview = acknowledgeHooks(proj, 'claude', { trusted: true, by: 'operator' });
  assert.equal(preview.written, false);
  assert.equal(hookState(proj, 'claude').trusted, false);
  acknowledgeHooks(proj, 'claude', { trusted: true, by: 'operator', evidence: 'release-readiness claude:hooks-trusted', consent: true });
  assert.equal(hookState(proj, 'claude').state, 'trusted');
  assert.equal(acknowledgeHooks(proj, 'codex', { trusted: true, by: 'x', consent: true }).ok, false, 'no binding, no trust');
  assert.ok(!fs.readFileSync(path.join(proj, RECEIPT), 'utf8').includes('trusted'), 'acknowledgements stay local');
  assert.ok(fs.existsSync(path.join(proj, STATE_FILE)));
  const marker = JSON.parse(fs.readFileSync(path.join(root, 'harness-build.json'), 'utf8'));
  marker.hooks = { 'guard-commit': 'hooks/core/commit.mjs' };
  fs.writeFileSync(path.join(root, 'harness-build.json'), JSON.stringify(marker));
  assert.ok(verifyPackageRoot(root, { host: 'claude' }).errors.some((e) => /hook target missing/.test(e)), 'a marker naming an absent hook target fails verification');
});

test('the same release payload loaded from another directory still counts as bound; a different payload does not', () => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'harness bind-alt-'));
  const a = fs.mkdtempSync(path.join(os.tmpdir(), 'harness pkg-a-'));
  const b = fs.mkdtempSync(path.join(os.tmpdir(), 'harness pkg-b-'));
  for (const dir of [a, b]) fs.cpSync(path.join(REPO, 'packages/claude'), dir, { recursive: true });
  assert.equal(bindInstalledRoot({ projectRoot: project, host: 'claude', pluginRoot: a }).ok, true);
  const alt = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: b });
  assert.equal(alt.ok, true, alt.errors?.join('; '));
  assert.equal(fs.realpathSync(alt.alternate_root), fs.realpathSync(b));
  assert.match(alt.note, /identical payload/);
  const marker = JSON.parse(fs.readFileSync(path.join(b, 'harness-build.json'), 'utf8'));
  marker.payload_digest = 'f'.repeat(64);
  fs.writeFileSync(path.join(b, 'harness-build.json'), JSON.stringify(marker, null, 2));
  const bad = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: b });
  assert.equal(bad.ok, false);
});
