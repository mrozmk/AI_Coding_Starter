# 06 — Permissions, the tier-1 prompt check, classes, `teams.policy`

**Contract:**
- [`team-mode.md` §10](../../.agents/reference/team-mode.md#10-escalation-tiers): the permission-prompt rules and the accepted limits.
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

## The tier-1 prompt check

`team_prompt_check.py` decides whether the TeamLead may press Enter on a team role's permission prompt. It answers *yes* (tier 1) only when all of these hold:

- the prompt's command is readable;
- the command names no egress tool and is not a web fetch;
- nothing in the prompt matches an `ask` or `deny` rule of the clone's settings;
- the destructive-SQL guard is quiet;
- the command edits no settings file;
- every path resolves inside the clone.

Rules are matched against the line, each command segment and the canonical form of every command. In the canonical form, quoting is removed, wrappers such as `env`/`sudo`/`nohup` are stripped, shell paths are reduced to their basename and nested `bash -c`/`eval` strings are parsed, so a rule cannot be bypassed by respelling. Anything it cannot lex or resolve is refused and goes to the Operator. Its `--report` mode always exits 0 and is a description, never an authorisation.

**Accepted limits.** The matcher approximates the host's permission matcher, and the live `/permissions` view is the truth. A line continuation can split an anchored deny in the host's matcher. A command built at run time (a `$VAR`, a path after `cd`) is refused rather than guessed.

## Deterministic classes

A class is the single deliberate exception to "an ask-tier prompt is never auto-approved": a refusal whose **only** cause is ask-tier matches is waived when the prompt belongs to one enabled class. Deny, egress, the SQL guard and unreadable prompts are never waived. The class is recorded in the ledger and listed in the READY note.

| Class | What qualifies |
|---|---|
| `merge-line` | the clone's `git merge` of its target line into the team branch (it may run local hooks and merge drivers: local code, not egress) |
| `allow-offline` | a settings edit adding only offline single-file allow entries (`bash -n`, `shellcheck`) for files in the ticket's diff; *running* a script stays the Operator's click |
| `add-ask` | a settings edit adding only ask entries |
| `prod-diagnose` | a named read-only diagnose script from a directory the project names |

Each class trusts the main checkout's `.git`, `CLAUDE.md` and the team's anchor file. A clone whose identity differs from its anchor gets no class.

> **Current state (read before relying on a class).** In the current engine every class is
> **on** unless the Operator switches it off (`team-watch.sh mode class <name> off`), and
> `prod-diagnose` exists only when its directory is configured. Making every class **off until
> the profile enables it** is the next change to this layer (`teams.policy.classes.<name>.enabled`
> below). Until then, the `enabled` flags in the example are documentation, not behaviour.

## `teams.policy`

Project policy for the supervision model, in the committed `.claude/project-profile.json`. Every key is optional. An absent key gives the conservative behaviour stated in its `_doc`, never a project's values. The example in [`project-profile.json.example`](../../.claude/project-profile.json.example) shows one project's choices to adopt consciously:

| Key | Meaning | Absent |
|---|---|---|
| `sensitive_paths` | globs whose changes make a question tier 2 and a QA warning the Advisor's | `CLAUDE.md → Validation → Test policy` is the list. **Judgement input in v1**: the TeamLead and the Advisor classify by it; no script enforces it yet ([follow-ups](follow-ups.md) F18) |
| `classes.<name>.enabled` (`merge_line`, `allow_offline`, `add_ask`, `prod_diagnose` + `dir`, `privileged`) | which deterministic classes may waive an ask-tier match | off — see the current-state note above |
| `tickets` (`auto_label`, `path_labels`, `recommendation_line`, `new_epic_when_none_fits`) | labels and lines on tickets created from recommendations | no labels; the recommendation line is still written |
| `closure` (`done_after_release_minutes_without_5xx`, `dry_run_max_days`, `on_hold_after_days`) | automatic ticket-closure rules | no automatic closure |

Profile keys are snake_case (`merge_line`). The class names in the ledger and in the Operator's words stay hyphenated (`merge-line`).

**Not policy.** The tier precedence, "unsure → higher tier", "a failure is never consent", the Operator-action block, the reply header and the policy-log formats are part of the engine, and no config changes them.
