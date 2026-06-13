---
description: Audit .agents/memory/ — propose archival candidates based on usage tracking
argument-hint: [threshold-days] (default 180)
---

# /memory-audit — Memory Lifecycle Audit

Reviews all files in `.agents/memory/` with lifecycle frontmatter and proposes
archival candidates. **Propose-only — never auto-archives.** User decides per file.

---

## How it works

Read telemetry lives in a **gitignored sidecar**, `.claude/memory-usage.json`, keyed by
path relative to `.agents/memory/`:

```json
{
  "errors.md":        { "last_referenced": "YYYY-MM-DD", "ref_count": N },
  "domain/deploy.md": { "last_referenced": "YYYY-MM-DD", "ref_count": N }
}
```

The hook lives at `.claude/hooks/track-memory-read.sh` and runs async after every `Read`
of a memory file, bumping that file's entry via atomic read-modify-write. Telemetry is
**local** (your read patterns differ from a teammate's) — it is never committed, so a file
**absent from the sidecar has simply never been read this checkout** (treat as `ref_count: 0`,
no `last_referenced`).

`pinned: true|false` still lives in each file's **frontmatter** (it is a human decision, not
telemetry) — a pinned file is excluded from archival proposals regardless of usage.

---

## Workflow

### 1. Collect usage from the sidecar + file list

Enumerate every memory file, then join each against its sidecar entry. A file with **no
sidecar entry** has never been read this checkout — treat it as `ref_count: 0` with no
`last_referenced` (so its idle window is measured from `created`, see step 2).

```bash
cd "$(git rev-parse --show-toplevel)"
DB=.claude/memory-usage.json
[ -f "$DB" ] || echo '{}' > "$DB"
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

### 2. Compute days-since-referenced for each

`$ARGUMENTS` = threshold in days (default: **180**). For each file:

- If it has a `last_referenced` in the sidecar: `days_idle = (today - last_referenced).days`
- If it has **no** sidecar entry (never read): `days_idle = (today - created).days` — a file
  created long ago and never once read is the strongest archival candidate.
- **Candidate** if: `days_idle >= threshold AND ref_count == 0 AND pinned == false`

### 3. Present the audit table

Show two sections:

**A) Pinned files (excluded from archival regardless of usage):**

| File | Size | Created | Last referenced | Refs |
| ---- | ---- | ------- | --------------- | ---- |

**B) Active files (have refs OR under threshold):**

| File | Size | Days idle | Refs |
| ---- | ---- | --------- | ---- |

**C) Archival candidates (threshold exceeded, ref_count == 0):**

| File | Size | Days idle | Created |
| ---- | ---- | --------- | ------- |

If section C is empty, say so explicitly and stop.

### 4. Ask user per-candidate

Use `AskUserQuestion` for each candidate (or group if many):

- **Archive** — move to `.agents/memory/archive/YYYY-Q<N>/<filename>`,
  remove entry from `MEMORY.md` if present, leave breadcrumb in `index.md` Quick Reference
- **Pin it** — flip `pinned: true` in the file's frontmatter, never propose again
- **Keep, reset counter** — set the sidecar `last_referenced` to today (give it another window)
- **Skip** — leave as-is, will appear again next audit

### 5. Execute approved actions

For "Archive":

1. `mkdir -p .agents/memory/archive/YYYY-Q<N>` (compute quarter from today)
2. `git mv <file> .agents/memory/archive/YYYY-Q<N>/`
3. If file is referenced in `MEMORY.md` (auto-memory index) or `.agents/memory/index.md`,
   either remove the line or update path to archive location (ask user which)
4. Report what was archived

For "Pin":

1. Edit frontmatter: `pinned: false` → `pinned: true`

For "Keep, reset":

1. Bump the sidecar entry to today:
   `jq --arg k "<key>" --arg d "<today>" '.[$k] = {"last_referenced": $d, "ref_count": ((.[$k].ref_count // 0))}' .claude/memory-usage.json > /tmp/mu.json && mv /tmp/mu.json .claude/memory-usage.json`

### 6. Summary

End with:

- N archived → which files, where
- N pinned → which files
- N reset → which files
- Reminder: run `git status` to review changes before commit

---

## Notes

- **Never auto-archives** without explicit per-file user approval.
- Archive location uses **quarters** (e.g. `archive/2026-Q2/`) for chronological browsing.
- `MEMORY.md` and `index.md` are excluded from candidacy — they're index files, not content.
- `project-brief.md` is auto-refreshed by `/maintain:refresh-brief` and excluded.
- Telemetry comes from the **sidecar**, not frontmatter — every memory file is tracked once
  it has been Read, with no per-file frontmatter setup required. A file that has never been
  read simply has no sidecar entry (its idle window is then measured from `created`).
- The sidecar is gitignored and local, so an audit reflects **this checkout's** read history,
  not the whole team's. A fresh clone starts with an empty `memory-usage.json`.

---

## Output format

Tabular, concise. No prose summaries. End with a one-line status:

> "Audit complete: N candidates, M archived, K pinned, L reset."
