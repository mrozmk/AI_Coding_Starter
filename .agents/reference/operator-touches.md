# Reference: Operator touch log

Every time a human had to act for a session — answer a team's TeamLead decision, clear a startup
dialog, click a permission prompt, restart something — one structured line is recorded locally, per
project and machine. The log is a list of causes to fix: recurring stops show up as clusters and
become tickets. It is not a percentage, a dashboard or a performance number.

Writer, reader and hook: `.claude/lib/touches.py`, run through `.claude/lib/touches.sh`
(`add | report | hook`) and the Notification hook `.claude/hooks/touch-notify.sh`.

## Storage

- `<main checkout>/.agents/touches/<yyyy-mm>.jsonl` — one file per UTC month (the month of the
  entry's `at`), one JSON object per line.
- Per project **main checkout**: team clones and worktrees write into the main checkout's file,
  never their own (see **Main checkout**). One machine keeps one log per project.
- Git-ignored (`.agents/touches/` is in the template's `.gitignore`); local only. Each developer
  and machine keeps their own log; nothing is merged or shared between machines.
- Appends are a single `write` of a line under 4 KiB to a file opened `O_APPEND`, so concurrent
  sessions never interleave lines. The directory and file are opened through pinned directory
  fds: a symlinked `.agents/touches`, a FIFO or a hard-linked month file is refused, never written.

## Entry

Keys, in this order:

| Field | Type | Cap | Meaning |
|---|---|---|---|
| `at` | string | — | UTC `YYYY-MM-DDTHH:MM:SSZ` of the record |
| `machine` | string | 100 | short host name, `[A-Za-z0-9._-]` only |
| `who` | string | 100 | `$USER`, same filter |
| `where` | string | 200 | `team <team> / <ticket> / <role>` (role `TeamLead` for the lead) or `solo <path relative to the main checkout>` (`solo .` at its root, `solo ?` outside it) |
| `kind` | string | — | what stopped: `question` · `permission` · `plan` · `text` · `decision` · `restart` · `other` — or `block`: a hook refused a call with no human involved (written only by `touches.sh block`; never an Operator touch) |
| `what` | string | 200 | one line: the question, or `<tool>: <command or path>` |
| `reason` | string | — | why a human was needed (below) |
| `answer` | string | 200 | the human's words, or `allow` / `deny` / `deny: <instead>`; empty when unknown |
| `wait_s` | int or null | — | seconds from the stop to the answer, when known |
| `relayed_by` | string, optional | 60 | `Supervisor` when the Supervisor relayed the Operator's answer (`team-lead.sh decision relay`); absent otherwise |
| `relayed_session` | string, optional | 100 | the Supervisor's session id for a relayed answer; absent otherwise |

Reason codes — the field reports group by — and who assigns each:

| Reason | Meaning | Assigned by |
|---|---|---|
| `human-only` | a decision only a human may make (operator-tier ask, plan gate, abandon) | the TeamLead at `decision open` (`--reason`, or the derived default) |
| `no-rule` | the lead had no rule or digest line for it | the TeamLead at `decision open` (the default otherwise) |
| `lead-unsure` | a rule existed, the lead escalated anyway | the TeamLead at `decision open` |
| `channel-failed` | a lead-run stage waited at a permission prompt no ask covered | the Notification hook |
| `guard` | a guard stopped a Supervisor session for the Operator | the egress guard ([security-egress.md](security-egress.md)) |
| `direct` | a human acted in a stage window or a solo session without a lead asking | the Notification hook, the dialog watch, a manual `add` |
| `hook` | no human: a PreToolUse hook refused the call (exit 2) and the session had to retry another way — only with `kind: block` | `touches.sh block`, called by the refusing hook |

## Main checkout

`touches.sh` resolves the main checkout in this order, first match wins:

1. `--main <dir>` when it is a directory with `.agents/`;
2. `$HARNESS_MAIN` (same check);
3. in a team clone (`.agents/team/team.json` at the git toplevel): `teamlead.json` → `main_root`
   (same check), else **unknown** — a clone never writes its own log;
4. otherwise the primary worktree of the repository (`git rev-parse --git-common-dir`'s parent),
   so a linked worktree writes into its main checkout;
5. none → unknown: `add` exits 1, the hook stays silent.

`HARNESS_MAIN` wins step 2 — a role session inherits it, so a test or a by-hand proof must unset it.
The global opt-in skips steps 1–3 (see **Global opt-in**).

## Writers

| Writer | When | Entry |
|---|---|---|
| `team-lead.sh decision answer` | a human answered a TeamLead decision | `kind` from the bound ask (`question`/`permission`/`plan`/`text`), else `plan` for a `--gate plan`, else `decision`; `reason` = the decision's `touch_reason`; `what` = the question; `answer` normalised for a permission/plan ask; `wait_s` = answered − created; `where` = `team <team> / <ticket> / <stage>` |
| the runner's dialog watch (`team-run-dialog.sh`) | a TeamLead or stage session first seen at the folder trust or MCP servers dialog | `other` / `direct`, `startup dialog <trust\|mcp> in <role>`; once per session and dialog kind (`runs/<run>/<decision>-<kind>.touched`) |
| the Notification hook (`touch-notify.sh`) | any session, team or solo, waits at a permission prompt | `permission`, `direct` — or `channel-failed` in a lead-run stage no ask covered |
| the egress guard (`record_touch`) | a Supervisor main-checkout session is stopped for the Operator | `permission` / `guard`; its shell fallback writes `where: "solo ?"` |
| a refusing PreToolUse hook (`touches.sh block --source <hook> --what <text>`) | the hook exits 2: guard-push, guard-team-verdict, guard-teamlead-bash, guard-teamlead-write, guard-memory, guard-team-memory, guard-jira-transition | `block` / `hook`, `what` = `<hook>: <text>`, `answer` empty, `wait_s` null; fire-and-forget — always exit 0, never output, a missing log or main checkout is a silent no-op; `TOUCHES_BLOCK_OFF=1` (set by `team-suite.sh`) stands it down, since test fixtures point `main_root` at the real checkout |
| by hand: `touches.sh add` | anything else that reached the Operator (a restart, a manual fix) | as given; the Supervisor passes `--where "team <team> / <ticket> / <role>"` for a team's matter so its wrapup counts it |

Every scripted caller survives a missing or failing `touches.sh`: one `warn: touch not recorded
(<source>)` line, the caller's own result unchanged.

**Not a touch:** an answer the Supervisor gives as a delegate under the Operator's mandate
(`team-lead.sh decision answer --delegated`). No human acted, so it writes no entry here and no
`operator-touches` line; `bash .claude/lib/team-mandate.sh answers` lists those answers on their own.

## Readers

- `touches.sh report [--since YYYY-MM-DD|<n>d] [--who U] [--reason R]` (default the last 30 days):
  groups by `reason` × `kind` × `where`, newest group first, then `Recurring` — up to five clusters
  of two or more entries with the same reason and a similar `what` (lowercased, quotes dropped,
  digits as `#`, first 48 characters). The hook's generic fallback text never forms a cluster.
  A malformed or ill-typed line is skipped and named on stderr (`skipped: <file>:<line> — <why>`),
  never fatal. `kind: block` lines are **not** Operator touches: they stay out of the header count,
  the groups and `Recurring`, and get their own section `Hook blocks (no human) — <n>` with up to
  five clusters of two or more (same similarity rule) — the shapes a session keeps hitting.
  `--brief` never counts them.
- `touches.sh report --brief --team T --ticket K --run RUN`: the run's count from the run id's
  timestamp (`Operator touches: <n> — <a>× <reason> (<kind>), …`), then `Recurring:` lines for
  clusters of three or more over the whole log that the run contributed to. The wrapup publishes
  **only the count line**; the `Recurring:` lines are local context, never a ticket on their own
  (the wrapup's follow-up bar drafts tickets only from `→ follow-up` lines of the acceptance brief),
  and are never pasted anywhere (a log example may come from another run or a solo session).
- `/tasks-status` shows the last seven days' header and top rows when a log exists.

## Dedup and limits

- **Lead-run stages.** A stage of a run with a per-run TeamLead files its permission prompts as asks
  ([team-lead.md](team-lead.md) §6); the decision path records any human answer. The hook waits a
  15-second grace (`TOUCHES_GRACE_S`; async, so the session never waits) and then applies the
  runner's `lead_ask_near` rule, narrowed: a `permission` ask of the same session, role and attempt
  that is waiting or was filed or delivered within 10 s covers the prompt (a differing tool name
  does not). Covered → no entry; not covered → one `channel-failed` entry. A waiting question of
  the same stage does not hide a separate permission prompt. An ask that fails open after the
  hook's check is not recorded.
- **Guard and prompt.** A `direct` prompt within 10 s of a `guard` entry with the same `machine` and
  `where` is not written — best effort: two stops in that window from the same place collapse into
  one, and a guard line written after the hook's check is not seen.
- **Run ledger.** `runs/<run>/operator-touches` (team-lead.md §10) stays the run's own count of
  human-answered decisions and dialogs; it has no permission prompts. This log is the
  project-wide, cross-run view.
- Volume stays small: one short line per touch, no roll-up. A monthly file that grows large is a
  signal to fix causes, not to rotate.

## Privacy

- Every text field is one line, at most 200 characters (`machine`, `who` at 100); control
  characters become spaces.
- Secrets are masked before the cap: labelled values (`password=…`, `"token": "…"`,
  `DB_PASSWORD=…`, `AccessKey=…;`, quoted values with escapes or doubled quotes, even when cut
  before the closing quote), secret flags (`--password …`, `--sas-token …`), `Bearer …`, and
  known token formats by prefix (`ghp_…`, `github_pat_…`, `sk-ant-…`, `AKIA…`, `xox?-…`,
  `glpat-…`, `AIza…`, `npm_…`, private key blocks, credentials in a database URL) — a token cut
  short by an earlier truncation is still masked. Pattern-based: a floor, not a guarantee.
- No transcript, prompt or full answer is stored; the hook reads only the pending tool call's name
  and its command, path or URL.
- Log examples are never published: the wrapup shares only counts.

## Global opt-in

Projects without this workflow can record permission prompts too, from the user's own settings:

1. Copy `.claude/lib/touches.py` to `~/.claude/touches/touches.py` (the one file; stdlib only).
2. Add to `~/.claude/settings.json`:

```json
{ "hooks": { "Notification": [ { "matcher": "permission_prompt", "hooks": [
  { "type": "command", "command": "python3 -I \"$HOME/.claude/touches/touches.py\" hook --global", "async": true }
] } ] } }
```

With `--global` the hook:

- stands down in a project that ships `.claude/hooks/touch-notify.sh` (its own hook records) and
  outside a git checkout;
- resolves the main checkout only from the project's own repository (no `HARNESS_MAIN`, no
  `teamlead.json` redirect);
- never writes a tracked month file, and never writes until git ignores the exact month file: it
  first adds `.agents/touches/` to the checkout's `info/exclude` (refusing a symlinked or
  hard-linked exclude file), then checks again.
