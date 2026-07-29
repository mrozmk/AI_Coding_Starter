---
status: populated
description: Memory-reflection protocol + entry-format templates + domain-file template — loaded only by reflection callers, never by /prime
---

# Memory Reflection Protocol & Templates

> **Not a `/prime` file.** Loaded **only** by the reflection callers — [`/execute`](../../.claude/commands/execute.md), [`/check-implementation`](../../.claude/commands/check-implementation.md), [`/orchestrate`](../../.claude/commands/orchestrate.md) — at the end of a completed unit of work, and by anything that needs to create a `domain/` file. For routing (*what to write where* / *what to read when*) see [index.md](index.md), which every session loads.
>
> The split exists because `/prime` reads `index.md` in **every** session while this protocol matters in a handful of turns at the very end of a run. Keeping it here is the [Loader Convention](index.md#loader-convention--prime-loads-commands-trust) applied to memory itself.

---

## The reflection pass — when it runs

It runs at the end of a **completed unit of work**, never mid-task:

| Caller | When | Source it reflects on |
|--------|------|-----------------------|
| [`/orchestrate`](../../.claude/commands/orchestrate.md) | Phase 7, **friction-gated** — only when the run-log shows a step needed >1 fix iteration, an escalated blocker the user resolved via guidance, or a designer mega-fix. A clean run (everything passed first try) learns nothing → skip. | the durable run-log |
| [`/check-implementation`](../../.claude/commands/check-implementation.md) | after the final report | the loop's first-hand context — bugs `/code-review` fixed, gate iterations |
| [`/execute`](../../.claude/commands/execute.md) | after moving the plan to `done/`, **only if no `/check-implementation` or `/orchestrate` follows** (else those reflect instead) | what was just implemented |

There is no `/remember` command. Manual capture still works: ask Claude to save it to memory — in the project's communication language (CLAUDE.md → Language Rules) — and follow the routing in [Quick Reference in index.md](index.md#quick-reference--where-to-write-discoveries).

---

## The bar — precision over recall

**Bloated memory is worse than no memory.** Save **only** if a fresh Claude would get it **wrong** without the note. **The default outcome is to save nothing.**

Do NOT save:

- routine edits, or anything visible by reading the code, git history, or `CLAUDE.md`
- "the feature works now" / a restatement of the plan
- a lesson with no actionable takeaway
- **anything already captured** — before appending, scan the target file's latest entries; if the lesson is already there (e.g. an earlier caller in the same flow saved it), add nothing. This is the de-dup guard for flows with two reflection points (`/execute` → `/check-implementation`).

Save when — and only when — the run produced one of:

| Discovery | Target file |
|-----------|-------------|
| Non-obvious bug root-cause + fix | `errors.md` |
| Undocumented API / protocol quirk | `api.md` |
| Deliberate X-over-Y decision + rationale | `decisions.md` |
| Reusable project-specific pattern | `patterns.md` |
| Knowledge specific to one module | `domain/{module}.md` |

If unsure between two files, pick the most specific. If a `domain/` file doesn't exist yet, create it from the template below.

If nothing clears the bar — the common case — write nothing and report one line: `Nothing worth remembering from this run.`

---

## Format — append newest-first, never reformat existing entries

Append-mode files put the **newest entry at the TOP**. Never rewrite or re-order what is already there.

**errors.md / api.md / patterns.md / domain/{module}.md:**

```markdown
## [YYYY-MM-DD] {Short title}

{What happened or was discovered}

**Rule:** {Actionable takeaway — what to do or avoid next time}
```

**decisions.md:**

```markdown
## [YYYY-MM-DD] {Decision title}

**Chosen:** {what was chosen}
**Rejected:** {alternatives considered}
**Why:** {rationale}
**Consequences:** {what this affects going forward}
```

If a discovery is one of the project's most important "always check this" lessons, also add a one-liner to [Quick Reference in index.md](index.md#quick-reference--where-to-write-discoveries) (keep it ≤7 items).

---

## Domain File Template

When creating a file in `domain/` for a specific module or subsystem:

```markdown
---
status: populated
description: {one-line — what this module does and why this memory exists}
---

# Memory: {module_name}

{One-line summary of what this module does}

**Source:** `{path/to/module}`

---

## Key Logic
- {non-obvious rule 1}
- {non-obvious rule 2}

## External Contracts
- {field / endpoint / config key} — {what it represents here}

## Known Edge Cases
- {scenario} → {behavior}

## Related Decisions
- See [../decisions.md](../decisions.md) entry: {date} — {title}
```

After creating one, add its row to the `When to Read` table in [index.md](index.md) so later sessions know when to load it.
