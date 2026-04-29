---
description: All-in-one AI workflow housekeeping — broken-reference check, memory pruning to archive, workflow health warnings
---

# /cleanup-workflow — AI Workflow Maintenance

Three-phase housekeeping for the `.claude/` + `.agents/` workflow. Run this when the project's been moving fast and you want to make sure references aren't broken, memory hasn't bloated with stale entries, and orphaned artifacts are surfaced.

**Always runs all three phases sequentially. No skip arguments.** If you only want a fast pre-commit reference check, that's still cheap as Phase 1 — just stop the run after Phase 1 if you don't want to continue.

---

## Phase 1: Reference Integrity Check

**Goal:** find broken refs that point at files / sections / commands / tools that no longer exist.

**Scope — 5 detection categories** (run all, fast, no user judgment needed):

### 1.1 Markdown links — `[text](path)`

```bash
rg -n '\[([^\]]+)\]\(([^)]+)\)' --glob '*.md' --glob '!node_modules' --glob '!.git'
```

For each match:
- Skip URLs starting with `http://`, `https://`
- Skip anchor-only `#section`
- Skip empty `()`
- For `path#anchor`, strip `#anchor` — only verify file exists
- Resolve relative to source file's directory; absolute paths from project root
- Check existence via `rg --files` or `ls`

### 1.2 Path refs in inline code — `` `<path>` ``

