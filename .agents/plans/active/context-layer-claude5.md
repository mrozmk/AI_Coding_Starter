# Feature: Always-loaded context layer for Claude 5 generation models

**Source spec:** `.agents/specs/2026-07-26-context-layer-claude5.md`
**External docs required:** no

> Validate task sanity against the repo before implementing. Above all: **the exact heading text of
> every section you touch is an API** — and so are two *content* lines inside `Git Workflow`. Eleven
> headings are addressed by name from commands and one hook; renaming or deleting one breaks a
> consumer silently, with no error.
>
> **Measurements below were re-taken on 2026-07-29, after merge `d869d42` pulled 9 commits from
> `origin/main`.** That merge grew `CLAUDE.md` and added two new contracts. If you are reading this
> after another sync, re-measure before trusting any number or line reference in this plan.

## Feature Description

Shrink the template's always-loaded context layer — the seed `CLAUDE.md`, the `CLAUDE-template.md` it
is generated from, and the generator's instructions — from 239 lines / 18 700 chars to ≤165 / ≤9 500,
and settle the routing conflict between `.agents/memory/` and Claude Code's native per-user
auto-memory. A documentation/template refactor: this repo has no application code, and every artifact
touched is markdown consumed by Claude Code at runtime.

## User Story

As a developer bootstrapping projects from this starter kit
I want `CLAUDE.md` to carry only rules, policies, and pointers
So that every downstream session stops paying context tax for prose the model already has.

## Problem Statement

`CLAUDE.md` loads into every conversation of every project generated from this template. It is 239
lines against a ≤200 cap that two files declare and neither enforces — and it crossed that cap while
the cap was sitting there in writing, which is the whole argument for making it executable. Roughly
half its content restates `index.md`, `settings.json`, agent frontmatter, or
`parallel-orchestration.md`. Separately,
the harness now tells the model to write to a native per-user memory directory while `CLAUDE.md`
routes the same discoveries to `.agents/memory/` — a live conflict. Full detail: spec → *Problem*.

## Solution Statement

Cut **vertically**: keep every heading a command or hook addresses by name, compress the prose
beneath it to a rule plus a pointer, delete outright only the three sections with zero referents.
Mirror the cut onto the template so it actually propagates. Give the generator the rationale it never
had **and an executable gate**, so the cap binds instead of being a comment. Settle memory scope in
favour of the repository.

## Feature Metadata

**Type**: Refactor (documentation / harness configuration)
**Complexity**: Medium — low per-edit difficulty, high blast radius, several silent-failure invariants
**Systems**: `CLAUDE.md`, `.claude/templates/`, `.claude/commands/setup/`, `.agents/memory/index.md`,
`.claude/skills/jira/`
**Dependencies**: none

---

## Execution Plan

> **For orchestrator.** Single source of truth for step order, dependencies, and progress. Statuses
> updated in-place. Valid: `pending` | `in_progress` | `done` | `blocked` | `skipped` | `manual`.

| Step | File | Depends On | Status | Effort |
| ---- | ---- | ---------- | ------ | ------ |
| 1 | [context-layer-claude5-1-rules-rehoming.md](./context-layer-claude5-1-rules-rehoming.md) | — | pending | low |
| 2 | [context-layer-claude5-2-cut.md](./context-layer-claude5-2-cut.md) | 1 | pending | medium |

### Step complexity (informational, not parsed)

| Step | Complexity | Why |
| ---- | ---------- | --- |
| 1 | easy | three additive edits, no deletions, no contract risk |
| 2 | complex | eleven exact-text invariants, two files that look alike but are not, one executable gate to author |

---

## CONTEXT REFERENCES

### Relevant Codebase Files — READ BEFORE IMPLEMENTING

- `.agents/specs/2026-07-26-context-layer-claude5.md` — **read for the method and the rollout matrix,
  not for numbers.** Its anchor table carries `file:line` consumers that have already drifted (it
  cites `orchestrate.md:635`; the consumer now sits at 660). Trust the heading names in it; re-derive
  every line number yourself.
- `CLAUDE.md` (239 lines / 18 700 chars, 17 `##` sections) — primary edit target.
- `.claude/templates/CLAUDE-template.md` (237 lines / 10 436 chars **total**; the generated body
  starts at `# CLAUDE.md` on line 20 and is **218 lines / 9 295 chars**) — what the generator copies
  from. Own cap at line 5, own mandatory list at 13–14. **The two numbers are not interchangeable —
  see *Which surface the cap measures* below.**
