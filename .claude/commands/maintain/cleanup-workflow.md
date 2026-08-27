---
description: All-in-one AI workflow housekeeping — broken-reference check, memory pruning to archive, workflow health warnings
---

# /maintain:cleanup-workflow — AI Workflow Maintenance

Four-phase housekeeping for the `.claude/` + `.agents/` workflow. Run this when the project's been moving fast and you want to make sure references aren't broken, memory hasn't bloated with stale entries, orphaned artifacts are surfaced, and the workflow tooling itself hasn't drifted.

**Always runs all four phases sequentially. No skip arguments.** If you only want a fast pre-commit reference check, that's still cheap as Phase 1 — just stop the run after Phase 1 if you don't want to continue.

---

## Phase 1: Reference Integrity Check

**Goal:** find broken refs that point at files / sections / commands / tools that no longer exist.

**Scope — 6 detection categories** (run all, fast, no user judgment needed):

### 1.1 Markdown links — `[text](path)`

```bash
rg -n --hidden '\[([^\]]+)\]\(([^)]+)\)' --glob '*.md' --glob '!node_modules' --glob '!.git'
```

For each match:
- Skip URLs starting with `http://`, `https://`
- Skip anchor-only `#section`
- Skip empty `()`
- For `path#anchor` resolving to an `.md` file **inside the repo**, verify the anchor too — against the target file's **heading slugs**: lowercase the heading, replace spaces with hyphens, drop everything that is not a letter, digit or hyphen (`## Search Commands` → `search-commands`). Anything else — external URLs, non-Markdown targets — keeps strip-and-skip: drop `#anchor`, verify only that the file exists.
  - Two headings that slug identically resolve to the first and pass, matching GitHub's own behaviour. Do not report collisions.
- Resolve relative to source file's directory; absolute paths from project root
- Check existence via `rg --files` or `ls`

### 1.2 Path refs in inline code — `` `<path>` ``

