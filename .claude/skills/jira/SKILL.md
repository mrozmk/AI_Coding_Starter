---
name: jira
description: Create, edit, search, comment, link, and transition Jira Cloud Epics, Tasks, and Bugs via mcp-atlassian. Use when the user mentions Jira, a PROJ-XXX issue key, or asks to create/update/search/comment/transition tasks, epics, or bugs. Supports bulk creation under a parent Epic.
when_to_use: |
  Triggered by phrases in Polish or English like "stwórz task", "create epic", "edytuj bug", "zaktualizuj", "dodaj komentarz", "add comment", "pokaż moje bugi", "show my bugs", "zmień status", "transition", "zablokuj przez", "blocked by", "powiąż z", "link to", or any reference to a Jira issue key (regex [A-Z]+-\d+). Also via explicit /jira invocation with optional subcommand as first argument: /jira bulk, /jira search, /jira transition, /jira comment, /jira link, /jira create, /jira update. Handles Epic / Task / Bug only — no sub-tasks.
argument-hint: "[subcommand] [args...]"
allowed-tools: mcp__atlassian__jira_get_issue mcp__atlassian__jira_search mcp__atlassian__jira_create_issue mcp__atlassian__jira_update_issue mcp__atlassian__jira_add_comment mcp__atlassian__jira_transition_issue mcp__atlassian__jira_get_transitions mcp__atlassian__jira_create_issue_link mcp__atlassian__jira_get_link_types mcp__atlassian__jira_get_all_projects mcp__atlassian__jira_batch_create_issues
---

# Jira skill

Single entry point for all Jira Cloud operations on Epics, Tasks, and Bugs. All MCP I/O goes through `mcp__atlassian__*` tools declared in `allowed-tools` above.

For parameter shapes and deeper protocol detail, defer to `.agents/reference/jira-mcp-atlassian.md`.

---

<HARD-GATE>
Three invariants — they hold for every invocation, every turn, for the duration of the session. Never relax them.

1. **Dry-run first.** Every mutating operation (create, update, transition, comment, link, bulk-create) MUST present the plan as a markdown table or diff and wait for explicit user confirmation (`y`) before the mutating MCP call. Even if the user seemed to pre-approve in an earlier turn — re-display and re-ask. Jira has no transactions and no undo.

2. **No default creation.** If any of these is missing, STOP and ask — do not guess or fabricate:
   - `project_key` (fall back to `$JIRA_DEFAULT_PROJECT` only if set; otherwise ask)
   - `parent_epic_key` for Task and Bug (always required — no Task / Bug is created "free-floating")
   - `summary`
   - `issue_type` (Epic / Task / Bug only)
   - `components` when `$JIRA_DEFAULT_COMPONENTS` is empty AND user did not supply

3. **No sub-tasks.** Never emit `issue_type: "Sub-task"`. If the user asks for sub-tasks, explain the skill handles Epic / Task / Bug only, and offer to create Tasks under the same parent Epic instead.
</HARD-GATE>

---

## Step 1 — Environment preflight

Run this check before every session-first invocation of a mutating operation. If the session already completed a successful MCP call, skip — environment is known good.

```!
echo "JIRA_URL: $([ -n "$JIRA_URL" ] && echo set || echo MISSING)"
echo "JIRA_USERNAME: $([ -n "$JIRA_USERNAME" ] && echo set || echo MISSING)"
echo "JIRA_API_TOKEN: $([ -n "$JIRA_API_TOKEN" ] && echo set || echo MISSING)"
echo "JIRA_DEFAULT_PROJECT: ${JIRA_DEFAULT_PROJECT:-UNSET}"
echo "JIRA_DEFAULT_COMPONENTS: ${JIRA_DEFAULT_COMPONENTS:-UNSET}"
echo "JIRA_DEFAULT_LABELS: ${JIRA_DEFAULT_LABELS:-UNSET}"
```

**If any of `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` is MISSING:** hard-stop. Tell the user in Polish:

> Brakuje zmiennej środowiskowej `<NAME>`. Uzupełnij ją w `.mcp.json` (dla `JIRA_*` MCP-side) lub `.claude/settings.local.json` (dla `JIRA_DEFAULT_*` skill-side) i zrestartuj Claude Code. Szczegóły: [.agents/reference/jira-mcp-atlassian.md](../../../.agents/reference/jira-mcp-atlassian.md) sekcja "Setup".

`JIRA_DEFAULT_*` UNSET is NOT a blocker — it just means the skill will ask when it needs those values.

---

## Step 2 — Subcommand dispatch

Inspect `$0` (first word of `$ARGUMENTS`). Route to the matching flow below:

