# `docs/map/system.yaml` — schema

The machine form of `docs/architecture.md`: the nodes of the architecture tree, the typed links
between them, and the flows that cross them. `/architect` Phase 4 writes it; `backlog-check.mjs`
(`--system-only`, and the full run) validates it and resolves the backlog's `Node` cells against
it; the later tree app renders it. **Status and progress are never stored here** — they live in
`.agents/backlog.md`, so the map stays a pure projection of structure.

**Block style only.** The reader is `.claude/lib/yaml-subset.mjs` (node builtins, no YAML
dependency): block maps by indentation, `- ` lists of scalars or maps, `[inline, lists]`,
quoted/bare scalars, `#` comments. **No** `{flow: maps}`, no anchors, no multi-line scalars, no `#`
inside a value. A list item that opens a map (`- id: x`) keeps its other keys two spaces deeper
than the dash; a block list nested under a key is indented deeper than that key — a list at the
key's own indent is rejected.

---

## 1. Top level

| Key | Type | Rule |
|---|---|---|
| `schema` | number | `1` — bumped only with a reader change |
| `nodes` | list of maps | the tree, §2 |
| `links` | list of maps | the context map and cross-tree links, §3 |
| `flows` | list of maps | the critical paths through the tree, §4 |

## 2. `nodes[]`

| Field | Values | Rule |
|---|---|---|
| `id` | kebab-case, `^[a-z][a-z0-9-]*$` | unique across all nodes; the value the backlog's `Node` cell and every `links` / `flows` entry use |
| `name` | free text | the display name (`docs/architecture.md` uses it) |
| `kind` | `trunk` · `branch` · `twig` · `leaf` · `root` | **exactly one `trunk`** per file. `branch` = bounded context hanging off the trunk; `twig` = a sub-grouping inside a branch; `leaf` = the smallest unit a Task targets (a service, module or component); `root` = infrastructure / generic foundation below the ground line (cloud, databases, security, monitoring, CI-CD) |
| `parent` | a node `id` | **required** for `branch`, `twig`, `leaf`; **absent** for `trunk` and `root`. Parents form a tree under the trunk: branch → trunk, twig → branch (or twig), leaf → branch or twig |
| `subdomain` | `core` · `supporting` · `generic` | required on every `branch` (the classification from `docs/architecture.md` → `## Subdomains`); optional on twigs/leaves (inherit the branch's) |
| `criticality` | `critical` · `normal` | default `normal`; `critical` marks a node the critical `FL-n` passes through (a generic node can be critical — `authn`) |
| `code` | inline list of globs | optional; the paths that implement the node (`[src/auth/**]`) — the later drift check compares them against the repository |

## 3. `links[]`

| Field | Values | Rule |
|---|---|---|
| `from`, `to` | node ids | both must exist in `nodes` |
| `kind` | `calls` · `events` · `acl` · `ohs` · `customer-supplier` · `conformist` · `realizedBy` | the first six are the context-map kinds of `subdomains.md` §3 and must agree with the edges in `docs/architecture.md` → `## Context map`. `realizedBy` is the cross-tree link — a business-process node realised by an architecture node — and never appears in the context map |

Direction: `from` is the consumer/caller (`calls`, `acl`, `conformist`), the publisher
(`events`), the host (`ohs`), the supplier (`customer-supplier`), the business node (`realizedBy`).

## 4. `flows[]`

| Field | Values | Rule |
|---|---|---|
| `id` | kebab-case | unique among flows |
| `name` | free text | |
| `critical` | `true` · `false` | `true` for the flow that realises the discovery flow marked `**Critical:** yes` — every critical `FL-n` must have one flow here |
| `fl` | `FL-n` | optional — the `docs/discovery.md` flow this one realises; when present it must exist there |
| `steps` | inline list of node ids | every step is an existing node, in traversal order; a flow with fewer than two steps is not a flow |

## 5. Integrity rules (what `backlog-check.mjs --system-only` enforces)

- ids unique across `nodes`; exactly one `trunk`
- every `parent` exists and the parent chain ends at the trunk; `trunk` and `root` have no parent
- every `branch` carries a `subdomain`
- every `links[].from` / `to` and every `flows[].steps[]` entry is an existing node id
- `kind` values are from the enumerations above
- every critical `FL-n` in `docs/discovery.md` has a flow with `critical: true` (full run only —
  `--system-only` has no discovery file to read)
- no `status`, `progress`, `done` or similar key anywhere — rejected

## 6. Worked example

The reference tree from the C4 / context-map survey behind this skill:
Platform Core trunk; Identity & Access, Business Core, Integration & Messaging, Data & Analytics,
User Experience branches; a Notification twig; five roots. Copied verbatim into
`.claude/lib/yaml-subset.test.mjs` — a change here is a change there.

```yaml
schema: 1
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
```
