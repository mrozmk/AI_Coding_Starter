# Reference: token usage per ticket (`cost.py`)

A local, stdlib-only Python 3.9 tool in `.claude/lib/costs/`, shipped with the team harness. It
answers "how many tokens did this ticket (or epic) cost, by whom and on which model". It ingests
Claude Code transcripts and Codex rollouts after the fact, keeps a registry of ticket bindings and
prints a token table. Tokens only, no USD.

## Data and privacy

- Data lives **outside the repo** in `$AGENT_COSTS_HOME` (default `~/.agent-costs/`):
  `config.json`, `costs.sqlite` and `runtime.jsonl`. The code is in the repo, the data is not.
- **Metadata only** from transcripts and rollouts: usage numbers, session/turn/response ids,
  model, effort, cwd, timestamps, file provenance (path, line ordinal, line hash) and a restricted
  event argument — one ticket key or one `.agents/(specs|plans)/…md` path. Prompts, descriptions,
  message text, tool output, free-text args and Codex `creator_account_id` / `base_instructions`
  are never imported. The one free text the DB holds is what a human types into `bind --note`.
- Tests (in the starter, not distributed to projects): `bash .claude/lib/tests/cost-tests.sh`.

## Ticket keys

A key is one of the forms `config.py` accepts:

| Form | Example | When |
|---|---|---|
| tracker key | `ABC-123` | Jira and other `PROJECT-<n>` trackers |
| GitHub issue | `owner/repo#123` | tracker `github` |
| local id | `<repo>:L<n>` | tracker `none` (the repo dir name, sanitized) |

A team run records the short key in `team.json` `ticket` and the qualified one in `cost_key`
(`team_cost_key` in `.claude/lib/team-profile.sh`). Bind and report with the **qualified** key.

## Config

```bash
mkdir -p ~/.agent-costs
cp .claude/lib/costs/config.example.json ~/.agent-costs/config.json   # then edit the dirs
```

| Key | Meaning |
|---|---|
| `projects` | `{name: [abs dir…]}` — required. Claude slug = dir with every non-ASCII-alphanumeric character → `-`. The **first** dir is the main checkout, every later one a team clone |
| `claude_projects_dir` | default `~/.claude/projects` |
| `codex_homes` | default `[$CODEX_HOME or ~/.codex]` — a project with a declared `.claude/codex-profile` lists that home here, since `codex-bg.sh` and the team runner run Codex there; a rollout whose `session_meta.cwd` is not under a project dir is skipped, never stored (`codex_skipped=` in the summary) |
| `stage_skills` | top-level skills that open a `--by-stage` segment; default `prime`, `brainstorm`, `plan-feature`, `execute`, `check-implementation`, `qa-verify`, `pr-create`, `orchestrate`, `quick-change`, `pr-merge` |

A missing config exits 2 and names `config.example.json`.

## Runtime log

`$AGENT_COSTS_HOME/runtime.jsonl`, append-only, one JSON object per line, written only by
`.claude/lib/costs/runtime-mark.sh` (bash + jq). **Opt-in:** nothing is written unless the
`$AGENT_COSTS_HOME` dir exists; without it, or without `jq`, every writer is a silent no-op and
never fails its caller. Invalid optional fields are dropped; a line with an invalid required field
is skipped with a `runtime-mark:` reason on stderr. Stage names and agent names only — never args,
prompts or free text. `at` is UTC with milliseconds, like usage timestamps.

| `type` | Fields |
|---|---|
| `session` | `v`, `provider` (`claude`/`codex`), `session` (uuid), `source` (`team-run`/`start-team`/`mail-role`/`codex-bg`), optional `name`, `ticket`, `team`, `role`, `run`, `attempt`, `parent_session` (uuid), `cwd`, `at` |
| `stage` | `v`, `session` (uuid), `event` (`start`/`end`), `name`, `source` (`hook-skill`/`hook-prompt`/`skill-end`), optional `tool_use_id`, `at` |
| `subagent` | `v`, `session` (uuid), `agent_type`, `parent_model`, `model` (the model core started), `at` — all required |