| `$0` | Action |
|---|---|
| *(empty)* | Interactive assistant — ask what to do |
| `create` | Single-issue create (see Flow A) |
| `update` | Single-issue edit (Flow B) |
| `bulk` | Bulk create under parent (Flow C → `references/bulk-pattern.md`) |
| `search` | JQL search (Flow D) |
| `comment` | Add comment (Flow E) |
| `link` | Create issue link (Flow F) |
| `transition` | Status change (Flow G → `references/transition-pattern.md`) |
| *anything else* | Treat entire `$ARGUMENTS` as natural-language intent — infer the verb, then route |

**Natural-language auto-trigger** (no `/jira` prefix, skill loaded by description match): same inference step as the last row above. Identify the verb (create / update / search / comment / link / transition), identify the issue key(s) if any, route to the matching flow. If intent is ambiguous, ask.

---

## Flow A — Create (single issue)

1. **Identify** the target issue type: `Epic`, `Task`, or `Bug`. If user didn't say, ask.
2. **Gather required fields** per `references/field-matrix.md`:
   - Epic: `project_key` (or `$JIRA_DEFAULT_PROJECT`), `summary`.
   - Task/Bug: above + `parent_epic_key`.
   - If any required field missing → stop and ask per HARD-GATE invariant 2.
3. **Fill optional fields** from `$JIRA_DEFAULT_COMPONENTS`, `$JIRA_DEFAULT_LABELS` if set; otherwise skip.
4. **Generate description** from the appropriate template in `references/description-templates.md`. Skip sections the user didn't provide content for — don't leave placeholders.
5. **Components validation** — if any component name was provided:
   ```
   jira_get_issue(issue_key="<parent-or-first-issue-in-project>", fields="components")
   ```
   Build a valid-components set; drop unknowns from the plan with a note.
6. **Dry-run table**:
   ```markdown
   Tworzę <type> w projekcie <project_key>:

   | Field       | Value                         |
   |-------------|-------------------------------|
   | Summary     | ...                           |
   | Type        | Task                          |
   | Parent      | PROJ-100                      |
   | Components  | backend                       |
   | Labels      | from-claude                   |
   | Assignee    | (none)                        |
   | Priority    | (default)                     |

   Description:
   <rendered markdown>

   Tworzę? [y/n/edit]
   ```
7. On `y`:
   ```
   jira_create_issue(
       project_key="...",
       summary="...",
       issue_type="Task",
       description="<markdown>",
       components="backend",
       additional_fields='{"parent": "PROJ-100", "labels": ["from-claude"]}'
   )
   ```
   - On 400 "parent field not available" → retry with `'{"epic_link": "PROJ-100"}'`.
   - On 400 about a required custom field → show error, ask user for value, retry once with the field added. Offer to capture the pattern to `.agents/memory/domain/jira.md`.
8. **Report**:
   ```
   Utworzone: <NEW-KEY> — $JIRA_URL/browse/<NEW-KEY>
   ```

---

## Flow B — Update (single issue)

1. **Fetch current state** for diff:
   ```
   jira_get_issue(issue_key="$1", fields="summary,status,priority,labels,components,assignee,description,parent")
   ```
2. **Apply user's change** to the fetched state — produce a diff.
3. **Dry-run table** showing before/after:
   ```markdown
   Zmiany dla $1:

   | Field     | Before      | After       |
   |-----------|-------------|-------------|
   | Priority  | Medium      | High        |
   | Labels    | ...         | ..., urgent |

   Kontynuować? [y/n]
   ```
4. On `y`:
   ```
   jira_update_issue(
       issue_key="$1",
       fields='<JSON-string of changed fields only>',
       components="<if components changed>",
       additional_fields='<if additional_fields changed>'
   )
   ```
   - **Labels are replaced wholesale.** If user said "add label X", merge with existing (from step 1) before passing.
   - **Components are replaced wholesale** — same merging rule.
5. **Report**: `Zaktualizowane: $1`.

**Status changes are NOT done via update.** Delegate to Flow G.

---

## Flow C — Bulk create

Delegate entirely to [`references/bulk-pattern.md`](references/bulk-pattern.md). Read that file when entering this flow.

Summary of invariants carried through: validate parent is Epic → `validate_only=true` pre-flight → confirm table → `validate_only=false` execute → full/partial report.

---

## Flow D — Search (JQL)

