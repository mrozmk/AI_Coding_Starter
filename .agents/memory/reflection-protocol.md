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
| [`/commit`](../../.claude/commands/commit.md) | Step 9 memory checkpoint — a lightweight pass over what the commit just captured; the bar and de-dup guard below apply in full (an earlier reflection in the same flow usually means there is nothing left to save) | the committed change set |

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
| Non-obvious defect in **application code** — root cause + fix, naming the file | `errors.md` |
| Friction in the **toolchain**: slash command, hook, subagent, MCP, shell/git/CLI, a lying debugging tool, a misread design file / ticket / review comment | `domain/harness.md` |
| Spec / test-runner / Storybook / Playwright / jsdom trap | `domain/testing.md` |
| Undocumented API / protocol quirk | `api.md` |
| Deliberate X-over-Y decision + rationale | `decisions.md` |
| Reusable project-specific pattern | `patterns.md` |
| Knowledge specific to one module | `domain/{module}.md` |

If unsure between two files, pick the most specific. If a `domain/` file doesn't exist yet, create it from the template below.

**`errors.md` is application code only.** Before writing there, check the **Scope** section at the top of that file — the entry must name a source file or symbol of the shipped application. Toolchain friction goes to `domain/harness.md`, test-harness traps to `domain/testing.md`. `guard-memory-scope.sh` nudges on a misroute but does not block.

**Prefer a fix over an entry.** If the friction was a defect in `.claude/` you can repair, repair it. `domain/harness.md` is for what cannot be fixed (shell semantics, vendor tool behaviour) or will recur despite the fix.

If nothing clears the bar — the common case — write nothing and report one line: `Nothing worth remembering from this run.`

---

## Format — append at the END, never reformat existing entries

Append-mode files put the **newest entry at the END**. Never rewrite or re-order what is already there.

**Supersession.** When a later decision overturns an earlier one, do not edit or delete the old entry — prefix its title with `⚠️ SUPERSEDED <YYYY-MM-DD>` and append the new entry linking back. A memory entry outranks an archived plan or spec that says otherwise. Record the **rejected alternative** in the new entry as the trap to avoid re-proposing: an omission is invisible, a named rejection is not.

**errors.md / decisions.md / domain/{module}.md — dated entries:**

```markdown
## YYYY-MM-DD — {Short title}
```

Body fields follow the `## Format` block at the top of each target file (errors: *What failed / Root cause / Fix* · decisions: *Decision / Why / Alternatives considered / Impact* · domain: free-form, ending in a **Rule:** takeaway). The dated em-dash heading is load-bearing: `/maintain:cleanup-workflow` Phase 2A parses `## <date> — <title>` blocks to find stale entries — a differently-shaped heading is invisible to pruning.

**patterns.md / api.md — topical, not dated:** their seed `## Format` blocks group by pattern name / service name. Append under the matching topic heading (or add a new one); don't force a date into the heading.

If a discovery is one of the project's most important "always check this" lessons, also add a one-liner to [Quick Reference in index.md](index.md#quick-reference--where-to-write-discoveries) — keep that table lean (add only true "always check this" rows; when it outgrows ~a dozen, prune one before adding another).

### These log files carry `merge=union`

`.gitattributes` declares the built-in `union` merge driver for the append-mode logs (`errors.md`, `decisions.md`, `patterns.md`, `api.md`, `domain/*.md`, `archive/**`). That is why two branches whose reflection passes both appended an entry merge cleanly instead of conflicting. Two consequences you own:

- **"Never reformat existing entries" is load-bearing, not stylistic.** Union emits **no conflict markers**. If two branches change the *same existing line* differently, both versions survive into the merged file and nothing flags it — a silent duplicate that only a reader will ever catch. Appending is always safe; editing what is already there is not.
- **After a merge, entries appear ours-then-theirs, not in date order.** Union concatenates by merge side, not by timestamp, so two entries written on concurrent branches can sit a few days out of order at the top. Expected and cosmetic — reorder by hand if it bothers you, or leave it.
- **First population of a placeholder is an in-place rewrite, not an append.** A `domain/` file shipped or created with `status: empty` frontmatter flips that line and replaces its placeholder description when it gets its first real content — and it sits in the union set. Two parallel branches populating the same placeholder merge with exit 0 into corrupt frontmatter (duplicated `---` delimiters, two `description:` lines), and a mangled `status:` line can make the Skip rule treat the file as an empty placeholder forever. Populate a placeholder only on an up-to-date branch and merge that commit on its own — the same discipline `/maintain:cleanup-workflow` requires for pruning.

Files that are *edited or regenerated in place* — including this one — are deliberately excluded from `union` and keep git's normal 3-way merge. The exclusion block in `.gitattributes` says which and why.

---

## Domain File Template

When creating a file in `domain/` for a specific module or subsystem:

```markdown
---
status: populated
description: {one-line — what this module does and why this memory exists}
created: YYYY-MM-DD   # cleanup-workflow 2B measures idle time from this
pinned: false         # true = never proposed for archival
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