| Writer | Writes |
|---|---|
| `team-run.sh` `launch` | `session` · `team-run`: the UUID it passes as `claude --session-id`, plus `runs/<run>/<role>-<attempt>.session` and `session.json` `session_id` |
| `codex-bg.sh` | `session` · `codex-bg`, provider `codex`: the thread id from the log header, `parent_session` = `$CLAUDE_CODE_SESSION_ID`, team fields from `.agents/team/session.json` |
| `/start-team` | `session` · `start-team`: the supervisor session with team and ticket — no name, so no label and not resolvable by name; never a binding |
| `mail-role` source | reserved for a role session's mail registration with `--name <NAME>` (labels and `bind --session NAME`); no shipped command writes it yet |
| `.claude/hooks/stage-mark.sh` | `stage`: `hook-skill` (PreToolUse `Skill`), `hook-prompt` (UserPromptExpansion of a typed `/command`), `skill-end` (PreToolUse of the exact end-step Bash call). Ignores every payload with `agent_id`, i.e. sub-agents |
| `subagent-model` mod | `subagent`: one line per spawn whose model it lowered; `cost.py` does not ingest it yet |

**`stage-mark.sh` is registered by `/setup:teams`** (`team-setup.sh`: PreToolUse `Skill`, PreToolUse
`Bash` filtered by `"if": "Bash(bash .claude/lib/costs/runtime-mark.sh stage end *)"`, and
UserPromptExpansion — synchronous, timeout 5), together with the writer's allow. `runtime-mark.sh`
itself is core: the core pipeline commands (the default stage list minus `pr-merge`, which is team)
end with its `stage end` step, which the core `settings.json` allows by that narrow rule and which
exits 0 silently before any dependency check. A project without the team harness has no hook, so it
writes no `stage` records and uses the transcript approximation under Stages below.

`collect` and `bind` ingest new lines into `registrations` (latest wins per provider × session ×
source) and `stage_marks` through the same incremental cursor as transcripts. A registered Codex
parent links a thread to its Claude session for lineage; a non-empty rollout `parent_thread_id`
stays authoritative.

## Commands

`cost.py` imports its sibling modules, so run it as `python3 .claude/lib/costs/cost.py` —
`python3 -I` drops the script dir from `sys.path` and fails on the first import.

```bash
python3 .claude/lib/costs/cost.py collect [--project NAME]
python3 .claude/lib/costs/cost.py bind <KEY> --session <uuid|registered name> [--share 0.5] [--provider claude|codex] [--note TEXT]
python3 .claude/lib/costs/cost.py bind <KEY> --turn <requestId|turn_id>
python3 .claude/lib/costs/cost.py bind <KEY> --window 2026-10-06T09:30:00Z 2026-10-06T12:00:00Z --cwd <dir|slug>
python3 .claude/lib/costs/cost.py bind <KEY> --team-run <clone dir> <run id>
python3 .claude/lib/costs/cost.py unassigned --since 2026-10-06 [--project NAME]
python3 .claude/lib/costs/cost.py report <KEY> [--with-children <KEY>,<KEY>] [--by-stage] [--format md|json|jira]
python3 .claude/lib/costs/cost.py report <KEY> [--with-children …] --jira-action <comments.json>
python3 .claude/lib/costs/cost.py summary [--days N | --since YYYY-MM-DD [--until YYYY-MM-DD]]
```

Exit codes: `0` ok · `2` usage/config error · `3` binding refused (overlap, bad share, bad
ticket) or Jira comment history incomplete · `4` no DB yet (run `collect` first). `summary`
exits 2 on a bad period (non-`YYYY-MM-DD` date, `--days` < 1, `--since` after `--until`,
`--until` without `--since`, `--days` with `--since`).

`--session` takes a uuid or a registered name (a `team-run` role's tmux name, or a `mail-role`
name); a name that matches no session, or more than one distinct session, exits 2 and lists the
candidates.

