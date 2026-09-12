# Bulk-create pattern

Flow for "create N issues under a parent Epic" via `jira_batch_create_issues`. Invoked when the primary skill sees subcommand `bulk` or detects bulk intent in natural language ("stwórz 5 tasków...", "create 3 bugs...").

---

## Input

Positional `$ARGUMENTS`:

- `$0` — parent Epic key, e.g. `PROJ-100`. **Required.** If empty, stop and ask.
- `$1` — count of issues to create. Optional. If absent, ask.
- `$2..` — topic / theme, e.g. `"refaktor modułu auth"`. Optional but strongly recommended — without it, summaries will be generic.

Natural-language variant (no slash): skill extracts the same triple from the prompt before delegating here.

---

## Flow

### Step 1 — Validate parent

```
jira_get_issue(issue_key="$0", fields="summary,issuetype,project")
```

- If `issuetype != "Epic"` → stop. Ask: `"$0 to <type>, nie Epic. Czy mimo wszystko tworzyć pod tym parentem? [y/n]"`. If user declines, abort.
- Read `project` key from response — it's the `project_key` for every child issue. Do NOT use `$JIRA_DEFAULT_PROJECT`; the parent's project wins.
- Read `summary` — use in the confirm prompt for context.

### Step 2 — Generate plan

For each of N issues, the model generates:
- `summary` — specific, distinct from siblings. Derived from the topic (`$2..`).
- `description` — Task template from `description-templates.md` (Task default; user can request Bug in the prompt).
- `issue_type` — default `"Task"`. If user said "bugs", use `"Bug"`. Mixed is allowed.
- `components` — from `$JIRA_DEFAULT_COMPONENTS` env (comma-separated string). Empty string if unset.
- `additional_fields` — JSON string `'{"parent": "$0", "labels": [...]}'` with `labels` from `$JIRA_DEFAULT_LABELS` split on comma, or omit if unset.

Build the `issues` argument as a **JSON string** of an array of create payloads:

```json
[
  {
    "project_key": "PROJ",
    "summary": "Extract AuthProvider interface",
    "issue_type": "Task",
    "description": "## Objective\n...",
    "components": "backend",
    "additional_fields": "{\"parent\": \"PROJ-100\", \"labels\": [\"from-claude\"]}"
  },
  ...
]
```

Note the double-stringification: `additional_fields` is itself a JSON string inside the outer JSON-string payload.

### Step 3 — Dry-run validation

```
jira_batch_create_issues(issues=<JSON-string-of-array>, validate_only=true)
```

- Jira returns per-issue validation results.
- If any issue fails validation (400, missing required field, invalid component, etc.) → show the raw per-issue errors, ask user to fix (typically: update components or add a required custom field). Retry step 3 until clean.
- If all pass → continue.

### Step 4 — Confirm table

Render a markdown table to the user:

```markdown
Mam stworzyć N zadań pod $0 (Epic: "<summary>"):

| # | Type | Summary                           | Components | Labels       |
|---|------|-----------------------------------|------------|--------------|
| 1 | Task | Extract AuthProvider interface    | backend    | from-claude  |
| 2 | Task | Replace PasswordHasher with Argon | backend    | from-claude  |
| …

Pełne opisy: rozwinąć? [r]   Tworzę? [y/n/edit]
```

- On `r`: print each issue's full description, then re-ask.
- On `edit`: enter interactive refinement — user edits summaries or drops issues, replan, redry-run, re-confirm.
- On `n`: abort; no Jira calls made.
- On `y`: proceed to step 5.

### Step 5 — Execute

```
jira_batch_create_issues(issues=<same-JSON-string>, validate_only=false)
```

### Step 6 — Report

- On full success: list created keys with clickable links:
  ```
  Utworzone:
  - PROJ-243: Extract AuthProvider interface — $JIRA_URL/browse/PROJ-243
  - PROJ-244: Replace PasswordHasher with Argon — $JIRA_URL/browse/PROJ-244
  ...
  ```
- On partial success: show created + failed, with raw error per failed issue:
  ```
  Utworzone (3/5):
  - PROJ-243, PROJ-244, PROJ-245
  Nieutworzone:
  - #4 (summary "…"): 400 — "priority name 'Critical' not found"
  - #5: validation error propagated after #4 failed
  Chcesz naprawić i dokończyć pozostałe? [y/n]
  ```
  On `y`: re-plan with fixes (ask user to resolve the error's cause), re-run steps 3-5 for the remaining issues only.

---

## Invariants (enforced)

- **Never execute step 5 without passing through step 4 `y` confirmation.** The model must not shortcut this even if the same batch was validated moments ago. The `validate_only=true` pass from step 3 does NOT count as confirmation — it only proves Jira accepts the shape.
- **Never retry automatically on 4xx.** Show the error, ask the user.
- **Never auto-rollback created issues.** Partial-success items stay in Jira. `jira_batch_create_issues` has no rollback primitive.

---

## Edge cases

- **N > 20**: warn the user that batches larger than ~20 sometimes trigger per-issue rate limiting in the underlying REST API. Offer to split into groups of 10.
- **Duplicate summary vs siblings**: before step 4, run `jira_search(jql='parent = $0 AND summary ~ "..."')` for each planned summary. In the confirm table, add a `⚠ duplikat?` column if any match is found. Don't block — let user decide.
- **Missing env**: if `$JIRA_DEFAULT_COMPONENTS` and `$JIRA_DEFAULT_LABELS` are both empty and the user didn't provide them in the prompt, the skill must not silently omit — it asks once: `"Użyć pustych labels i components? [y / podaj wartości]"`. This satisfies hard invariant #2 (no default creation without explicit signal).
