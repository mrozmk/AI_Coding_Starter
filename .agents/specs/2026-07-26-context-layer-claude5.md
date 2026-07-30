# Design: Always-loaded context layer for Claude 5 generation models

**Date:** 2026-07-26
**Status:** Approved
**External docs required:** no

## Summary

Shrink the template's always-loaded context layer — the seed `CLAUDE.md`, the
`CLAUDE-template.md` it is generated from, and the generator's instructions — from 231 lines to
~130, and settle the routing conflict between `.agents/memory/` and Claude Code's native per-user
auto-memory. Driven by Anthropic's "The new rules of context engineering for Claude 5 generation
models": progressive disclosure, no repetition across surfaces, principle-based guidance instead of
binary rules.

## Problem

`CLAUDE.md` is loaded into every conversation of every project bootstrapped from this template, so
its cost is paid per session, per project, forever. Three defects:

1. **It violates its own generator's cap — twice over.** `create-CLAUDE_MD.md:183` mandates ≤200
   lines and `.claude/templates/CLAUDE-template.md:5` repeats the same cap; the seed is 231 lines
   and the template itself is 233. The cap has never bound anything.
2. **Roughly half of it is repetition.** The `Memory — routing discoveries` table is a 1:1 duplicate
   of `.agents/memory/index.md → Quick Reference`. `On-Demand Context` is a second pointer table
   next to the same file. `Proactive Agent Usage` restates `.claude/agents/*.md` frontmatter, which
   Claude Code already injects into the system prompt. The git three-tier enumeration restates
   `.claude/settings.json`. The `/orchestrate` push-model paragraph summarizes
   `.agents/reference/parallel-orchestration.md`, which it also links.
3. **Two memory surfaces now contend.** Claude Code's harness instructs the model to write to a
   native per-user memory directory; `CLAUDE.md` routes the same discoveries to `.agents/memory/`.
   Nothing has ever been written to the native directory (it does not exist on disk), so there is no
   migration problem — but the conflicting instruction is live and unresolved.

The root cause of (1) and (2) is a missing rationale: `create-CLAUDE_MD.md` lists ten mandatory
sections but never says **why** they are mandatory. Successive passes therefore treated each heading
as an invitation to explain, rather than as a named anchor other files depend on.

## Solution

**Cut vertically, not horizontally.** Some `CLAUDE.md` headings are a contract — commands and hooks
address them by name, so renaming or deleting one breaks a consumer silently.

### Contractual anchors — heading text is load-bearing, must not change

Consumers reference these headings in **four** syntactic forms, and any audit that matches fewer
than all four under-reports:

| Form | Example |
|---|---|
| arrow pointer | `CLAUDE.md → Validation` |
| backtick-quoted | `` `CLAUDE.md` → Security `` |
| markdown link + name | `[CLAUDE.md](../../CLAUDE.md) Git Workflow` |
| bare heading literal | `` `## Project Knowledge Layers` `` |

| Anchor | Consumers |
|---|---|
| `Language Rules` | `prime-ba.md:124,130,140`, `recon.md:176`, `brainstorm.md:195,357`, `plan-feature.md:698,712,956`, `stack-research.md:131,236`, `test-e2e.md:216`, `index.md:84` |
| `Code Navigation` | `hooks/nudge-lsp.sh:42` (`grep -q`, **substring** — the generator emits `## Code Navigation (LSP)`, so the contract is the phrase, not the full heading), `plan-feature.md:64`, `execute.md:34`, `brainstorm.md:61` |
| `Validation` | `orchestrate.md:646`, `plan-feature.md:291`, `gates/verify-implementation.md:62`, `check-implementation.md:168`, `brainstorm.md:272`, `reference/parallel-orchestration.md:113` |
| `Commands` + `Code Structure & Modularity` | `gates/check-quality.md:13` — reads both sections by name |
| `Style & Conventions` | `plan-feature.md:63` |
| `Tech Stack` | `plan-feature.md:58` |
| `Automatic Behaviors` | `.agents/memory/index.md:31` |
| `Search Commands` | `release.md:71,136` — anchor link `#search-commands` |
| `Security` | `recon.md:80` — backtick form |
| `Git Workflow` | `orchestrate.md:635` — markdown-link form, cites the force-remove guard |
| `Project Knowledge Layers` | `createwikillm.md:249` — **inserts a row into this table**; a structural dependency, not just a pointer |

