import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseYaml } from './yaml-subset.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const POLICIES = path.join(HERE, '..', 'skills', 'audit-security', 'policies');

// Literal snapshots taken with the reader audit-security shipped before it was promoted here; the
// promoted reader must produce the same objects for the same policy files.
const POLICY_SNAPSHOT = {
  report: {
    mode: 'report',
    required_classes: { always: ['secrets'], by_stack: { sast: 'source', sca: 'manifest', iac: 'iac' } },
    blocking: { verdicts: ['confirmed'], severities: ['critical', 'high'], kev_always_blocks: true },
    exit: 'always-zero',
  },
  gate: {
    mode: 'gate',
    required_classes: { always: ['secrets'], by_stack: { sast: 'source', sca: 'manifest', iac: 'iac' } },
    blocking: { verdicts: ['confirmed'], severities: ['critical', 'high'], kev_always_blocks: true },
    exit: 'gate',
    waiver: { allowed: true, requires: ['reason', 'by'] },
  },
};

for (const mode of ['report', 'gate']) {
  test(`audit-security policy ${mode}.yaml parses to its pre-promotion snapshot`, () => {
    const text = fs.readFileSync(path.join(POLICIES, `${mode}.yaml`), 'utf8');
    assert.deepStrictEqual(parseYaml(text), POLICY_SNAPSHOT[mode]);
  });
}

// Verbatim copy of the worked example in .claude/skills/architect/system-schema.md.
const SYSTEM_EXAMPLE = `schema: 1
nodes:
  - id: platform-core
    name: Platform Core
    kind: trunk
  - id: identity
    name: Identity & Access
    kind: branch
    parent: platform-core
    subdomain: generic
  - id: authn
    name: Authentication
    kind: leaf
    parent: identity
    criticality: critical
    code: [src/auth/**]
  - id: business-core
    name: Business Core
    kind: branch
    parent: platform-core
    subdomain: core
  - id: orders
    name: Orders
    kind: leaf
    parent: business-core
    criticality: critical
    code: [src/orders/**]
  - id: integration
    name: Integration & Messaging
    kind: branch
    parent: platform-core
    subdomain: supporting
  - id: notification
    name: Notification
    kind: twig
    parent: integration
  - id: email
    name: Email
    kind: leaf
    parent: notification
    code: [src/notify/email/**]
  - id: data-analytics
    name: Data & Analytics
    kind: branch
    parent: platform-core
    subdomain: supporting
  - id: reporting
    name: Reporting
    kind: leaf
    parent: data-analytics
  - id: user-experience
    name: User Experience
    kind: branch
    parent: platform-core
    subdomain: supporting
  - id: web-app
    name: Web
    kind: leaf
    parent: user-experience
    criticality: critical
    code: [apps/web/**]
  - id: cloud
    name: Cloud
    kind: root
  - id: databases
    name: Databases
    kind: root
  - id: security
    name: Security
    kind: root
  - id: monitoring
    name: Monitoring
    kind: root
  - id: devops
    name: DevOps / CI-CD
    kind: root
links:
  - from: web-app
    to: authn
    kind: calls
  - from: web-app
    to: orders
    kind: calls
  - from: orders
    to: notification
    kind: events
  - from: orders
    to: reporting
    kind: events
  - from: identity
    to: business-core
    kind: ohs
flows:
  - id: place-order
    name: Place order
    critical: true
    fl: FL-1
    steps: [web-app, authn, orders, notification, email]
`;

test('system-schema.md example parses to nodes / links / flows of maps', () => {
  const doc = parseYaml(SYSTEM_EXAMPLE);
  assert.deepStrictEqual(Object.keys(doc), ['schema', 'nodes', 'links', 'flows']);
  assert.strictEqual(doc.schema, 1);
  assert.strictEqual(doc.nodes.length, 17);
  assert.deepStrictEqual(doc.nodes[0], { id: 'platform-core', name: 'Platform Core', kind: 'trunk' });
  assert.deepStrictEqual(doc.nodes[2], {
    id: 'authn', name: 'Authentication', kind: 'leaf', parent: 'identity', criticality: 'critical', code: ['src/auth/**'],
  });
  assert.deepStrictEqual(doc.nodes[6], { id: 'notification', name: 'Notification', kind: 'twig', parent: 'integration' });
  assert.deepStrictEqual(doc.nodes[16], { id: 'devops', name: 'DevOps / CI-CD', kind: 'root' });
  assert.deepStrictEqual(doc.nodes.filter((n) => n.kind === 'trunk').map((n) => n.id), ['platform-core']);
  assert.deepStrictEqual(doc.nodes.filter((n) => n.kind === 'root').length, 5);
  assert.deepStrictEqual(doc.links, [
    { from: 'web-app', to: 'authn', kind: 'calls' },
    { from: 'web-app', to: 'orders', kind: 'calls' },
    { from: 'orders', to: 'notification', kind: 'events' },
    { from: 'orders', to: 'reporting', kind: 'events' },
    { from: 'identity', to: 'business-core', kind: 'ohs' },
  ]);
  assert.deepStrictEqual(doc.flows, [
    { id: 'place-order', name: 'Place order', critical: true, fl: 'FL-1', steps: ['web-app', 'authn', 'orders', 'notification', 'email'] },
  ]);
});

test('map items may nest a block list', () => {
  const doc = parseYaml(`items:
  - id: a
    tags:
      - x
      - y
  - id: b
    tags: []
`);
  assert.deepStrictEqual(doc, { items: [{ id: 'a', tags: ['x', 'y'] }, { id: 'b', tags: [] }] });
});

test('scalar lists are unchanged', () => {
  const doc = parseYaml(`names:
  - alice
  - "bob"
  - 3
  - true
top: [a, b]
`);
  assert.deepStrictEqual(doc, { names: ['alice', 'bob', 3, true], top: ['a', 'b'] });
});

test('a URL list item stays a string, not a map', () => {
  const doc = parseYaml(`links:
  - https://example.com
  - "key: looks like a map but is quoted"
`);
  assert.deepStrictEqual(doc, { links: ['https://example.com', 'key: looks like a map but is quoted'] });
});

test('bad indent still throws yaml: unexpected indent', () => {
  assert.throws(() => parseYaml(`a:\n  b: 1\n    c: 2\n`), /yaml: unexpected indent/);
  assert.throws(() => parseYaml(`list:\n  - id: a\n      name: wrong\n`), /yaml: unexpected indent/);
});

test('a dedent below the document indent throws instead of truncating', () => {
  assert.throws(() => parseYaml(`  a: 1\n  b: 2\nc: 3\n`), /yaml: unexpected indent/);
});

test('comments and blank lines are ignored', () => {
  const doc = parseYaml(`# header\nmode: gate   # trailing\n\nexit: gate\n`);
  assert.deepStrictEqual(doc, { mode: 'gate', exit: 'gate' });
});