1. **Resolve input**:
   - If `$1` matches a cookbook id (keyword like `open-bugs`, `my-recent`, `high-prio-bugs` etc. from [`references/jql-cookbook.md`](references/jql-cookbook.md)) → use the mapped JQL.
   - If `$ARGUMENTS` looks like raw JQL (contains `=`, `~`, `AND`, `OR`) → use as-is.
   - Otherwise (natural language like `"moje bugi"`, `"open tasks"`) → translate to JQL:
     ```
     Interpretuję jako: project = $JIRA_DEFAULT_PROJECT AND type = Bug AND assignee = currentUser() AND resolution = Unresolved
     Użyć? [y/edit]
     ```
     Wait for confirmation — search is safe but misinterpreted JQL wastes the turn.
2. **Ensure project clause**: if the JQL has no `project =` and `$JIRA_DEFAULT_PROJECT` is set, prepend `project = $JIRA_DEFAULT_PROJECT AND (...)`.
3. **Execute**:
   ```
   jira_search(
       jql="<resolved>",
       fields="summary,status,assignee,priority,issuetype,parent",
       limit=50
   )
   ```
4. **Render** a markdown table:
   ```
   | Key       | Type | Summary            | Status      | Assignee  | Priority |
   |-----------|------|--------------------|-------------|-----------|----------|
   | PROJ-123  | Bug  | Login returns 500  | In Progress | j.smith   | High     |
   ```
5. If `total > 50` → note the total count and ask: `Pokaż następne 50 czy zawęzić query? [next/narrow/skip]`.

---

## Flow E — Comment

1. **Gather**: issue key (`$1` or from prompt), comment body (rest of prompt). Both required.
2. **Dry-run**:
   ```
   Dodaję komentarz do <KEY>:

   <rendered markdown>

   Dodać? [y/n]
   ```
3. On `y`:
   ```
   jira_add_comment(issue_key="<KEY>", comment="<markdown>")
   ```
4. **Report**: `Dodany komentarz do <KEY>`.

Comments are public in Jira — the dry-run is important even for short text.

---

## Flow F — Link

Two-phase:

1. **Discover link types** (cache in-session after first call):
   ```
   jira_get_link_types()
   ```
   Each result has `name` (e.g. "Blocks"), `inward` (e.g. "is blocked by"), `outward` (e.g. "blocks").
2. **Resolve the user's phrasing** to a link type + direction. Examples:
   - `"PROJ-1 blocks PROJ-2"` → link-type=`Blocks`, inward=`PROJ-2`, outward=`PROJ-1`
   - `"PROJ-1 is blocked by PROJ-2"` → link-type=`Blocks`, inward=`PROJ-1`, outward=`PROJ-2`
   - Ambiguous → ask.
3. **Dry-run**:
   ```
   Tworzę link: <outward-KEY> <outward-phrase> <inward-KEY>

   Kontynuować? [y/n]
   ```
4. On `y`:
   ```
   jira_create_issue_link(
       link_type="<type-name>",
       inward_issue="<KEY>",
       outward_issue="<KEY>"
   )
   ```
   (Exact parameter names TBD at first use — verify against MCP tool schema.)
5. **Report**: `Utworzony link: ...`.

---

## Flow G — Transition

Delegate entirely to [`references/transition-pattern.md`](references/transition-pattern.md). Read that file when entering this flow.

Summary of invariants carried through: `jira_get_transitions` first → pick id → fetch current status → confirm diff → execute with required fields if any.

---

## Field conventions (quick reference)

- **`components`**: comma-separated string, no spaces — `"backend,api"`.
- **`parent`** (Task/Bug under Epic): via `additional_fields='{"parent": "EPIC-KEY"}'`. Fall back to `{"epic_link": "..."}` on error.
- **`description` and `comment`**: markdown. `mcp-atlassian` converts to ADF.
- **`labels`**: inside `additional_fields` as array of strings — `'{"labels": ["x","y"]}'`.
- **`additional_fields`**: a JSON **string** (stringified JSON), not a dict literal.

Full matrix: [`references/field-matrix.md`](references/field-matrix.md).

---

## Error handling

- **4xx / 5xx from MCP**: show the raw error body to the user. No automatic retry. No swallowing.
- **400 about required custom field**: show error, ask user for value, offer to capture the field-id → project mapping to `.agents/memory/domain/jira.md` so future calls pre-populate.
- **401**: `JIRA_API_TOKEN` likely expired. Tell user to regenerate at `id.atlassian.com`.
- **403**: permissions issue. Name the project key and `$JIRA_USERNAME`.
- **404 on issue key**: do not retry with different casing — just report not-found.
- **429 rate limit**: show error, suggest waiting. Do not auto-retry.
- **Missing required user input**: HARD-GATE invariant 2 — stop and ask.

---

## Language

User-facing prompts, confirmations, and reports: **Polish**. Skill internals (this file, references): **English**.

Example confirm prompt: `"Tworzę? [y/n/edit]"` — not `"Create? [y/n/edit]"`.