- `.claude/commands/setup/create-CLAUDE_MD.md` (353 lines) — cap at 191, "where detail lives" table
  at 193–201, `Orchestrate publish` derive at 119 and fill at 208, LSP instruction at 206, stale
  trigger description at 224, `On-demand context references` licence at 236, mandatory list at
  210–220, success report at 300–346 (**where the cap gate must go**).
- `.agents/memory/index.md` (132 lines — it shrank when `reflection-protocol.md` was extracted) —
  `Quick Reference` at 7, `When to Read` at 23.
- `.claude/commands/orchestrate.md` — **two content-level consumers of `CLAUDE.md`**: line 103 reads
  the `**Orchestrate publish:**` value, line 660 cites the force-remove guard.
- `.claude/hooks/nudge-lsp.sh:42` — `grep -q "Code Navigation" CLAUDE.md`. The only hook reading
  `CLAUDE.md` content.
- `.claude/starter-sync-playbook.md` — sync categories: `index.md` is B (58); `CLAUDE.md` is C (69)
  and `.agents/specs/` is C (72).

### New Files to Create

None. Every task modifies an existing file.

---

## The anchor contract

Consumers reference headings in **four** syntactic forms. Any audit matching fewer under-reports —
this is not hypothetical, it produced two wrong anchor sets during planning:

| Form | Example |
|---|---|
| arrow pointer | `CLAUDE.md → Validation` |
| backtick-quoted | `` `CLAUDE.md` → Security `` |
| markdown link + name | `[CLAUDE.md](../../CLAUDE.md) Git Workflow` |
| bare heading literal | `` `## Project Knowledge Layers` `` |

**Eleven unconditional exact headings** — `Language Rules`, `Validation`, `Commands`,
`Code Structure & Modularity`, `Style & Conventions`, `Tech Stack`, `Automatic Behaviors`,
`Search Commands`, `Security`, `Git Workflow`, `Project Knowledge Layers` — **plus one conditional
substring contract**, `Code Navigation`, which the generator emits only for LSP projects and as
`## Code Navigation (LSP)`. Twelve strings, two kinds; do not collapse them into one count.
`Error Handling` is the only section kept purely on policy grounds. Consumers are enumerated with
`file:line` in the spec — **read it there. Do not re-derive it from a pointer regex.**

`Project Knowledge Layers` is additionally a **structural** contract: `createwikillm.md:249` inserts
a row into that table, so the table must survive, not just the heading.

### Two CONTENT contracts inside `Git Workflow` — headings are not the whole API

Both arrived with merge `d869d42` and both live inside the section Step 2 compresses hardest. A
heading-only audit does not see them; that is exactly why they are called out here.

| Contract | Consumer | What breaks if it goes |
|---|---|---|
| the line `**Orchestrate publish:** push` (`CLAUDE.md:131`) plus its explanatory blockquote | `orchestrate.md:103` reads it; `create-CLAUDE_MD.md:119` derives the value and `:208` fills the slot | No error. `/orchestrate` silently falls back to its `push` default — so a downstream PR-gated project that had declared `branch-local` starts pushing again after regeneration. |
| the force-remove guard sentence inside the `allow` tier (`CLAUDE.md:124`) | `orchestrate.md:660` — markdown-link form, cites it by name | The citation dangles. The rule itself is **not** a restatement of `settings.json` — it is an operational guard that exists nowhere else. |

**Consequence for Step 2:** deleting the `allow`/`ask`/`deny` enumerations is still right — they *are*
a restatement of `settings.json`. But the force-remove sentence must be kept (one line is enough),
and the `Orchestrate publish` line + blockquote must survive verbatim in the seed and as a
`{push | branch-local}` placeholder in the template.

### Do not freeze `file:line` into a generated artifact

The spec's anchor table pairs each heading with `file:line` consumers. That is fine **in the spec**,
which is a point-in-time audit. It must **not** be copied into `create-CLAUDE_MD.md`, which ships to
every downstream project and is regenerated on a schedule nobody controls. Proof that this decays
immediately: the spec cites `orchestrate.md:635`; nine commits later the same consumer is at 660,
and nothing flagged it. The generator gets **the list of protected heading names plus the
heading-outward audit command** — names are stable, line numbers are not.