```bash
rg -n --hidden '`([./][^`]+\.(md|json|toml|yaml|yml|py|ts|tsx|mts|cts|js|jsx|mjs|cjs|sh))`' --glob '*.md'
rg -n --hidden '`(\.agents/[^`]+)`'  --glob '*.md'
rg -n --hidden '`(\.claude/[^`]+)`'  --glob '*.md'
rg -n --hidden '`(docs/[^`]+)`'      --glob '*.md'
```

Same skip / resolution / existence rules as 1.1.

### 1.3 Section anchors in prose — `"<file> → <section>"`

```bash
rg -n --hidden '([A-Z][A-Za-z_-]*\.md)\s*→\s*([A-Z][A-Za-z &\-]+)' --glob '*.md'
rg -n --hidden '([A-Z][A-Za-z_-]*\.md)\s*`([A-Za-z &\-]+)`'         --glob '*.md'
rg -n --hidden '`([A-Z][A-Za-z_-]*\.md)`\s*→\s*`?([A-Z][A-Za-z-]*(?:\s+(?:&\s+)?[A-Z][A-Za-z-]*){0,4})' --glob '*.md'
```

The third line covers the **backticked filename form** — `` `CLAUDE.md` → Validation `` — which the first two cannot see. The forms are disjoint by construction: a backtick sits between `.md` and `→` in the new one, so no reference is counted twice. Two filters keep the widening from producing noise:

- **The section capture takes at most five Title-Case tokens and stops before the first lowercase token**, bounded in the pattern rather than trimmed afterwards. Real references trail the section name with explanation — `` `CLAUDE.md` → Validation test policy ``, `CLAUDE.md → Style & Conventions rather than guessing` — and a Title-Case test applied to the whole capture would discard them, trading one blind spot for another.
- **The captured file must exist** (rule 1 below), which drops `` `DESIGN.md` → extract palette `` — an arrow used as prose about a file fetched from someone else's repo, not a section reference.

For each match, capture `(file, section)`. Verify:
1. The file exists.
2. A heading `## <section>` or `### <section>` exists in that file:
   ```bash
   rg -n '^#+\s+<section>' <file>
   ```
   Match is case-insensitive and tolerates trailing punctuation.

### 1.4 Slash command references — `` `/<command>` `` in prose

```bash
rg -n --hidden '`(/[a-z][a-z0-9-]*(:[a-z][a-z0-9_-]*)?)`' --glob '*.md'
```

For each match, verify the command file exists: bare `/name` → `.claude/commands/<name>.md`; namespaced `/ns:name` → `.claude/commands/<ns>/<name>.md`.

Skip these built-in non-command tokens (they look like commands but are part of CLI grammar): `/help`, `/init`, `/clear`, `/config`, `/login`, `/logout`, `/cost`, `/status`, `/release-notes`, `/exit`. Also skip skills bundled with Claude Code itself (they resolve without a file in this repo): `/code-review`, `/review`, `/security-review`, `/simplify`.

### 1.5 MCP / skill tool references — `` `mcp__*` ``

```bash
rg -n --hidden '`(mcp__[a-z_-]+__[a-z_]+)`' --glob '*.md'
```

For each match, verify the tool name exists in:
- The MCP tool listing of the current session (if available)
- OR `.mcp.json` (look for the MCP server name as a hint)
- OR `.claude/skills/<name>/` directory

If none, flag as "MCP tool not configured in this project" (warning, not blocker — user may have it set up locally).

### 1.6 CLAUDE.md section contract

The contract is data, not prose: the rows between `CLAUDE-CONTRACT:BEGIN` and `CLAUDE-CONTRACT:END` in [.claude/templates/CLAUDE-template.md](../../templates/CLAUDE-template.md), each one `| <item> | <kind> | <tier> |`.

```bash
find .claude -maxdepth 2 -name 'CLAUDE-template.md'   # contract source present?
find . -maxdepth 1 -name 'CLAUDE.md'                  # target present?
# only once BOTH lines above returned a path:
awk '/CLAUDE-CONTRACT:BEGIN/,/CLAUDE-CONTRACT:END/' .claude/templates/CLAUDE-template.md
rg -n '^#+\s+' CLAUDE.md
```

Guard both inputs **before** any probe touches them — `rg` on a missing file exits `2`, and per [.agents/memory/index.md](../../../.agents/memory/index.md) → Probe Convention a non-zero exit from an embedded probe fails the whole skill load, so the user sees a shell error naming a file that is merely absent:

- Contract source absent → report `contract source missing — section check skipped`, loud, and let the remaining categories run. Never a silent green.
- `CLAUDE.md` absent → report `CLAUDE.md not found — contract check skipped` and return.

For each contract row, by `kind`:

- **`heading`** — normalize every `CLAUDE.md` heading (trim, strip trailing `#`, collapse whitespace) and compare the item **literally and exactly**, regex-escaping it first because names contain `&`. Heading *level* drift (`###` vs `##`) is accepted — consumers read by name, not depth. A prefix match is not: `## Validation Legacy` does not satisfy `Validation`.
- **`content:<Section>`** — bound the search to that section's body (its heading up to the next `## `) and check **the component, not just its marker**; a marker-only search passes on a gutted section:
  - `**Orchestrate publish:**` — the label, a real value on the same line (`push` or `branch-local`, never a `{…}` placeholder), **and** its explanatory blockquote, bounded to the span between the label and the next peer item or `### Branch model`. Unbounded, any later blockquote in the section satisfies it.
  - `git worktree remove --force` — the full guard sentence, not an incidental mention of the command elsewhere.
  - `### Branch model` — the heading **and six labelled assignments** (`**Preset:**` … `**Protected:**`) carrying non-placeholder values, matched **outside** blockquote lines. Field *names* are not enough: an explanatory blockquote can name all six and assign none, and that block holds no branch facts at all. The template's assignment form is the shape to require.
- **`conditional:lsp`** — match `Code Navigation` by **substring** (the heading ships as `## Code Navigation (LSP)`, and the contract is the substring). This is the single documented exception to exact matching; do not generalize it. Report it missing **only when the precondition holds**, and that precondition is **repo-scoped declaration, never machine state**:
  - ✅ an LSP package declared in a project manifest (`package.json` dependencies, `pyproject.toml`, `Cargo.toml`, `go.mod`) or an in-repo editor/LSP config naming one.
  - ❌ never `command -v` — a language server on `PATH` says nothing about this repo, and a check whose verdict depends on whose laptop runs it is worse than no check.
  - ❌ never a plain text search for the indicator names, not even a narrowed one. They occur as prose throughout `.claude/` and `.agents/`, and `pyright` is a substring of `Copyright` — measured here, a bare name search self-detects an LSP off the `LICENSE` header of a repo that declares none. Read manifests, not text.

  Declared + substring absent → **tier 2** (the `nudge-lsp.sh` pointer goes quiet — a lost hint, not a switched code path). Not declared → **silent**, never a finding.

Heading present but its body still `{placeholder}` → report `present but unfilled`, counted as absent for tier 1. A stub that satisfies a presence check is worse than an absent section, which is why this is a distinct outcome rather than a pass.

**Tier 3 — unknown targets.** From 1.3's matches take only those whose target file is `CLAUDE.md`, then subtract the contract items, the conditionals, and `CLAUDE.md`'s actual headings; what remains is a reference to a section this contract does not know. Restricting by target file **first** is what keeps a perfectly valid `README.md → Installation` out of a *contract* finding — non-`CLAUDE.md` references stay 1.3's business.

Normalize each candidate to its **leading Title-Case run** before subtracting — the same bound the third 1.3 pattern applies, because the first one does not: it captures lowercase too, so `CLAUDE.md → Style & Conventions rather than guessing` arrives with its explanation attached and would be reported as an unknown section that nobody ever referenced.

Report only — this category never edits `CLAUDE.md` (see the standing rule after 1.7).

### 1.7 Phase 1 output

```markdown
📎 Reference Integrity — <N> markdown files scanned

❌ MARKDOWN LINKS broken (<count>):
   <source>:<line>
     [<text>](<original>) → tried <resolved>
     Suggestion: <basename match if exactly one> | none | ambiguous: <candidates>

❌ PATH REFS broken (<count>):
   <source>:<line>
     `<path>` — file not found
     Suggestion: <basename match> | none | ambiguous

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

❌ CLAUDE.md CONTRACT broken (<count>):
   tier 1 — <item> (<kind>) — absent | present but unfilled
   tier 2 — <item> (<kind>) — absent | present but unfilled
   tier 3 — unknown target: <source>:<line> — "CLAUDE.md → <section>"
     Available headings in CLAUDE.md: <list of ## headings>

✅ <total OK> references valid
```

If zero broken across all 6 categories, output:
```
✅ All references valid (<total> checked across 6 categories).
```

**No auto-fix.** User decides what to repair. Continue to Phase 2 after report.

---

## Phase 2: Memory Pruning

Memory pruning runs at **two granularities, in this order**:

- **Section 2A — entry-level (per-entry).** Cut stale `## <date> — <title>` entries out of
  living append-style files (the file keeps living). Daily archive `archive/<file>-YYYY-MM-DD.md`.
- **Section 2B — file-level (per-file).** Archive whole memory files that have gone cold per the
  read-telemetry sidecar. Quarterly archive `archive/YYYY-Q<N>/<file>`.

**Order matters: 2A → 2B.** Prune entries in living files first, then judge whole dead files — a
file emptied by 2A becomes an obvious 2B candidate in the same run. The two archive schemes differ
on purpose (entries vs whole files); both are historical-only and never auto-loaded.

> **Prune on an up-to-date branch, and merge that commit on its own.** The memory logs carry
> `merge=union` (`.gitattributes`), so an entry deleted here **comes back** if another branch still
> carries it — union keeps both sides, and a deletion is not a side it can see. Pulling first and
> merging the pruning commit alone, rather than inside a batch of feature work, is what keeps the
> cut from being silently undone.

---

### Section 2A — Entry-level pruning (per-entry)

**Goal:** identify stale entries in append-style memory files and offer archiving.

**Files in scope:**
- `.agents/memory/errors.md`
- `.agents/memory/decisions.md`
- `.agents/memory/patterns.md`
- `.agents/memory/api.md`
- `.agents/memory/domain/*.md`

**Skip:** `.agents/memory/archive/**`, regenerated files (`architecture.md`, `project-brief.md`, `domain/business-model.md`), and `user-profile.md` (per-developer, gitignored — never pruned).

#### 2A.1 Identify candidate entries via heuristics

`errors.md`, `decisions.md` and `domain/*.md` are structured as `## <date> — <title>` blocks (per starter convention); `patterns.md` and `api.md` use **topical, undated** `## <name>` headers. Parse each file into `##`-delimited entries either way.

**Heuristic A — date-based (dated entries only):**
- Entry header date is older than **6 months** from today → candidate.
- Undated topical entries (patterns/api) never match A — judge them by B and C alone.

**Heuristic B — code-grounded:**
- Extract path-like tokens from entry body: `src/**/*`, `lib/**/*`, `.agents/**/*`, file names with extensions.
- For each token, check existence with `rg --files`.
- If **all** referenced paths are broken (file moved/deleted) → candidate.
- If **some** broken → soft signal (mention in report but don't auto-flag).

**Heuristic C — usage-based (file-level, from the read-tracking sidecar):**
- If `.claude/memory-usage.json` exists (written by `track-memory-read.sh`), look up this file's entry.
- `last_referenced` **older than 90 days** → the whole file is cold (not consulted in a quarter) → its entries are stronger archive candidates.
- **Absent** from the sidecar → do NOT treat as a signal (tracking may have started recently; absence ≠ unused — false-positive philosophy).
- This is a file-level hint layered onto the per-entry decision, never an auto-archive trigger.

**A, B and C aligned (old + broken refs + cold)** → strong candidate (highlighted).
**Any one met** → candidate.
**None** → keep silently.

#### 2A.2 Per-candidate user decision

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
- **Skip-for-now** → leave entry, but it will reappear in next `/maintain:cleanup-workflow` run.

**Default suggestion when uncertain:** archive. It's reversible (entry still in git history + archive file).

#### 2A.3 Apply archive moves

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

   > These entries were archived by `/maintain:cleanup-workflow` because they were stale (date heuristic and/or code-grounded heuristic). Do not load this file in `/prime` or any agent — it is historical record only.
   ```

#### 2A.4 Section 2A output

```markdown
🗂 Memory Pruning — 2A entry-level — <N> files scanned

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

### Section 2B — File-level pruning (from read-telemetry sidecar)

**Goal:** archive whole memory files that have gone cold — never read within the threshold window.
Where 2A used the sidecar as a *soft* signal (Heuristic C), 2B uses it as the *hard* criterion.

**Propose-only — never auto-archives.** User decides per file.

#### 2B.1 Collect usage from the sidecar + file list

The read-telemetry sidecar `.claude/memory-usage.json` (written async by `track-memory-read.sh`
after every memory-file `Read`, already introduced in 2A's Heuristic C) is keyed by path relative
to `.agents/memory/`:

```json
{ "errors.md": { "last_referenced": "YYYY-MM-DD", "ref_count": N } }
```

Enumerate every memory file and join it against its sidecar entry. A file with **no sidecar entry**
has never been read this checkout → treat as `ref_count: 0`, no `last_referenced` (idle measured
from `created`, see 2B.2). `pinned: true|false` lives in each file's **frontmatter** (a human
decision, not telemetry) — a pinned file is excluded from proposals regardless of usage.

```bash
cd "$(git rev-parse --show-toplevel)"
DB=.claude/memory-usage.json
# Do NOT create the sidecar here — 2B is read-only on telemetry, and the "no sidecar →
# skip 2B" guard below must stay reachable (a created-empty sidecar would turn every
# file into a false archive candidate via days-since-created).
# Unusable counts as absent: -f alone passes a 0-byte or malformed sidecar, and then every
# jq below returns empty — so every file reads as "never referenced" and becomes a false
# archive candidate, which is the exact damage this guard exists to prevent.
{ [ -s "$DB" ] && jq -e . "$DB" >/dev/null 2>&1; } || { echo "no usable read-usage telemetry (track-memory-read hook has not run, or the sidecar is empty/corrupt) — skipping 2B"; exit 0; }
for f in .agents/memory/*.md .agents/memory/domain/*.md; do
  key="${f#.agents/memory/}"
  last=$(jq -r --arg k "$key" '.[$k].last_referenced // ""' "$DB")
  refs=$(jq -r --arg k "$key" '.[$k].ref_count // 0'        "$DB")
  pinned=$(head -10 "$f" 2>/dev/null | grep -m1 '^pinned:' | sed 's/pinned: //')
  created=$(head -10 "$f" 2>/dev/null | grep -m1 '^created:' | sed 's/created: //')
  size=$(wc -l < "$f")
  echo "$f|${last:-never}|$refs|${pinned:-false}|${created:-?}|$size"
done
```

If the sidecar is absent or unusable (the hook has never run, or the file is empty/corrupt),
report `no usable read-usage telemetry` and skip the rest of 2B. Report it as *missing telemetry* —
never as "zero reads". A file nobody has read and a file whose reads were never recorded look
identical here, and only the first is an archive candidate.

#### 2B.2 Compute days-idle for each

Threshold is a fixed **180 days** (no command argument — `cleanup-workflow` takes no arguments).
For each file:

- Has a `last_referenced` in the sidecar → `days_idle = (today − last_referenced).days`
- No sidecar entry (never read) → `days_idle = (today − created).days` — a file created long ago
  and never once read is the strongest archival candidate.
- **Candidate** if: `days_idle >= 180 AND ref_count == 0 AND pinned == false`

> The 180-day threshold can be overridden inline for a single run — 2B.4's `AskUserQuestion` MAY
> offer "threshold 180 days — change for this run?". This is a per-run choice, not a CLI argument.

**Exclude from candidacy regardless of usage:** `pinned: true` files, `MEMORY.md`, `index.md`, `user-profile.md`,
`project-brief.md` and the other regenerated files (`architecture.md`, `domain/business-model.md`).

#### 2B.3 Present the file-level audit table

Show three sections:

**A) Pinned files (excluded from archival regardless of usage):**

| File | Size | Created | Last referenced | Refs |
| ---- | ---- | ------- | --------------- | ---- |

**B) Active files (have refs OR under threshold):**

| File | Size | Days idle | Refs |
| ---- | ---- | --------- | ---- |

**C) Archival candidates (threshold exceeded, ref_count == 0):**

