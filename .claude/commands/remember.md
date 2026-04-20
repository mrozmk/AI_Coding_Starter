---
description: Save a discovery, decision, or lesson to project memory
argument-hint: [what to remember — or leave empty to reflect on recent work]
---

# /remember - Save to Project Memory

Capture something worth remembering into the appropriate memory file.
This command can be triggered explicitly or used mid-task without a commit.

---

## Input

`$ARGUMENTS` — optional. Can be:
- A specific thing to remember: `/remember build breaks when env var FOO is unset — must be set in CI`
- Empty: `/remember` — AI reflects on recent conversation and extracts what's worth saving

---

## Steps to follow:

### 1. Determine what to remember

- If `$ARGUMENTS` is provided — use it as the content to save
- If `$ARGUMENTS` is empty — review the recent conversation and identify:
  - Any bug that occurred and was fixed
  - Any API or protocol behavior that was surprising or undocumented
  - Any architectural decision that was made
  - Any pattern that was identified or established
  - Any gotcha or warning worth capturing
  - If nothing worth saving is found — inform the user: "Nothing significant to remember from recent context." and stop.

### 2. Classify into the right file

| Type of discovery | Target file |
|---|---|
| Bug, crash, root cause, lesson learned | `.agents/memory/errors.md` |
| API response, protocol quirk, undocumented field | `.agents/memory/api.md` |
| Architectural or technical decision (why X over Y) | `.agents/memory/decisions.md` |
| Coding pattern specific to this project | `.agents/memory/patterns.md` |
| Knowledge specific to one module or domain | `.agents/memory/domain/{module}.md` |

- If unsure between two files — pick the most specific one
- If the `domain/` file doesn't exist yet — create it using the template in `.agents/memory/index.md`

### 3. Format the entry

Use the appropriate format per file type:

**errors.md / api.md / patterns.md:**
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

**domain/{module}.md:**
```markdown
## [YYYY-MM-DD] {Short title}

{What was learned about this module}

**Rule:** {Actionable takeaway}
```

### 4. Append to file

- Add the new entry at the **top** of the relevant section (newest first)
- Do NOT rewrite or reformat existing entries
- Do NOT remove the `_No entries yet._` placeholder if other entries exist — just add above it... actually remove it once the first real entry is added

### 5. Update index.md Quick Reference (if critical)

- If this discovery is one of the most important lessons for the project — add a one-liner to the **Quick Reference** section in `.agents/memory/index.md`
- Use judgment: Quick Reference should stay short (max ~7 items). Only add if it's a "always check this" level insight.

### 6. Confirm

Report to the user:
> "Saved to `.agents/memory/{filename}`: {title of entry}"