`collect` is incremental and idempotent. A second run with nothing new prints
`new_occurrences=0`.

**`--team-run`, key.** The binding is stored under the `<KEY>` you pass. The run's own key
(`team.json` `cost_key`, else the run record's `ticket`) is only compared with it: a mismatch
prints `cost: warning — run records name …, binding …` on stderr and still binds (exit 0). Pass
the qualified key — for a GitHub or tracker-`none` team that is `owner/repo#N` / `<repo>:L<n>`,
not the short `#N` / `L<n>`.

**`--team-run`, explicit path.** A run is complete when every `runs/<run>/<role>-<attempt>.prompt.md`
has a matching `.session` file with a uuid (a dead attempt's session counts too). A complete run
gets one `explicit` session binding per role session plus a **Codex-only** run window
(`provider=codex`, `inferred-window`) that catches threads with no registered parent; a registered
thread matches its role session explicitly and explicit beats window. All bindings of the batch
land together or not at all, and the clone's previous open team-run window is closed in the same
transaction. `--team-run` refuses `--share` and `--provider` (exit 2).

**`--team-run`, window path** (incomplete run, or one launched by an older runner — stderr says
why). The window runs from the run id's UTC start to the next run's start in the same clone
(`runs/` and `archive/*/runs/`). With no next run the window is open-ended: a role keeps billing
after its last `written_at`. Binding the clone's next run with `--team-run` closes it at that run's
start; until then it also collects that run's usage. Only team-run windows are closed this way.
The cwd is the clone dir, which must be a configured project dir. `--with-children` takes the
child list from the caller (read it from the tracker); the tool holds no tracker credentials.

## Semantics

**Dedupe keys.** Every sighting of a response is an *occurrence*. The canonical `usage` row is
recomputed from all occurrences of its key and does not depend on import order. The values come
from the occurrence with the highest `output`, then the latest `ts`. The owner is chosen by
provenance (Codex `thread_id`), otherwise by the session with the earliest `first_ts`, which
flags `ambiguous-owner`.

| Provider | Key | Fallback |
|---|---|---|
| Claude | `requestId` | `message.id`, else hash + `no-response-key` |
| Codex | `token_usage_record.response_id` | hash + `no-response-key`; `token_count` deltas keyed `tc:<thread>:<ordinal>` only for a thread with no own records |

**Normalization.** Total = `input + cache_write + cache_read + output`. Reasoning is
informational and never added to the total.

| Column | Claude | Codex |
|---|---|---|
| input | `input_tokens` | `input_tokens - cached_input_tokens` |
| cache_write | `cache_creation_input_tokens` | `cache_write_input_tokens` |
| cache_read | `cache_read_input_tokens` | `cached_input_tokens` |
| output | `output_tokens` | `output_tokens` |
| reasoning | `output_tokens_details.thinking_tokens` | `reasoning_output_tokens` |

**Coverage reasons.** A session is `partial` when it has any of the reasons below. A report row
is `partial` when any session contributing to it is, including the parent session of a
sub-agent.

| Reason | Meaning |
|---|---|
| `pending-partial-line` | the last line is not complete yet; it is picked up on the next collect |
| `bad-json` | a complete line did not parse; it was skipped |
| `missing-usage` | a response had no usage or no int `input_tokens`/`output_tokens`; no zero row was written |
| `no-response-key` | the response was keyed by a hash |
| `ambiguous-owner` | the same response appears in more than one session; the earliest owns it |
| `token-count-fallback` | Codex usage was derived from cumulative `token_count` |
| `counter-discontinuity` | a negative `token_count` delta: a new epoch, never zero-filled |
| `codex-cache-write-unverified` | Codex reported `cache_write_input_tokens > 0` |
| `history-starts-mid-session` | the rollout does not start with `session_meta` |

**Basis and precedence.** An explicit binding (session or turn) beats a window binding on the
same row. Within the winning class the shares must sum to ≤ 1, and the rest is `unassigned`.
Shares that sum to more than 1 put the whole row in `### Conflicts`. `bind` refuses a new binding
that would push any row over 1 within a provider partition. A provider-neutral binding counts in
both partitions.

| Basis | When |
|---|---|
| `explicit` | session or turn binding with share 1 |
| `manual-share` | any binding with share < 1 |
| `inferred-window` | window binding with share 1, including `--team-run` |

Lineage: Claude sub-agents share the parent `sessionId`. Codex child threads inherit their
parent's session binding through `parent_thread_id`, up to 5 levels.

**Report sections.** The header shows as-of (the latest included usage ts), the last collect,
the revision (git short sha plus schema version) and the coverage counts. The table is split by
provider × model × effort × agent (team/role split from `<team>-<role>`) × basis. It is followed
by `Unassigned (bound sessions)`, `Conflicts`, `Unknown coverage` (bindings that match no data;
a team run's idle Codex safety-net window is omitted once a sibling binding of that run matched)
and `Reconciliation`. Reconciliation compares the Codex per-thread provider counter with the
ingested sums. It is listed and never corrected.

**Stages (`--by-stage`).** Chosen per Claude main session.

- *Marker mode* — a session with at least one applied runtime stage mark (needs the registered
  `stage-mark.sh` hook, see Runtime log). Marks of skills on the stage list are replayed as a stack
  in `(ts, line)` order: `start X` pushes X (an X already on the stack is popped first, together
  with everything above it — those count as *inferred* ends); `end X` pops down to and including X
  (entries above it are inferred); an `end` with no matching start counts as *unmatched* and is
  otherwise ignored, so a stray end never switches a session to marker mode. Stages still open at
  the end count as inferred. A row's stage is the top of the stack after the last mark strictly
  before its ts, excluding the mark emitted by the row's own response (`tool_use_id` → transcript
  turn), so a streamed response stays on its side of the boundary. Marks whose `tool_use_id`
  belongs to a sub-agent's transcript are dropped.
- *Transcript approximation* — every other session: a stage is the segment after the last
  top-level stage skill invoked (`Skill` tool_use or a typed `/command`), because a transcript
  records invocation, not return. The response that emits a stage call stays in the previous stage.

Sub-agents land in the stage active at their parent's `Agent` call, linked via `meta.json`
`toolUseId`; workflow agents without that link land in the stage active at their first timestamp
(`outside-stage` only when that is unknown). Codex rows form the `codex` stage. The header names
how many of the report's sessions used each mode and their inferred/unmatched end counts — only
this report's sessions, since the runtime log spans every ticket. A command can close its stage
explicitly with a final step `bash .claude/lib/costs/runtime-mark.sh stage end <name>`, which the
hook records (the command itself writes nothing). The check row asserts Σ stages = Σ allocated.
Known limit: a listed skill invoked from inside another listed skill still opens its own segment.
`commit`, `push`, `code-review`, `deep-review`, `gates:*` and `codex-review` are not on the default
list.

## Summary (/ai-costs)

`/ai-costs` runs `collect`, then `cost.py summary`, and prints the markdown verbatim. It creates no
bindings, posts nothing and prices nothing; `collect` does refresh the local DB for every
configured project. The summary's headings and labels are Polish (`Razem`, `Pełna stawka`, …).

- **Period** — whole UTC days, `--until` inclusive: rows with `since 00:00Z <= ts < (until + 1
  day) 00:00Z`. Default `--days 30` (today and the 29 days before); `--since` alone ends today.
  Rows with no `ts` fall outside every period. Local days differ from UTC days at the edges.
- **Metrics** — *Razem* = input + cache write + cache read + output (the report's `Total`);
  *Pełna stawka* = input + cache write + output (cache read is billed at ≈ 0.1× input);
  *cache hit* = cache read / (input + cache write + cache read), `-` when that is 0. Codex
  `input` is already net of cached input, so the formulas hold for both providers.
- **Scope** — the **first** dir of each configured project is its main checkout, every later dir
  a team clone (keep the main dir first in `config.json`). A row whose `cwd` is under a clone
  (longest match wins) is *team*; a Claude session registered by `team-run` is *team* too;
  everything else is *supervisor*.
- **Roles** — Claude: the report's agent label / `team-run` registration. Codex: the allocator's
  lineage (`parent_thread_id` chain → registered Claude parent) first; with no linked role, the
  latest `team-run` registration in the thread's clone at or before the thread's **earliest own
  usage** `ts` → `<role> (inferred)` (never `sessions.first_ts`, which replayed parent history
  lowers); otherwise `-`.
- **Tickets** — the same allocation as `report`; a conflicting row counts toward no ticket. `⚠ <n>
  klony` flags a ticket whose team rows span several clones.
- **Lowest cache hit** — groups (provider, session, agent) with Razem ≥ 1 M only, 10 lowest.
- **Supervisor sessions** — Claude supervisor rows per session; *Śr. kontekst / wywołanie* and
  *Wywołania* count the main thread only (sub-agent calls would dilute it); *Czas* = last − first
  `ts` inside the period.
- **Coverage footer** — share of Razem not bound to a ticket, partial sessions in the period,
  `codex_skipped` files, last collect, the scope rule. An empty period prints `no data` (exit 0).

## Example workflow

Use your configured clone directory and an actual run ID from its `.agents/team/runs/` or
`.agents/team/archive/<ticket>-*/runs/` directory. Run IDs have the form
`<team>-<YYYYMMDD>-<HHMMSS>`; replace the placeholders before invoking the CLI.

```bash
python3 .claude/lib/costs/cost.py collect
python3 .claude/lib/costs/cost.py bind ABC-123 --team-run /path/to/project-alfa <run-id>
python3 .claude/lib/costs/cost.py report ABC-123 --by-stage
```

The clone directory must be listed in `projects`. `--window` clock values require `Z` or an
explicit UTC offset (for example, `+02:00`); date-only values still mean midnight UTC.
For Codex counter fallback, reconciliation subtracts the last replayed counter before the
child's history boundary. Explicit response counters retain their reported totals. Actual
counter discontinuities and mismatches remain visible; reconciliation never repairs usage.

`bash .claude/lib/test-gate.sh` runs `.claude/lib/tests/cost-tests.sh` first **when that file is
present** — it is in the starter but not in the distribution (the manifest excludes the harness
tests) — then the project's own gate (`teams.test_gate` in `.claude/project-profile.json`).

## Jira comment

For Jira-tracked tickets. The tool never posts; the model runs the Jira MCP call it recommends.
One report comment per ticket, found by its first line `token-usage-report: <KEY>` (whole-line
match).

1. Fetch: `mcp__atlassian__jira_get_issue(issue_key, fields="summary", include="comments",
   comment_limit=100)`.
2. Save the JSON result (raw or MCP-wrapped `{"result": "<json>"}`) to the scratchpad.
3. `python3 .claude/lib/costs/cost.py report <KEY> [--with-children …] --jira-action <file>`
   prints `{"action": "add"|"edit", "comment_id", "duplicates", "body"}`.
4. `add` → `jira_add_comment(issue_key, body)`; `edit` → `jira_edit_comment(issue_key,
   comment_id, body)`. Mention `duplicates` to the user; never delete them.
5. Exit 3 (a full page of 100 comments with no marker — older ones may be hidden) → ask the human
   for the report comment's id. Exit 3 on an empty comment list too: mcp-atlassian also returns
   `[]` when the comments API fails, so an empty read is never trusted — check the ticket and, if
   it really has no report comment, post the body with `jira_add_comment` by hand (the next run
   finds the marker and edits). Every saved comment must carry `id` and `body`; a mis-saved file
   exits 2.

The body (`--format jira`) omits the collect and children-lookup times, so it is identical across
re-runs on unchanged usage and bindings. The report comment is tool-owned: a human edit that keeps
the marker line is overwritten by the next `edit`.

## Not implemented

USD pricing; a dashboard view; Codex rows in their parent's stage; a report comment for trackers
other than Jira; stage marks in a project without the team harness (no hook there).