| File | Size | Days idle | Created |
| ---- | ---- | --------- | ------- |

If section C is empty, say so explicitly and continue to Phase 3.

#### 2B.4 Per-file user decision

Use `AskUserQuestion` for each candidate (or group if many). The prompt MUST say "archive this
**file**" — distinct from 2A's "archive this **entry**".

- **Archive** — move the whole file to `.agents/memory/archive/YYYY-Q<N>/<filename>`, remove its
  entry from `MEMORY.md` *if present*, leave a breadcrumb in `index.md` Quick Reference.
- **Pin it** — flip `pinned: true` in the file's frontmatter, never propose again.
- **Keep, reset counter** — set the sidecar `last_referenced` to today (give it another window).
- **Skip** — leave as-is, will reappear next run.

#### 2B.5 Execute approved file actions

For **Archive**:

1. `mkdir -p .agents/memory/archive/YYYY-Q<N>` (compute the quarter from today).
2. `git mv <file> .agents/memory/archive/YYYY-Q<N>/`
3. If the file is referenced in `MEMORY.md` (global auto-memory index — **may not exist in an
   `.agents/memory/`-based project; this step no-ops cleanly when absent**) or `.agents/memory/index.md`,
   remove the line or repoint it to the archive location (ask user which).
4. Report what was archived.

