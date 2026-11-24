# `/create-task` — the Jira route

`/jira` is the one Jira create path: `/create-task` hands the draft to `/jira` Flow A (the `Skill`
tool, skill `jira`, args `create …`) and never calls an Atlassian MCP create tool itself.

## Field mapping

| Draft | Jira field |
|---|---|
| title | summary |
| the body without the intent line and the `# <title>` line | description — handed over **already rendered**: Flow A uses it verbatim instead of generating one from its template |
| `bug` | issue type `Bug` |
| `enhancement` or `none` | issue type `Task` |
| `--parent <KEY>` | the Epic (`parent_epic_key`) — verified and kept by `/jira`, also for a Bug |
| `--label` values | `labels` — with `--type none` (a recommendation) handed over as complete, so `/jira` adds no `$JIRA_DEFAULT_LABELS` |

Everything else stays `/jira`'s: the required fields (project, the Epic for a Task, a Bug's Epic
resolution), components, attachments, the dry-run table with the whole description and the explicit
`y`, and the shipped `ask` on the Jira create tools. The no-prompt guarantee of `/create-task` is
GitHub's only.

## Status

`--status started` → `/jira` Flow G after the create, only on the user's word — no automatic
transition.

## `--dry-run`

Print the mapped fields and list as unresolved: `project`, `Epic` (for a Bug: resolved by `/jira` at
send), `components`. A supplied `--parent` shows as "supplied — verified by `/jira` at send", not as
unresolved. No MCP call.

## After the create

The report carries the key `/jira` returned and `created via /jira Flow A`. A failed follow-up step
(attachment, transition) is finished **on that key** — a Jira draft is never replayed, it would
create a second issue.
