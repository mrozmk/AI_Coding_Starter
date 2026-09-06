# Feature: <feature-name>

The following plan should be complete, but validate codebase patterns and task sanity before implementing. Pay special attention to the naming of existing utils, types and models; import from the right files.

**Source spec:** `.agents/specs/<spec-file>.md`
**Spec SHA-256:** `<sha256 of the approved spec bytes — the approval identity this plan was built from>`
**External docs required:** yes | no
**Execution effort:** medium
**Appetite:** <from the spec — omit this line and the next if the spec has none>
**Cut first (if this overruns):** <the spec's cut order, verbatim>

> `**Execution effort:**` is always written explicitly by this generator (`medium` is the default target: Opus at effort medium). An explicit `low` in an older plan stays `low`; a plan with no field keeps the legacy `low` fallback in its readers. Never invent a third level or a model name here.

## Feature Description

<Derived from the spec's Summary + Problem/Solution, expanded with implementation-level detail>

## Solution Statement

<From the spec's Solution, refined into the concrete implementation approach>

## Feature Metadata

**Feature Type**: New Capability | Enhancement | Refactor | Bug Fix
**Estimated Complexity**: Low | Medium | High
**Primary Systems Affected**: <components / services>
**Dependencies**: <external libraries or services — matches the spec's External dependencies>

---

## CONTEXT REFERENCES

### Relevant Codebase Files — READ BEFORE IMPLEMENTING

- `path/to/file.ext` (lines X-Y) — Why: <pattern to mirror / contract to keep>

### New Files to Create

- `path/to/new.ext` — <purpose>

### Relevant Documentation ⟂ conditional — only if External docs required: yes

- [Doc title](https://example.com/doc#section) — Why: <what it unblocks>

### Patterns to Follow

<Concrete patterns from the codebase, with snippets: naming, error handling, logging, tests>

---

## Architecture and contracts

> Compact and mandatory — project constraints an executor must not cross, not a coding tutorial. Each line names a real module or rule; delete a line only when the spec genuinely has nothing for it.

- **Owned modules:** <the modules/directories this plan is allowed to change>
- **Dependency direction:** <who may import whom; layers that must stay one-way>
- **Interfaces & invariants:** <public signatures, data shapes, ordering/encoding rules that must hold after the change>
- **Reuse targets:** <existing utils/types/services to import instead of re-creating — `file:line`>
- **Prohibited changes:** <files, contracts, migrations or behaviors this plan must leave alone>
- **Migration constraints:** <data/config/compat steps that must precede or follow — or "none">

## UI structural contract ⟂ conditional — only when the spec names a design reference

> Pointing at a design file is not a contract. Enumerate what the executor must reproduce so the parity audit cannot surprise anyone.

- **Design reference:** `<path to the approved mockup>`
- **Section inventory + order:** <top-level sections in the exact rendered order>
- **Variant / state matrix:** <every variant, card state, empty/error/loading state the design shows>
- **Copy strings:** <headline, CTA labels, microcopy specified verbatim>
- **Semantic requirements:** <native vs custom elements, framework Link vs a, i18n namespace, icon set, accessibility names/roles>
- **Runtime validation:** <how the rendered result is checked — runtime smoke baseline → reload → diff, or `SKIPPED` with the reason when no app runs>

## Independent tracks

<One or two sentences: are there genuinely disjoint tracks (no shared files, no shared contracts)? Name them. Splitting the plan is the user's decision at grilling time, never automatic.>

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable. Every task is mandatory.

### {CREATE | UPDATE | ADD | REMOVE | REFACTOR | MIRROR} {target_file}

- [ ]

- **IMPLEMENT**: <specific implementation detail>
- **PATTERN**: <existing pattern — file:line>
- **IMPORTS**: <required imports>
- **GOTCHA**: <known constraints>
- **EXPECT**: present | absent | contains | not-contains — {path}[ :: {literal or symbol}]
- **VALIDATE**: `{executable validation command — exit 0 on success}`

> The `- [ ]` line is a **parse anchor** for the verification gate; the executor never ticks it. `EXPECT` is required on every task (repeatable) and is what the gate mechanically verifies; `VALIDATE` must exit non-zero on failure. Keep `## STEP-BY-STEP TASKS`, the anchor, `EXPECT` and `VALIDATE` exactly — the gate parser depends on them.

---

## TESTING STRATEGY

<Scope tests to the project's stated policy (rules → Validation) or its existing suite. Sensitive paths (payment, auth, webhook, license, locale/redirect routing, permission isolation, subprocess supervision) MUST have unit tests.>

### Core Functions to Test

### Edge Cases

---

## VALIDATION COMMANDS

### Level 1: Automated

```bash
<typecheck / lint / test commands, in order, fail fast — always present and executable>
```

### Level 2: Manual Validation

<Feature-specific manual steps>

---

## ACCEPTANCE CRITERIA

<Judged, never counted — the counted list is STEP-BY-STEP TASKS.>

- [ ] Feature implements all specified functionality
- [ ] All validation commands pass with zero errors
- [ ] Code follows project conventions and patterns
- [ ] No regressions in existing functionality
- [ ] Tests written where the policy requires them
- [ ] Security considerations addressed (if applicable)

---

## NOTES

<Design decisions and trade-offs, kept minimal — the spec carries the why, the plan the how.>

## Independent Review

<Filled by the review step: reviewer host/model/effort, review_id, reviewed SHA-256, verdict, accepted/rejected findings, rounds (max 3), repeat/skip reason.>