**The generator's mandatory-section list does not currently protect all of them.** `Validation`,
`Commands`, `Style & Conventions`, and `Tech Stack` are contractual yet absent from it — a future
generation could legally drop them. Step 2 adds them.

**Audit method:** search from the headings outward, never from pointer syntaxes inward. Enumerating
syntaxes is what failed; a heading no known syntax matches is invisible. False positives are
harmless — keeping an unneeded heading costs one line, deleting a needed one breaks a consumer with
no error. The asymmetry decides the design. Command: spec → *Verification command*.

---

## Seed vs template — they are NOT identical

The template is a **superset**: `## Testing` and `## Notes` are template-only, it orders
`Language Rules` after `Git Workflow` (line 152, vs 15 in the seed), keeps `{communication-language}`
unsubstituted, and carries a 19-line preamble before `# CLAUDE.md` at line 20. Their shared sections
also differ in content — audited table in Step 2 → *Step A*.

**The invariant is narrower than "identical bodies":** same contractual anchor set with identical
heading text · same `≤165` cap · same mandatory-section list · same cut applied to every section the
two files genuinely share. `## Testing` and `## Notes` are out of scope in both directions.

### Which surface the cap measures

The template file is 237 lines, but its first 19 lines are **instructions to the generator** — they
describe how to use the template and never appear in any generated `CLAUDE.md`. Measuring them
against a cap on the always-loaded context layer measures the wrong thing.

**Rule: the cap applies to the template BODY, starting at the exact line `# CLAUDE.md` (line 20).**
Body today: **218 lines / 9 295 chars**. The 19-line preamble is excluded from every measurement, in
this plan and in the gate. The seed has no preamble, so its cap applies to the whole file.

Without this rule the template appears to violate a cap it does not actually violate, and someone
"fixes" it by cutting content that was never the problem.

---

## Testing strategy

**Maturity signals, in priority order:** (1) `CLAUDE.md → Validation` holds only
`{typecheck}`/`{lint}`/`{test}` placeholders — the template has never been instantiated, so it states
no enforceable policy; (2) existing test count is zero; (3) the repo is markdown and shell only.

**Verdict: no test suite, and none warranted.** Not a coverage gap waved through — this feature ships
no runtime code. The sensitive-path gate does not trigger: no payment, auth, webhook, license, or
locale-redirect code is touched. Manual validation replaces tests and is mandatory — the full gate
lives in Step 2 → *Level 3*, and both failure modes that matter (a broken anchor, a seed/template
divergence) are scripted there.

---

## Definition of Done

- [ ] Both steps `done` in the Execution Plan table
- [ ] Step 2's Level 3 gate run in full, every check passing
- [ ] Before→after line **and** char counts recorded for `CLAUDE.md` and the template **body**
- [ ] No contractual anchor lost from either file — headings **and** the two `Git Workflow` content
      contracts (`Orchestrate publish`, force-remove guard)
- [ ] No `file:line` table written into `create-CLAUDE_MD.md`

---

## Notes

**Why vertical.** Eleven headings are addressed by name across the harness plus a literal `grep` in
`nudge-lsp.sh`. The prose beneath a heading is free to go; the heading is not.

**Why the generator gets a gate, not just a smaller number.** The cap already existed in two files
and bound nothing — which is exactly how the seed reached 239 lines. A number without an enforcement
step is a comment.

**Rollout is not uniform**, and most of this feature reaches existing projects *immediately* — only
the root `CLAUDE.md` cut waits:

| Surface | Sync category | Reaches an existing project? |
|---|---|---|
| `CLAUDE.md` | C — never overwritten | **No.** New bootstraps only. |
| `.agents/memory/index.md` (`Memory scope`) | B — merged | **Yes, on next sync.** |
| `create-backlog.md`, `jira/SKILL.md` (Step 1) | **A** | **Yes, on next sync** — these rules go live without any regeneration |
| `CLAUDE-template.md`, `create-CLAUDE_MD.md` | A | Synced, but effective only when the project re-runs `/setup:create-CLAUDE_MD` |

An earlier draft claimed everything but memory scope waited for a bootstrap. That was wrong: Step 1
edits a slash command and a skill, and `starter-sync-playbook.md:20–25` puts all of
`.claude/commands/*.md` and `.claude/skills/**` in category A.

**Deliberately excluded:** `guard-memory.sh` hard-block → nudge, directive density in
`orchestrate.md` / `plan-feature.md`, `/plan-feature` verification rubrics — each tracked separately.