```bash
rg -n '`([./][^`]+\.(md|json|toml|yaml|yml|py|ts|tsx|js|jsx))`' --glob '*.md'
rg -n '`(\.agents/[^`]+)`'                                       --glob '*.md'
rg -n '`(\.claude/[^`]+)`'                                       --glob '*.md'
rg -n '`(docs/[^`]+)`'                                           --glob '*.md'
```

Same skip / resolution / existence rules as 1.1.

### 1.3 Section anchors in prose — `"<file> → <section>"`

```bash
rg -n '([A-Z][A-Za-z_-]*\.md)\s*→\s*([A-Z][A-Za-z &\-]+)' --glob '*.md'
rg -n '([A-Z][A-Za-z_-]*\.md)\s*`([A-Za-z &\-]+)`'         --glob '*.md'
```

For each match, capture `(file, section)`. Verify:
1. The file exists.
2. A heading `## <section>` or `### <section>` exists in that file:
   ```bash
   rg -n '^#+\s+<section>' <file>
   ```
   Match is case-insensitive and tolerates trailing punctuation.

### 1.4 Slash command references — `` `/<command>` `` in prose

```bash
rg -n '`(/[a-z][a-z0-9-]*)`' --glob '*.md'
```

For each match, verify file `.claude/commands/<command>.md` exists.

Skip these built-in non-command tokens (they look like commands but are part of CLI grammar): `/help`, `/init`, `/clear`, `/config`, `/login`, `/logout`, `/cost`, `/status`, `/release-notes`, `/exit`.

### 1.5 MCP / skill tool references — `` `mcp__*` ``

```bash
rg -n '`(mcp__[a-z_]+__[a-z_]+)`' --glob '*.md'
```

For each match, verify the tool name exists in:
- The MCP tool listing of the current session (if available)
- OR `.mcp.json.example` (look for the MCP server name as a hint)
- OR `.claude/skills/<name>/` directory

If none, flag as "MCP tool not configured in this project" (warning, not blocker — user may have it set up locally).

### 1.6 Phase 1 output

```markdown
📎 Reference Integrity — <N> markdown files scanned

❌ MARKDOWN LINKS broken (<count>):
   <source>:<line>
     [<text>](<original>) → tried <resolved>
     Suggestion: <basename match if exactly one> | brak | niejednoznaczne: <candidates>

❌ PATH REFS broken (<count>):
   <source>:<line>
     `<path>` — file not found
     Suggestion: <basename match> | brak | niejednoznaczne

❌ SECTION ANCHORS broken (<count>):
   <source>:<line>
     "<file> → <section>" — section heading not found in <file>
     Available headings in <file>: <list of ## headings>

❌ SLASH COMMANDS broken (<count>):
   <source>:<line>
     `/<command>` — no .claude/commands/<command>.md
     Suggestion: <similar command names> | none

❌ MCP REFS broken (<count>):
   <source>:<line>
     `mcp__<name>` — not detected in this project's MCP config
     Hint: check .mcp.json or claude mcp list

✅ <total OK> references valid
```

If zero broken across all 5 categories, output:
```
✅ All references valid (<total> checked across 5 categories).
```

**No auto-fix.** User decides what to repair. Continue to Phase 2 after report.

---

## Phase 2: Memory Pruning

**Goal:** identify stale entries in append-style memory files and offer archiving.

**Files in scope:**
- `.agents/memory/errors.md`
- `.agents/memory/decisions.md`
- `.agents/memory/patterns.md`
- `.agents/memory/api.md`
- `.agents/memory/domain/*.md`

**Skip:** `.agents/memory/archive/**`, regenerated files (`architecture.md`, `project-brief.md`, `domain/business-model.md`).

### 2.1 Identify candidate entries via heuristics

Each memory file is structured as `## <date> — <title>` blocks (per starter convention). Parse each file into entries.

**Heuristic A — date-based:**
- Entry header date is older than **6 months** from today → candidate.

**Heuristic B — code-grounded:**
- Extract path-like tokens from entry body: `src/**/*`, `lib/**/*`, `.agents/**/*`, file names with extensions.
- For each token, check existence with `rg --files`.
- If **all** referenced paths are broken (file moved/deleted) → candidate.
- If **some** broken → soft signal (mention in report but don't auto-flag).

**Both A and B met** → strong candidate (highlighted).
**A or B met** → candidate.
**Neither** → keep silently.

### 2.2 Per-candidate user decision

For each candidate, present:

```
📋 errors.md — entry from 2025-08-14 (8.5 months old)

## 2025-08-14 — Stripe webhook signature verification fails on raw body parsing

[full entry body, max ~20 lines preview]

Heuristics matched:
  ⏰ Date: 8.5 months old (threshold: 6 months)
  🔗 Code refs: src/lib/stripe/webhook.ts → file no longer exists

Action? [k]eep / [a]rchive / [d]elete (rare) / [s]kip-for-now
```

- **Keep** → leave entry in place. Don't ask again this run.
- **Archive** → move to `.agents/memory/archive/<file>-YYYY-MM-DD.md`, append at TOP (newest at top, same convention as live files).
- **Delete** → permanently remove from file (use only for truly worthless entries; warn user).
- **Skip-for-now** → leave entry, but it will reappear in next `/cleanup-workflow` run.

**Default suggestion when uncertain:** archive. It's reversible (entry still in git history + archive file).

### 2.3 Apply archive moves

For each "archive" decision:

1. Ensure `.agents/memory/archive/` exists (create with `.gitkeep` if absent).
2. Append to `.agents/memory/archive/<original-filename>-YYYY-MM-DD.md` (one archive file per source file per archive day — entries from the same source on the same day go into one file). Newest entries at the TOP.
3. Remove the entry from the source file.
4. Add archive header at top of new archive file (only on first creation):
   ```markdown
   ---
   archived_from: errors.md
   archived_on: YYYY-MM-DD
   ---

   # Archived entries from `errors.md`

   > These entries were archived by `/cleanup-workflow` because they were stale (date heuristic and/or code-grounded heuristic). Do not load this file in `/prime` or any agent — it is historical record only.
   ```

### 2.4 Phase 2 output

```markdown
🗂 Memory Pruning — <N> files scanned

Per-file results:
  errors.md:    <kept> kept, <archived> archived, <deleted> deleted, <skipped> skipped
  decisions.md: ...
  patterns.md:  ...
  api.md:       ...
  domain/foo.md:...

New file sizes:
  errors.md:    142 lines (was 287, −51%)
  decisions.md: 89 lines  (was 89, no change)
  ...

Archive created/updated:
  .agents/memory/archive/errors-2026-04-27.md (3 entries)
  .agents/memory/archive/decisions-2026-04-27.md (1 entry)
```

---

## Phase 3: Workflow Health Warnings

**Goal:** surface signals of workflow drift. **No actions** — just flagging.

### 3.1 Signal: `status: empty` stuck longer than 30 days

For each regenerated memory file (`.agents/memory/architecture.md`, `project-brief.md`, `domain/business-model.md`):

```bash
# Check if frontmatter says status: empty
head -10 <file> | grep -q '^status: empty' && \
  git log -1 --format='%ct' -- <file>
```

If `status: empty` AND `now - last_modified > 30 days` → warning:
> ⚠️ `<file>` has `status: empty` and hasn't been touched in <X> days. If your project is past bootstrapping, run the owning command (`/refresh-brief` or `/create-CLAUDE_MD`) to populate it.

### 3.2 Signal: specs without matching done plan

```bash
ls .agents/specs/*.md 2>/dev/null
ls .agents/plans/done/*.md 2>/dev/null
```

For each spec, check whether a plan with a matching topic exists in `plans/done/` or `plans/active/`. Match heuristic: kebab-case topic in filename.

If no match → warning:
> ⚠️ `<spec>` has no matching plan in `plans/active/` or `plans/done/`. Designed but never implemented? Consider closing or running `/plan-feature`.

### 3.3 Signal: stale active plans (>14 days)

```bash
for f in .agents/plans/active/*.md; do
  age_days=$(( ( $(date +%s) - $(git log -1 --format='%ct' -- "$f") ) / 86400 ))
  [ $age_days -gt 14 ] && echo "$f $age_days"
done
```

For each match → warning:
> ⚠️ `<plan>` last touched <X> days ago. Stalled? Either resume with `/execute` or move to `plans/done/` if shipped.

### 3.4 Signal: audit.log size

```bash
[ -f .claude/audit.log ] && wc -l .claude/audit.log | awk '{print $1}'
```

If `> 5000 lines` → warning:
> ⚠️ `.claude/audit.log` has <N> lines (>5000). Consider rotating: `mv .claude/audit.log .claude/audit.log.<date>`. The log is gitignored — local only.

### 3.5 Signal: memory file size thresholds

For each append-style memory file:
- `errors.md` > 500 lines → warning
- `decisions.md` > 500 lines → warning
- `patterns.md` > 500 lines → warning
- `api.md` > 500 lines → warning
- Any `domain/*.md` > 500 lines → warning (excluding `business-model.md` which is regenerated)

> ⚠️ `<file>` is <N> lines. Consider running Phase 2 of `/cleanup-workflow` to prune stale entries (you may have skipped some on the previous run).

### 3.6 Phase 3 output

```markdown
🚦 Workflow Health — <N> signals detected

⚠️ STATUS: EMPTY STUCK (<count>):
   .agents/memory/project-brief.md — empty for 47 days. Run /refresh-brief.
   ...

⚠️ ORPHAN SPECS (<count>):
   2026-03-14-realtime-updates.md — designed but no plan in active/done.

⚠️ STALE ACTIVE PLANS (<count>):
   2026-04-02-auth-rewrite.md — last touched 25 days ago.

⚠️ AUDIT LOG (<count>):
   .claude/audit.log — 7,231 lines. Consider rotating.

⚠️ LARGE MEMORY FILES (<count>):
   errors.md — 542 lines. Consider another /cleanup-workflow pass.

✅ Other signals: clean.
```

If zero warnings:
```
✅ Workflow health clean. No drift signals detected.
```

---

## Final Report

After all 3 phases:

```markdown
# /cleanup-workflow run summary — YYYY-MM-DD

## Phase 1: References
   - Markdown links:    <X> OK, <Y> broken
   - Path refs:         <X> OK, <Y> broken
   - Section anchors:   <X> OK, <Y> broken
   - Slash commands:    <X> OK, <Y> broken
   - MCP refs:          <X> OK, <Y> broken
   Total broken: <N> — fix manually before commit.

## Phase 2: Memory pruning
   <K> entries kept, <A> archived, <D> deleted, <S> skipped.
   Archives: <list of created archive files>.

## Phase 3: Workflow health
   <N> warnings (see details above).

## Next steps
   - Fix Phase 1 broken refs (manual).
   - Address Phase 3 warnings as time permits.
   - Re-run /cleanup-workflow before next major milestone.
```

---

## Rules

- **Use `rg`, never `grep` or `find`.**
- **Phase 1: no auto-fix.** Suggestions only — user repairs manually.
- **Phase 2: archive is the default.** Delete only on explicit user choice.
- **Phase 3: no actions.** Pure signal — let the user decide.
- **Skip `.agents/memory/archive/**`** in all phases (this command never re-processes its own archive).
- **Skip `node_modules`, `.git`, `dist`, `build`** in all file scans.
- **Run order is fixed:** Phase 1 → Phase 2 → Phase 3. User can stop after any phase by interrupting; no resumption — re-run from start next time.
