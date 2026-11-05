# Upgrade notes — team layer

Changes that need an action, or a second look, in a project that already runs the team layer.
Newest first.

## The agent-mail tool copy is named by its content

**Before:** the channel step named the copy under `~/.agent-mail/tools/` after the vendored
tool's commit (`agent_mail-<7 hex>`), refused an uncommitted tool, and gave a second project a
second copy of identical content. A `~/…` value in `.claude/codex-profile` was stored as
`$HOME/~/…`.

**Now:** the copy is `agent_mail-<12 hex>`, a hash of the runtime files' names and bytes. A fresh
install finishes in one run, and identical tools share one copy. `~/…` is stored under `$HOME`.

**Action:**

- `bash .claude/lib/team-mail.sh --here check` reports `tool behind checkout (<old> → <new>)` once
  for an entry that still points at a commit-named copy, even when the content is the same. The
  re-sync is an Operator action, as before: run the command the line prints (`--resync-tool`).
  It repoints the entry to the content-named copy; the old directory stays until you remove it.
- An entry or `channel.local.json` whose `codex_home` contains `/~/`: re-run the channel step
  (`/setup:teams`) or correct the path by hand to the real directory.

## Permission classes are off until the profile enables them

**Before:** every deterministic class (`merge-line`, `allow-offline`, `add-ask`, `prod-diagnose`)
was **on** unless the Operator switched it off. `prod-diagnose` existed as soon as its `dir` and
`privileged` were set.

**Now:** a class is active only when `.claude/project-profile.json → teams.policy.classes.<name>.enabled`
is exactly `true` **and** its runtime switch is not off. `team_prompt_classes.py switches <main>`
prints `disabled` for a class the profile does not enable.

**Action:** if your TeamLead relied on a class, enable it in the profile:

```json
"teams": { "policy": { "classes": {
  "merge_line":    {"enabled": true},
  "allow_offline": {"enabled": true},
  "add_ask":       {"enabled": true},
  "prod_diagnose": {"enabled": true, "dir": "scripts/ops/", "privileged": "<regex>"}
} } }
```

What you will see otherwise: ask-tier prompts that used to be answered at tier 1 become Operator actions (`class <name> not enabled`), and the auto-merge gate refuses a PR that adds offline allow entries.

## Protocol headings are English

The headings one file writes and another reads are now fixed English. Prose under them follows the profile's `language` (`pl` | `en`). A run whose wrapup was written before the upgrade keeps the old headings. Read them with this map:

| Old (Polish) | New |
|---|---|
| `## Planowanie` | `## Planning` |
| `## Co ważne dla Ciebie` | `## What matters for you` |
| `## Decyzje nadzorcy` | `## Supervisor decisions` |
| `## Pamięć odłożona (B)` | `## Deferred memory (B)` |
| „Decyzje TeamLead” (READY note section) | "TeamLead decisions" |
| `Decyzje nadzorcy: <n> …` (READY count line) | the same line, in the developer's language |
| `Mergować <team>?` | `Merge <team>?` |
| `Advisor bez odpowiedzi (<reason>)` | `Advisor no reply (<reason>)` |
| dashboard `czeka na odpowiedź` | `waiting for an answer` |

The Operator's words are English (`approve`, `reject`, `answer`, `revoke`). The Polish forms (`zatwierdź`, `odrzuć`, `odpowiedz`, `cofnij`) stay accepted as aliases.
