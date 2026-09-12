# JQL Cookbook

Common queries for use with `jira_search`. The skill can map short keywords (first word of `$ARGUMENTS` after `search`) to these snippets.

`$JIRA_DEFAULT_PROJECT` is substituted at runtime by the skill. `currentUser()` is a built-in Jira function for "me — the authenticated API user".

---

### `open-bugs` — My open bugs in the default project

```jql
project = $JIRA_DEFAULT_PROJECT AND issuetype = Bug AND statusCategory != Done AND assignee = currentUser() ORDER BY priority DESC, created DESC
```

### `open-tasks-epic` — Open tasks under a given Epic

Arg: `EPIC-KEY` (e.g. `PROJ-100`). Skill substitutes.

```jql
parent = EPIC-KEY AND statusCategory != Done ORDER BY created ASC
```

Note: on legacy Cloud instances without the `parent` field, replace `parent = EPIC-KEY` with `"Epic Link" = EPIC-KEY`.

### `my-recent` — Issues I created in the last 7 days

```jql
reporter = currentUser() AND created >= -7d ORDER BY created DESC
```

### `unassigned-open` — Unresolved issues with no assignee in default project

```jql
project = $JIRA_DEFAULT_PROJECT AND resolution = Unresolved AND assignee is EMPTY ORDER BY priority DESC
```

### `recent-activity` — Issues changed in the last 24 hours (any project)

```jql
updated >= -24h ORDER BY updated DESC
```

### `sprint-current` — Issues in the active sprint of the default project

Requires the project uses Scrum sprints.

```jql
project = $JIRA_DEFAULT_PROJECT AND sprint in openSprints() ORDER BY rank
```

### `high-prio-bugs` — Open high-priority bugs (any assignee)

```jql
project = $JIRA_DEFAULT_PROJECT AND issuetype = Bug AND priority in (Highest, High) AND statusCategory != Done ORDER BY priority DESC, created ASC
```

### `blocked` — Issues blocked by another issue

```jql
project = $JIRA_DEFAULT_PROJECT AND issueLinkType = "is blocked by" ORDER BY priority DESC
```

### `sub-tasks-of` — Sub-tasks of a given parent (for lookups only — this skill does not create sub-tasks)

Arg: `PARENT-KEY`.

```jql
parent = PARENT-KEY ORDER BY created ASC
```

### `label` — Issues with a specific label in default project

Arg: `label-name`.

```jql
project = $JIRA_DEFAULT_PROJECT AND labels = "label-name" ORDER BY updated DESC
```

### `no-components` — Open issues without components assigned

```jql
project = $JIRA_DEFAULT_PROJECT AND components is EMPTY AND resolution = Unresolved ORDER BY created DESC
```

### `due-soon` — Issues with a due date within the next 7 days

```jql
project = $JIRA_DEFAULT_PROJECT AND duedate >= now() AND duedate <= 7d AND resolution = Unresolved ORDER BY duedate ASC
```

### `resolved-this-week` — Closed issues resolved this calendar week

```jql
project = $JIRA_DEFAULT_PROJECT AND resolved >= startOfWeek() ORDER BY resolved DESC
```

---

## Usage notes

- Default page size: 50 (Jira Cloud cap per request). Use `start_at` for pagination.
- Always request the `fields` you need, comma-separated: `jira_search(jql=..., fields="summary,status,assignee,priority,parent", limit=50)`.
- If the JQL has no `project` clause and `$JIRA_DEFAULT_PROJECT` is set, the skill prepends `project = $JIRA_DEFAULT_PROJECT AND (...)` automatically to avoid slow cross-project searches.
- `statusCategory != Done` is more robust than `status != Done` — `status` names vary per workflow, `statusCategory` is one of three built-ins (`To Do`, `In Progress`, `Done`).