That is **eleven unconditional exact headings plus one conditional substring contract**
(`Code Navigation`, which the generator emits only for LSP projects and as `## Code Navigation
(LSP)`). Twelve heading strings in total — an earlier draft called the whole set "eleven" and
conflated the two kinds.

**Consequence for the generator's mandatory-section list:** it currently names only
`Language Rules`, `Code Structure & Modularity`, `Error Handling`, `Security`, `Git Workflow`,
`Project Knowledge Layers`, `Automatic Behaviors`, `Search Commands` (plus the two being removed).
`Validation`, `Commands`, `Style & Conventions`, and `Tech Stack` are contractual but **absent from
that list**, so a future generation could legally drop them. All eleven unconditional anchors, plus
policy-retained `Error Handling`, must be in both mandatory lists.

### Retained on policy grounds — no referent, kept because the rule matters

`Error Handling` only. Earlier drafts of this spec got this set wrong twice, in both directions —
first over-claiming four headings as contractual, then wrongly demoting `Security`, `Git Workflow`,
and `Project Knowledge Layers` to policy-only because the audit regex matched a single reference
form. Trim its prose; keep its rule.

Those headings survive; the prose beneath them is compressed to a rule plus a pointer. Only sections
with **zero** referents and no independent rule are deleted outright.

### Verification command — ship this, do not re-derive it

**Search from the headings outward, not from the pointers inward.** Enumerating pointer syntaxes is
what failed twice; a heading that no known syntax matches is invisible. Inverting the search — take
every heading `CLAUDE.md` actually has, look for its literal text anywhere in the harness — cannot
miss a reference form, and its false positives are harmless: keeping an unneeded heading costs one
line, deleting a needed one breaks a consumer with no error. The asymmetry decides the design.

Two details are load-bearing and were both wrong in an earlier draft:

- **`--glob` options must precede `--`.** After `--`, ripgrep treats them as *paths*: it emits
  `rg: --glob: No such file or directory` and silently applies no exclusion, so templates and specs
  get counted. Verified by execution.
- **Sweep the union of baseline and candidate headings.** Reading only the post-edit file can never
  flag a heading you just deleted — which is the single failure this gate exists to catch.

Do **not** suppress stderr here. Hiding `2>/dev/null` over this command is what concealed the broken
globs.

```bash
# Union of headings before and after the edit; flag any that is referenced but no longer present.
{ git show HEAD:CLAUDE.md; cat CLAUDE.md; } | rg -o '^## (.+)$' -r '$1' | sort -u |
while IFS= read -r h; do
  n=$(rg -l -F --glob '!**/templates/**' --glob '!**/create-CLAUDE_MD.md' \
        --glob '!**/starter-sync-playbook.md' --glob '!**/specs/**' --glob '!**/plans/**' \
        -- "$h" .claude/ .agents/ | wc -l | tr -d ' ')
  present=$(rg -c "^## $h\$" CLAUDE.md || echo 0)
  printf '%-32s refs:%-3s inSeed:%s\n' "$h" "$n" "$present"
  [ "$n" -gt 0 ] && [ "$present" -eq 0 ] && echo "  🔴 DELETED BUT REFERENCED — restore it"
done
rg -n 'CLAUDE\.md' .claude/hooks/          # hooks that read the file directly
```

Any heading reported with a non-zero count must exist verbatim in both `CLAUDE.md` and
`.claude/templates/CLAUDE-template.md`. Baseline run on the unmodified repo returns `refs:0` for
exactly `Proactive Agent Usage`, `Plan Mode`, `On-Demand Context`, and `Project Overview` — the first
three are the planned deletions; `Project Overview` is a placeholder that stays.

Memory scope is settled in favour of the repository: `.agents/memory/` stays the single memory
surface. It is committed, reviewable in a PR, visible to CI, and portable across tools and models —
which is the template's reason to exist. The native per-user directory is invisible to everyone but
its owner, so knowledge written there would silently leave the project.

### Rejected alternatives

- **Extract harness self-documentation to `.agents/reference/harness.md`.** Creates a file nobody
  has a reason to open, and duplicates `settings.json` a second time. Adopted only for the
  backlog→Jira rule, which has real owners (see Files).
- **Convert harness doctrine to a Skill.** Skills describe procedures to run; this is background
  doctrine. A skill's description loads unconditionally anyway, so the saving is illusory.
