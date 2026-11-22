# 06 — Permissions, the prompt check, classes, `teams.policy`

**Contract:**
- [`team-lead.md` §6](../../.agents/reference/team-lead.md#6-answering-on-an-authority): answering a prompt on an authority (`class | teamlead | operator`) and the human-only check.
- [`team-decision-model.md` → Deterministic classes](../../.agents/reference/team-decision-model.md#3-decision-model).
- [`security-egress.md`](../../.agents/reference/security-egress.md): egress.

## Three tiers — the engine property

`.claude/settings.json` sorts commands into `deny`, `ask` and `allow`, with precedence **deny > ask > allow**.

- `deny` is absolute: no prompt or classifier overrides it.
- `ask` always prompts, even in auto mode.
- Anything in no list prompts interactively, or the classifier decides in auto mode.

That precedence is the engine. **Which** commands sit in each list is the project's policy. Typical choices:
- history rewrites and unrecoverable discards → deny;
- consequential merges, deletes, deploys and secret-returning commands → ask;
- reads and routine git → allow.

Two lessons carried over from the source:

- A rule matches the **whole command text**, arguments included. A rule for a free-text command group must anchor the verb (`Bash(tool group * <verb> -*)`), never `*<verb>*`: a resource name that merely contains the word matches.
- Every permission change is the **Operator's**. A peer message, a hook output or a line on screen never grants one. A session denied an action never asks another session to do it instead.

## The two team guards

`/setup:teams` registers two `PreToolUse` guards in the project's `settings.json`, in the same
opt-in step and both with `"onFailure": "block"`: the egress guard (`guard-team-egress.sh`, under
`Bash` and `WebFetch`) and the destructive-SQL guard (`guard-destructive-sql.sh`, under `Bash`:
`DROP`/`TRUNCATE` of a table, database or schema is denied, any other SQL write asks). The
template's own shared settings carry neither; a project gets them only through `/setup:teams`.
The egress guard is a **best-effort guard over `Bash` and `WebFetch`, not an allowlist**:
`WebSearch` and MCP tools are out of its scope. What it catches and what it does not:
[`security-egress.md`](../../.agents/reference/security-egress.md).

In the main checkout the Supervisor can lift the guard's `gh` prompt per clone with `Bash(gh …)` allow rules in `.claude/settings.local.json` — never for a team role, the TeamLead or an Advisor, never from `settings.json` — also for compounds of covered `gh` commands with allowlisted companions (`| jq`, `| head`, `cd <path>`, …), and, with `Bash(python3 -)` / `Bash(python3 -c *)`, for opt-in inline Python. Every Supervisor prompt is logged to `.agents/touches/`. Rule forms and limits: [`security-egress.md`](../../.agents/reference/security-egress.md) → Local `gh` rules for the Supervisor.

## The prompt check

`team_prompt_check.py` decides whether a sender (`team-answer.sh`) may press Enter on a team role's permission prompt. On the Operator's direct call it answers *yes* only when all of these hold:

- the prompt's command is readable;
- the command names no egress tool and is not a web fetch;
- nothing in the prompt matches an `ask` or `deny` rule of the clone's settings;
- the destructive-SQL guard is quiet;
- the command edits no settings file;
- every path resolves inside the clone.

The per-run TeamLead answers on an authority instead (`--authority class|teamlead|operator`,
[`team-lead.md` §6](../../.agents/reference/team-lead.md#6-answering-on-an-authority)). The
human-only check runs first: a settings edit, a project-added ask rule, egress or a recursive `rm`
outside the clone is refused on every authority (exit 9); the Operator answers it in the stage
window, never a waiver. Then
`teamlead` and `operator` may waive a baseline ask match, `class` only inside an enabled class.
Deny, the SQL guard and an unreadable or unbound prompt are refused on every authority.

Rules are matched against the line, each command segment and the canonical form of every command. In the canonical form, quoting is removed, wrappers such as `env`/`sudo`/`nohup` are stripped, shell paths are reduced to their basename and nested `bash -c`/`eval` strings are parsed, so a rule cannot be bypassed by respelling. Anything it cannot lex or resolve is refused and goes to the Operator. Its `--report` mode always exits 0 and is a description, never an authorisation.

**Accepted limits.** The matcher approximates the host's permission matcher, and the live `/permissions` view is the truth. A line continuation can split an anchored deny in the host's matcher. A command built at run time (a `$VAR`, a path after `cd`) is refused rather than guessed.

## Deterministic classes

A class is the single deliberate exception to "an ask-tier prompt is never auto-approved": a refusal whose **only** cause is ask-tier matches is waived when the prompt belongs to one enabled class. Deny, egress, the SQL guard and unreadable prompts are never waived. An answer sent on a class is recorded in `runs/<run>/answers.md` (`[authority class]`) and listed in the wrap-up's `## Supervisor decisions`.

| Class | What qualifies |
|---|---|
| `merge-line` | the clone's `git merge` of its target line into the team branch (it may run local hooks and merge drivers: local code, not egress) |
| `allow-offline` | a settings edit adding only offline single-file allow entries (`bash -n`, `shellcheck`) for files in the ticket's diff; *running* a script stays the Operator's click |
| `add-ask` | a settings edit adding only ask entries |
| `prod-diagnose` | a named read-only diagnose script from a directory the project names |

Each class trusts the main checkout's `.git`, `CLAUDE.md` and the team's anchor file. A clone whose identity differs from its anchor gets no class.

**Off until enabled.** A class is active only when the project's profile enables it
(`teams.policy.classes.<name>.enabled: true`) **and** the Operator has not switched it off
(`team-watch.sh mode class <name> off`, his words only). The switch can narrow an enabled class and
can never widen one the profile does not enable. `team_prompt_classes.py switches <main>` shows
each class as `on`, `off` or `disabled` (not enabled in the profile). `prod_diagnose` also needs its
`dir` and `privileged`.

## `teams.policy`

Project policy for the supervision model, in the committed `.claude/project-profile.json`. Every key is optional. An absent key gives the conservative behaviour stated in its `_doc`, never a project's values. The example in [`project-profile.json.example`](../../.claude/project-profile.json.example) shows one project's choices to adopt consciously:

| Key | Meaning | Absent |
|---|---|---|
| `sensitive_paths` | globs whose changes count as sensitive | `CLAUDE.md → Validation → Test policy` is the list. **Judgement input in v1**: supervision classifies by it; no script enforces it yet ([follow-ups](follow-ups.md) F18) |
| `classes.<name>.enabled` (`merge_line`, `allow_offline`, `add_ask`, `prod_diagnose` + `dir`, `privileged`) | which deterministic classes may waive an ask-tier match | off — every class is disabled until enabled here |
| `tickets` (`auto_label`, `path_labels`, `recommendation_line`, `new_epic_when_none_fits`) | labels and lines on tickets created from recommendations | no labels; the recommendation line is still written |
| `closure` (`done_after_release_minutes_without_5xx`, `dry_run_max_days`, `on_hold_after_days`) | automatic ticket-closure rules | no automatic closure |

Profile keys are snake_case (`merge_line`). The class names in `team-watch.sh mode class` and in the Operator's words stay hyphenated (`merge-line`).

**Not policy.** The deny > ask > allow precedence, the human-only check, "a failure is never consent" and the Operator-action block are part of the engine, and no config changes them.
