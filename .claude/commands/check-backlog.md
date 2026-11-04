---
description: Independent critic + grill for .agents/backlog.md — @start-critic grades it against the backlog rubric, the main thread judges, the user decides, accepted fixes go through /update-backlog's apply phase
argument-hint: "[--epic E<n>] [--since D-k]"
---

# Check Backlog: Critic + Grill

## Input: $ARGUMENTS

`/setup:create-backlog` ends with the mechanical checker; the judgement calls — is Wave 0 minimal,
is this `H` really an `XH`, are the criteria testable outcomes, is the skeleton thin, is a
dependency really a soft relation — need an independent reader. This command adds one, and routes
every accepted fix through `/update-backlog` (the backlog's only structural writer).

**This command writes nothing itself** except the one `**Last check:**` header line (step 10).
Every structural change goes through `/update-backlog`'s apply phases.

Scope: empty = the whole backlog · `--epic E<n>` = that Epic · `--since D-k` = the Tasks named in
the `**Tasks:**` lines of `D-k` and every later `D-n`, plus one hop of `Relates` siblings and direct
`Depends on` neighbours.

---

## 0. Preconditions

`/prime` ran; `.agents/backlog.md` exists; the PRD's `**Current:**` equals the backlog's
`**Scope rev:**` — otherwise "run `/update-backlog` first" and stop (a check against a stale backlog
grades the wrong scope).

## 1. Mechanical gate

`node .claude/lib/backlog-check.mjs` — errors → print them and stop. Warnings → kept verbatim and
passed to the critic as known context (it must not re-report them).

## 2. Current view

`node .claude/lib/backlog-check.mjs --next-ids` → write, for every in-scope **live** Task, its
`current` criteria (id, text, source file; withdrawn ones omitted) to
`$SCRATCH/check-backlog-current.md` (`$SCRATCH` = the session scratchpad, never `/tmp`, never the
repo). These are the criteria the critic grades — they may come from an approved spec, not the
backlog block.

## 3. Critic

Spawn `@start-critic` (read-only) with:

```
ARTIFACT: .agents/backlog.md $SCRATCH/check-backlog-current.md
RUBRIC:   .claude/skills/backlog/backlog-rubric.md
SOURCES:  docs/PRD.md docs/discovery.md docs/architecture.md docs/map/system.yaml (those that exist)
          + every approved spec named in the Ref cell of an in-scope Task
ROUND:    1
PRIOR:    (the checker warnings, verbatim, as known context)
SCOPE:    all | E<n> | <the --since Task set>
RULES:    (see below)
```

- ≤ ~25 live Tasks, or a narrow `--epic` / `--since`: **one call, all rules**.
- Otherwise: one call per in-scope Epic with `RULES: K1,K2,K5,K7` and `SCOPE: E<n>`, plus one call
  with `RULES: K3,K4,K6,K8,K9,K10` and `SCOPE` = the selection.

Deduplicate findings by (rule, id). A spawn failure → `Critic: not-reviewed — <reason>`; the
verdict cannot be `ship`.

## 4. Judge

Every finding in the main thread, one line each: `[#NN] KEEP | DROP — reason` — anchored? real?
severity honest? a duplicate of a checker warning? (→ drop).

## 5. Grill

Each kept `blocker` / `major` → one `AskUserQuestion` (at most 8 per run; the rest are listed as open
findings). Recommended option = the critic's `fix`; plus "keep as is — reason recorded". Accepted
answers become **intents** in `/update-backlog`'s model:

| Accepted fix | Intent |
|---|---|
| split a Task | `split` — replacements share its traces, the first takes its prerequisites, its dependents are redirected to the named replacement |
| merge Tasks | `merge` — union of traces and prerequisites, dependents redirected |
| move wave / slice / resize | `edit` of the structural cells |
| a soft relation / a chain | `edit` adding `Relates` / `Chain` |
| rewrite a criterion | withdraw the AC id + a new id |

A split or merge whose dependent is protected, or whose redirect is ambiguous, becomes a question —
never a silent rewire.

## 6. Apply

When any intent exists: run `/update-backlog`'s apply phases (Phase 5 impact → Phase 6 candidate →
Phase 7 preview → Phase 8 write) with these intents, the `D-n` titled `check-backlog <date>` and
`Sources: BA direct decision (check-backlog findings #…)`. A candidate that fails the checker leaves
the finding open; nothing is written.

## 7. Post-fix review

After a structural write: regenerate the current view (step 2), then **one** more critic call —
`SCOPE` = the changed and new **live** Task ids (a Task withdrawn by the fix is history, not
re-graded), all rules, `ROUND: 2`, `PRIOR` = the applied findings. Unresolved findings are
reported; never a third round.

## 8. Codex (optional)

Runs when `command -v codex` succeeds; never a condition of the verdict; the user may skip it with a
reason, recorded in the report. Absent → one line "Codex: skipped — not on PATH".

## 9. Report

Per rule: kept / dropped; fixes applied (with the `D-n`); open findings; checker warnings verbatim;
the verdict `ship | revise | rethink`.

## 10. Record

Write the backlog header line (create it under the header when absent; replace it when present):

```
**Last check:** YYYY-MM-DD · scope: all | E2 | since D-4 · verdict: ship | revise | rethink · backlog sha256: <12 hex>
```

The hash is **canonical** — the backlog without its own `**Last check:**` line, computed after
every write of this run, so writing the line does not invalidate it:

```bash
grep -v '^\*\*Last check:\*\*' .agents/backlog.md | shasum -a 256 | cut -c1-12
```

`/prime-ba` recomputes it the same way; a different value means the backlog changed since the check.
A partial scope never reads as a whole-backlog `ship`.

---

## Notes

- Not folded into `/setup:create-backlog` — the backlog changes for months after creation; run this
  after each `/update-backlog` (`--since D-k`) and before each `/jira draft`.
- The critic never writes; this command never writes outside the `/update-backlog` apply phases and
  the `**Last check:**` line.