- **Make native auto-memory canonical** (closest to the article's rule 5). Rejected: it moves
  project knowledge out of the repo, where the team, CI, and other tooling cannot reach it.

## Architecture

Four surfaces change, each keeping its existing role. The first three are **one coupled change** —
patching any subset leaves the template self-contradictory:

- **`CLAUDE.md` (seed, 231 lines)** — rules, conventions, policies, pointers. Never maps, never
  mechanics. What this repo itself uses.
- **`.claude/templates/CLAUDE-template.md` (233 lines)** — the artifact the generator actually
  copies from (`create-CLAUDE_MD.md:179`). It carries its **own** `≤200` cap (line 5) and its **own**
  mandatory-section list (lines 13–14, including `Proactive Agent Usage` and `Plan Mode`). Slimming
  the seed without slimming this file means `/setup:create-CLAUDE_MD` regenerates the verbose
  structure in every new project — i.e. the change would not propagate at all, which is the whole
  point in a template repo.
- **`create-CLAUDE_MD.md`** — the generator's instructions. Gains the missing rationale so the cap is
  self-enforcing rather than aspirational.
- **`.agents/memory/index.md`** — already the memory routing authority. Gains memory *scope*
  alongside memory *routing*.

The seed and the template are **deliberately not identical** and must not be forced into identity:
the template is a superset carrying `## Testing` and `## Notes`, orders its sections differently
(`Language Rules` sits after `Git Workflow`, not near the top), and keeps `{communication-language}`
unsubstituted. The invariant to preserve is narrower: **the same contractual anchor set, the same
cap, the same mandatory-section list, and the same cut applied to every section they share.**

Detail evicted from `CLAUDE.md` returns to the file that already owns it. Nothing is invented as a
new home except where an owner genuinely exists:

| Evicted content | Returns to |
|---|---|
| Memory routing table | `.agents/memory/index.md → Quick Reference` (identical table already there) |
| Git three-tier command enumeration | `.claude/settings.json` (the executable source of truth) |
| `/orchestrate` push model | `.agents/reference/parallel-orchestration.md` (already linked) |
| `guard-memory.sh` mechanics | `.claude/hooks/guard-memory.sh`, `.claude/memory-domains.json` |
| Agent roster | `.claude/agents/*.md` frontmatter (injected into the system prompt) |
| Plan-mode 99% protocol | `.claude/commands/analysis.md` |
| Backlog → Jira direction rule | `.claude/commands/setup/create-backlog.md`, `.claude/skills/jira/SKILL.md` |

### Cut plan

Line ranges are from the current 231-line seed. **The same cut applies to the body of
`.claude/templates/CLAUDE-template.md`**, whose line numbers are offset by its ~20-line guidance
preamble; work from the section headings there, not from these numbers.

**Structural cuts** — deletions and rewrites:

| Section | Lines | Now | After | Δ | Action |
|---|---|---|---|---|---|
| Starter-kit note | 1–8 | 8 | ~4 | −4 | compress |
| Project Knowledge Layers *(incl. the routing subsection below)* | 137–174 | 38 | ~12 | −26 | keep the layer table, drop three blockquotes |
| ↳ *of which* Memory — routing discoveries | 160–174 | 15 | **0** | — | delete — exact duplicate of `index.md → Quick Reference` |
| Git Workflow | 118–136 | 19 | ~10 | −9 | keep `deny > ask > allow` precedence, drop per-tier command lists |
| Automatic Behaviors | 175–190 | 16 | 16 | **0 lines / −724 chars** | `guard-memory` bullet is ONE physical line of 874 chars → shrink to ~150 chars. All 9 bullets survive, so the section cannot lose lines. |
| Proactive Agent Usage | 191–200 | 10 | **0** | −10 | delete — zero referents |
| Plan Mode | 201–206 | 6 | **0** | −6 | delete — zero referents |
| Search Commands | 207–217 | 11 | ~5 | −6 | keep heading verbatim, drop example block |
| On-Demand Context | 218–231 | 14 | **0** | −14 | delete — zero referents, duplicate pointer table |

Structural subtotal: **−75 lines** (the Automatic Behaviors row contributes characters, not lines).

> **Lines are a weak proxy here — characters are the real cost.** The seed averages 71 chars/line and
> contains a single 874-char line; the template averages 42. An earlier draft of this table conflated
> *rendered* lines with *physical* ones and overstated the savings. Treat every "after" figure as an
> estimate, and gate on the two hard numbers at the end of this section instead.

**Light trims** — prose tightening, no structural change; each keeps its heading and its rule:

| Section | Lines | Now | After | Δ |
|---|---|---|---|---|
| Language Rules | 15–27 | 13 | ~8 | −5 |
| Code Structure & Modularity | 81–93 | 13 | ~8 | −5 |
| Error Handling | 100–108 | 9 | ~6 | −3 |
| Security | 109–117 | 9 | ~6 | −3 |
| Architecture | 73–80 | 8 | ~6 | −2 |

Trim subtotal: **−18**.

**Untouched:** `Project Overview` (6), `Commands` (18), `Validation` (19), `Tech Stack` (8),
`Style & Conventions` (6). `Validation` is the densest load-bearing block in the file — read by
`plan-feature` and the gates — and is explicitly out of scope for trimming.

### Targets — two numbers, and the second is the one that matters

| Metric | Now | Target | Role |
|---|---|---|---|
| Lines | 231 | **≤150** | the cap, because three files already declare a line cap and consumers expect one |
| Characters | 16 504 | **≤9 500** (≈−42%) | the real cost — what the model actually pays per session |

Estimated landing: ~147 lines / ~8 000 chars. The line cap is tight but reachable; if a choice
arises, **characters win** — a 149-line file that is still 15 000 chars has not solved the problem,
while a 152-line file at 8 000 chars has.

**The cap must become executable, not declarative.** Today `≤200` is asserted in two files and
enforced nowhere, which is exactly why the seed drifted to 231. Moving the number to `≤150` repeats
that mistake unless the generator gains a real post-generation gate — it must `wc -l` and `wc -c` the
file it just wrote, push detail into memory files and re-check while over, and report explicitly if a
mandatory rule makes compliance impossible. A number without a gate is a comment.

## Files

- **Modified:** `CLAUDE.md` — vertical cut per the table above. In `Project Knowledge Layers`, a
  **one-line pointer** to `index.md → Memory scope` — a pointer, not a restatement of the rule. It
  lives here (rather than only in `index.md`) because the rule must hold in a session that never ran
  `/prime`; `CLAUDE.md` is the only always-loaded surface.
- **Modified:** `.claude/templates/CLAUDE-template.md` — the same cut applied to the body, plus:
  cap `≤200` → `≤150` (line 5), and `Proactive Agent Usage` / `Plan Mode` dropped from the mandatory
  list (lines 13–14), plus the four contractual headings that list never protected. Must end with the
  **same contractual anchor set and the same cut on shared sections** as the slimmed seed — *not*
  structurally identical to it: the template stays a superset by exactly `Testing` and `Notes`, keeps
  its own section order, and keeps its `{communication-language}` placeholders.
- **Modified:** `.claude/commands/setup/create-CLAUDE_MD.md` — **an executable post-generation cap
  gate** in Phase 3/4 (`wc -l` + `wc -c` the generated file, push detail into memory files while over
  budget, report explicitly if a mandatory rule blocks compliance). Today the command runs straight
  from generation to its success report (lines 291–334) with no size check, which is why the declared
  cap has never bound anything. Plus: cap `≤200` → `≤150` (line 183);
  `Proactive Agent Usage` and `Plan Mode` removed from the mandatory list (lines 201–211); the list
  gains a per-section prose budget and its **inlined** rationale: the exact anchor names, why they
  are mandatory (consumers address them by name), and the verification command from the Solution
  section. The rationale must be **self-contained** — it may not cite this spec, because
  `.agents/specs/` is category C and never ships to downstream projects
  (`starter-sync-playbook.md:61–67`), so a generator that pointed at it would dangle everywhere but
  here.
- **Modified:** `.agents/memory/index.md` — new `## Memory scope` section holding the **full** rule:
  `.agents/memory/` is the only memory surface for this project; do not write to the native per-user
  memory directory, since knowledge outside the repo is invisible to the team and to CI.
- **Modified:** `.claude/commands/setup/create-backlog.md` — absorbs the backlog-is-source-of-truth
  rule.
- **Modified:** `.claude/skills/jira/SKILL.md` — absorbs the one-way direction rule, **scoped**: it
  governs *delivery-order mirroring* via `/jira bulk` **when `.agents/backlog.md` exists**, and
  forbids reconstructing backlog ordering from Jira. It must not read as a global invariant — the
  backlog is optional (`CLAUDE.md:146`) and the skill's standalone create/update/search/comment/link/
  transition flows (`SKILL.md:76–259`) remain fully supported without one.

## External dependencies

None — all changes are internal to the template. No library, API, or service is involved.

## Edge Cases

- **Silent breakage of a section referent.** Deleting or renaming a heading something points at
  fails without an error. Before finalizing, run the verification command in Solution → *Verification
  command* against **both** `CLAUDE.md` and `.claude/templates/CLAUDE-template.md`; any heading it
  names must keep its exact text in both files. **Sweep from the headings outward**, and accept the
  false positives that come with literal matching — they only ever cause you to keep a heading. The
  opposite bias, matching explicit pointer syntaxes only, is what produced two wrong anchor sets
  during design.
- **Seed and template drifting apart.** They are near-identical today (231 vs 233 lines) and nothing
  enforces that. If only one is cut, `/setup:create-CLAUDE_MD` silently reintroduces the verbose
  structure. Implementation must verify the **narrowed** invariant after the change — same anchor
  set, same cap, same mandatory list, same cut on shared sections — and confirm the section-set diff
  still shows the template as a superset by exactly `{Testing, Notes}`. Do **not** diff the two
  bodies for equality; they are deliberately different documents.
- **`nudge-lsp.sh` greps the literal string `Code Navigation`.** That section is conditional and
  absent from the seed. Do not introduce it, and do not rename it in the generator.
- **`release.md` links `#search-commands`.** The heading must remain exactly `## Search Commands` —
  GitHub-style anchor generation is case- and punctuation-sensitive.
- **Rollout differs per surface — this is not a uniform "new projects only" change.** An earlier
  draft claimed existing downstream projects were entirely unaffected; that is false for
  `index.md`. Exact behaviour on the next `/maintain:sync-from-starter`:

  | Surface | Sync category | Reaches an existing project? |
  |---|---|---|
  | `CLAUDE.md` | C — never overwritten (`sync-from-starter.md:133`) | **No.** New projects only. |
  | `.claude/templates/CLAUDE-template.md` | A | Yes — but only takes effect if the project re-runs `/setup:create-CLAUDE_MD` |
  | `.claude/commands/setup/create-CLAUDE_MD.md` | A | Same as above |
  | `.agents/memory/index.md` | **B — merged** (`starter-sync-playbook.md:55`: overwrite with starter structure, restore project-specific `When to Read` rows) | **Yes, immediately.** |

  The `Memory scope` section therefore propagates to existing projects on their next sync, ahead of
  any regeneration. **Accepted deliberately**, not worked around: it is a one-way policy statement,
  inert in any project that never wrote to native memory (no project has — the directory does not
  exist here), and it is precisely the kind of rule that should reach existing projects rather than
  wait for a bootstrap that will never happen. Implementation must place it as a distinct
  `## Memory scope` section so the category-B merge carries it as starter structure, not as a
  project-specific row that restore-logic could drop.
- **Agent roster removal assumes Claude Code.** The roster is dropped from `CLAUDE.md` because the
  harness injects `.claude/agents/*.md` frontmatter into the system prompt. A different runner would
  not. Accepted: the template targets Claude Code.
- **`decisions.md` cannot absorb the backlog rule.** It is a pristine, deliberately empty template
  file (reset in commit `35b23ae`); writing project decisions into it would break the template's
  clean-slate contract. Hence the rule goes to the commands that enforce it.

## Out of Scope

- `guard-memory.sh` hard-block → nudge (tracked separately as item 4).
- Directive density in `orchestrate.md` (83) and `plan-feature.md` (81) (item 5).
- Verification rubrics emitted by `/plan-feature` (item 6).
- Any change to `Validation`, `Commands`, or the `.agents/` directory layout.
- **The `createwikillm` column mismatch.** Auditing the `Project Knowledge Layers` structural
  contract surfaced a pre-existing defect: `createwikillm.md:249–255` inserts a **5-cell** row into a
  **4-column** table, so `/setup:createwikillm` produces a malformed table today. A draft of the plan
  bundled the fix here; it was removed as scope creep — the defect predates this feature, nothing
  here worsens it, and `createwikillm.md` is sync category A, so fixing it would push an unrequested
  behavior change into every existing downstream project. **Track separately.** Correct the consumer
  (emit 4 cells), never widen the table — widening inflates the always-loaded file this feature
  exists to shrink, and would have to be mirrored into the template.
- Actively migrating existing downstream projects. Their `CLAUDE.md` is left alone by design; the
  `index.md` memory-scope section reaching them via category-B sync is a documented, accepted
  consequence (see Edge Cases), not a migration.
