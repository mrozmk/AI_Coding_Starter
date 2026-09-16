# Transition pattern

Flow for changing an issue's status. Two-phase because Jira requires a `transition_id`, not a status name, and the set of available transitions depends on the issue's current status and the project's workflow.

Invoked when the primary skill sees subcommand `transition` or detects transition intent in natural language ("przenieś PROJ-123 do In Progress", "close PROJ-45").

---

## Input

Positional `$ARGUMENTS`:

- `$0` — issue key, e.g. `PROJ-123`. **Required.** If empty, stop and ask.
- `$1` — target status name, e.g. `"In Progress"`, `"Done"`. **Optional** — if absent, skill lists available transitions and asks the user to pick.

Natural-language variant: skill extracts issue key and status name from the prompt.

---

## Flow

### Step 1 — Discover transitions

```
jira_get_transitions(issue_key="$0")
```

Response shape (approximate — verify at first use):

```json
[
  {"id": "11", "name": "Start Progress", "to": {"name": "In Progress"}},
  {"id": "21", "name": "Done", "to": {"name": "Done"}, "fields": {"resolution": {"required": true}}},
  {"id": "31", "name": "Back to To Do", "to": {"name": "To Do"}}
]
```

### Step 2 — Select transition

- If `$1` is present:
  - Case-insensitive match against each transition's `name` and `to.name`.
  - On unambiguous match → select its `id`.
  - On no match → show the available list, do NOT guess, ask user to pick.
  - On multiple matches → show the matching subset, ask user to disambiguate.
- If `$1` is absent:
  - Show the full list, ask user to pick by name or index.

### Step 3 — Fetch current status (for diff prompt)

```
jira_get_issue(issue_key="$0", fields="status,summary")
```

Only the `status.name` and `summary` are needed. This is a read call, not mutating — no confirm yet.

### Step 4 — Handle required fields

If the chosen transition has `fields` with `required: true` entries (common for `Done` / `Close` → `resolution`):

- For each required field, ask the user interactively:
  ```
  Transition "Done" wymaga pola "resolution". Wybierz:
  - Fixed
  - Won't Do
  - Duplicate
  - ...
  ```
- Build the `fields` JSON string: `'{"resolution": {"name": "Fixed"}}'`.
- Allow the user to cancel (answer `n`) at this point.

### Step 5 — Dry-run confirm

Render a diff-style prompt in Polish:

```
Zmieniam $0 ("<summary>")
  z:  "<CURRENT_STATUS>"
  na: "<TARGET_STATUS>"
<if required fields:>
  pola: resolution=Fixed

Kontynuować? [y/n]
```

- On `n` → abort.
- On `y` → step 6.

### Step 6 — Execute

```
jira_transition_issue(
    issue_key="$0",
    transition_id="<selected-id>",
    fields='<JSON-string-if-required-fields-else-omit>'
)
```

### Step 7 — Report

```
$0 → "<TARGET_STATUS>" ✓
Link: $JIRA_URL/browse/$0
```

On error (e.g. transition became invalid between steps 1 and 6 because someone else moved the issue): show raw error, offer to re-run step 1 and re-pick.

---

## Invariants

- **Never skip step 5 confirm.** Even when the target status was explicit in `$1`.
- **Never auto-default a required field.** Ask the user every time. `resolution="Fixed"` may seem obvious but guessing is the common bug.
- **Never call `jira_transition_issue` with a status name in place of `transition_id`.** That call silently succeeds on some MCP versions with no transition actually happening.

---

## Edge cases

- **Chained transitions** (user wants `To Do` → `Done`, but workflow forces `To Do` → `In Progress` → `Done`): step 1 only shows transitions available from the CURRENT status. If the user's target is not reachable in one step, say so:
  ```
  Z 'To Do' nie ma bezpośredniego przejścia do 'Done'. Dostępne: Start Progress → In Progress. Chcesz wykonać pierwszy krok? Wtedy uruchom skill ponownie z kolejnym. [y/n]
  ```
- **Unknown issue key** (404 at step 1): stop with "Klucz $0 nie istnieje w tej instancji". Don't retry.
- **No transitions available** (weird workflow state): show `jira_get_transitions` raw response and stop.
- **Target status name exists but as multiple transitions** (rare — some workflows have two paths to the same status): list them with their transition names, ask user to disambiguate by transition name.