For **Pin**: edit frontmatter `pinned: false` → `pinned: true`.

For **Keep, reset** (the only telemetry *write* in this command alongside Pin's frontmatter flip):

```bash
jq --arg k "<key>" --arg d "<today>" '.[$k] = {"last_referenced": $d, "ref_count": ((.[$k].ref_count // 0))}' .claude/memory-usage.json > /tmp/mu.json && mv /tmp/mu.json .claude/memory-usage.json
```

#### 2B.6 Section 2B output

```markdown
🗂 Memory Pruning — 2B file-level — <N> files scanned

Archival candidates: <archived> archived, <pinned> pinned, <reset> reset, <skipped> skipped

Archive created/updated:
  .agents/memory/archive/2026-Q2/domain-deploy.md (whole file)
```

---

## Phase 3: Workflow Health Warnings

**Goal:** surface signals of workflow drift. **No actions** — just flagging.

**Input — retro signals:** if `.agents/retros/` exists, read the `## Signals for /maintain:cleanup-workflow` section of the newest ~3 retros and fold any actionable items into this phase's report (`/retro` produces raw signal; this phase is its declared consumer).

### 3.1 Signal: `status: empty` stuck longer than 30 days

For each regenerated memory file (`.agents/memory/architecture.md`, `project-brief.md`, `domain/business-model.md`):

```bash
# Check if frontmatter says status: empty
head -10 <file> | grep -q '^status: empty' && \
  git log -1 --format='%ct' -- <file>
```

If `status: empty` AND `now - last_modified > 30 days` → warning:
> ⚠️ `<file>` has `status: empty` and hasn't been touched in <X> days. If your project is past bootstrapping, run the owning command (`/maintain:refresh-brief` or `/setup:create-CLAUDE_MD`) to populate it.

### 3.2 Signal: specs without matching done plan

```bash
ls .agents/specs/*.md 2>/dev/null
ls .agents/plans/done/*.md 2>/dev/null
```

For each spec, check whether a plan with a matching topic exists in `plans/done/` or `plans/active/`. Match heuristic: kebab-case topic in filename.

If no match → warning:
> ⚠️ `<spec>` has no matching plan in `plans/active/` or `plans/done/`. Designed but never implemented? Consider closing or running `/plan-feature`.

### 3.3 Signal: stale active plans (>14 days)

For each `*.md` file in `.agents/plans/active/`:
- Run `git log -1 --format=%cd --date=short -- <file>` (substitute the literal filename) to get its last-commit date.
- Compare that date to today and compute the age in days yourself.
- If older than 14 days, flag it.

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

> ⚠️ `<file>` is <N> lines. Consider running Phase 2 of `/maintain:cleanup-workflow` to prune stale entries (you may have skipped some on the previous run).

### 3.6 Phase 3 output

```markdown
🚦 Workflow Health — <N> signals detected

⚠️ STATUS: EMPTY STUCK (<count>):
   .agents/memory/project-brief.md — empty for 47 days. Run /maintain:refresh-brief.
   ...

⚠️ ORPHAN SPECS (<count>):
   2026-03-14-realtime-updates.md — designed but no plan in active/done.

⚠️ STALE ACTIVE PLANS (<count>):
   2026-04-02-auth-rewrite.md — last touched 25 days ago.

⚠️ AUDIT LOG (<count>):
   .claude/audit.log — 7,231 lines. Consider rotating.

⚠️ LARGE MEMORY FILES (<count>):
   errors.md — 542 lines. Consider another /maintain:cleanup-workflow pass.

✅ Other signals: clean.
```

If zero warnings:
```
✅ Workflow health clean. No drift signals detected.
```

---

## Phase 4: Workflow Optimization Audit

**Goal:** surface *systemic drift* in the workflow itself — stale auto-loads, internal contradictions, unbounded automation, config gaps. **No actions — flagging only**, same as Phase 3.

**Generic-only rule:** this phase **discovers** what to check by parsing `.claude/commands/`, `.claude/settings.json`, `.mcp.json`, `.env.example`, `.gitignore`, and `.agents/memory/index.md`. It never hardcodes project-specific paths — what it audits is whatever those files declare.

**False-positive philosophy:** prefer a false-negative to a false-positive. A missed signal costs 30 seconds when it surfaces later; a false alarm trains the user to ignore the report — and then every future signal is lost. When unsure whether something is drift, stay silent.

### 4.1 Auto-load freshness

Parse `prime.md` (and `prime-ba.md`) for the files they load **every** session (the "always" reads). For each:
- If the file is `status: empty` or missing → it is being loaded (or attempted) every prime for no value → flag.
- If the file is oversized (> 500 lines for a memory file, or visibly larger than its peers) → flag as a prime-cost signal.

> ⚠️ `/prime` loads `<file>` every session but it is `<empty / 542 lines>`. Consider populating it (`/maintain:refresh-brief`, `/setup:create-CLAUDE_MD`) or trimming it (Phase 2).

**Dead-memory cross-check → handled by Phase 2B.** Cold whole-file detection from the sidecar
(`last_referenced` past the threshold, `ref_count == 0`) is owned by **Section 2B** of Phase 2,
which not only flags but *archives* such files. 4.1 does not re-run that check here — see the 2B
results earlier in this run. (This keeps a single threshold and one decision point instead of the
former 90-day flag here vs 2B's 180-day archive criterion.)

### 4.2 Cross-file duplication & internal contradictions

- **Contradictions:** scan `CLAUDE.md` + `.claude/commands/` for rules that conflict with practice. Canonical example: `CLAUDE.md` mandates "use `rg`, never `grep`/`find`" while a command actually invokes `grep`/`find`. Search the commands for the forbidden tool and flag each hit.

  **Exempt: bounded single-file field extraction.** A pipeline that reads one named file and pulls one field out of it — `head -10 "$f" | grep -m1 '^pinned:'`, `head -10 <file> | grep -q '^status: empty'`, `wc -l file | awk '{print $1}'` — is not a file search and must **not** be flagged. The rule this check enforces is about *finding files by content across a tree*, which is what `rg` replaces; it was never about parsing a line out of a known file, and `rg` is not the better tool for that.

  > This command itself uses exactly those forms (`grep -m1` twice in Phase 2B, `grep -q` in Phase 3, `awk` in Phase 4.1). Without this exemption Phase 4.2 reports **itself** as a contradiction on every single run — and a report that always contains a known-false line is one the reader learns to skim, which is the failure this whole phase exists to avoid.
- **Duplication:** the same multi-line guidance copied across files drifts out of sync. Flag blocks substantially duplicated between `CLAUDE.md` and a command — the source of truth should live in one place and be linked.

> ⚠️ `CLAUDE.md` mandates `rg` but `<command>.md:<line>` calls `find`/`grep`. Align the command or the rule.

### 4.3 Hook automation review

Read the `hooks` block in `settings.json` and the scripts in `.claude/hooks/`. Flag:
- **Unbounded log growth:** a hook that appends to a file with no rotation. (The shipped `audit-append.sh` self-rotates at 5000 lines — flag any *other* appender that does not.)
- **Async + non-idempotent:** an `async` hook performing a non-idempotent mutation (a race between concurrent fires could corrupt state). Idempotent appends/rotations are fine.
- **Secret leakage:** a hook command that could write a token/secret into a logged field; cross-check against the `deny` token patterns in `settings.json`.
- **Sync correctness:** a hook meant to *block* (like `guard-commit.sh`) must NOT be `async` — async cannot block. Flag any blocker registered async.

### 4.4 Gitignore & MCP config drift

- **Gitignore coverage:** confirm local-only artifacts are ignored — `.claude/audit.log`, `.claude/worktrees/`, any tool output dir. Flag artifacts present in the tree but not gitignored (they will leak into commits).
- **MCP config drift:** `.mcp.json` is committed and must hold no secrets — flag any `env` block with a literal credential (secrets belong in `.env` via `--env-file`). Flag `.env.example` keys missing for a declared server, and missing `--output-dir`/equivalent flags that would dump MCP artifacts into the repo root.

### 4.5 Phase 4 output

```markdown
🛠 Workflow Optimization — <N> signals detected

⚠️ STALE AUTO-LOAD (<count>):
   /prime loads project-brief.md every session — status: empty.

⚠️ CONTRADICTIONS (<count>):
   CLAUDE.md mandates rg; <command>.md:<line> uses find.

⚠️ HOOK RISKS (<count>):
   <hook> appends to <file> with no rotation.

⚠️ CONFIG DRIFT (<count>):
   .claude/worktrees/ not in .gitignore.

✅ Other checks: clean.
```

If zero signals:
```
✅ Workflow optimization clean. No systemic drift detected.
```

---

## Final Report

After all 4 phases:

```markdown
# /maintain:cleanup-workflow run summary — YYYY-MM-DD

## Phase 1: References
   - Markdown links:    <X> OK, <Y> broken
   - Path refs:         <X> OK, <Y> broken
   - Section anchors:   <X> OK, <Y> broken
   - Slash commands:    <X> OK, <Y> broken
   - MCP refs:          <X> OK, <Y> broken
   Total broken: <N> — fix manually before commit.

## Phase 2: Memory pruning
   2A entries:  <K> kept, <A> archived, <D> deleted, <S> skipped.
   2B files:    <A> archived, <P> pinned, <R> reset, <S> skipped.
   Archives: <list of created archive files / dirs (2A daily, 2B quarterly)>.

## Phase 3: Workflow health
   <N> warnings (see details above).

## Phase 4: Workflow optimization
   <N> drift signals (auto-load / contradictions / hooks / config).

## Next steps
   - Fix Phase 1 broken refs (manual).
   - Address Phase 3 warnings as time permits.
   - Re-run /maintain:cleanup-workflow before next major milestone.
```

---

## Rules

- **Use `rg`, never `grep` or `find`** — for *searching*. A bounded single-file field extraction (`head -N | grep -m1 '^key:'`, `wc -l | awk '{print $1}'`) is not a search and is exempt, both from the rule and from Phase 4.2's contradiction check.
- **Phase 1: no auto-fix.** Suggestions only — user repairs manually.
- **Phase 2: archive is the default.** Delete only on explicit user choice.
- **Phase 2 runs 2A (entry-level) before 2B (file-level).** 2A cuts stale entries from living files (daily archive `archive/<file>-YYYY-MM-DD.md`); 2B archives whole cold files (quarterly archive `archive/YYYY-Q<N>/`). Both schemes coexist by design.
- **Phase 2B: archive is the default for cold files.** `Pin` and `Keep, reset` are the only telemetry *writes* the command makes (frontmatter flip / sidecar bump); everything else only reads the sidecar.
- **Phase 3: no actions.** Pure signal — let the user decide.
- **Phase 4: no actions.** Discovery + flagging only; never hardcode project paths, and prefer a false-negative to a false-positive.
- **Skip `.agents/memory/archive/**`** in all phases (this command never re-processes its own archive).
- **Skip `node_modules`, `.git`, `dist`, `build`** in all file scans.
- **Run order is fixed:** Phase 1 → Phase 2 → Phase 3 → Phase 4. User can stop after any phase by interrupting; no resumption — re-run from start next time.
