# Upgrade notes — team layer

Changes that need an action, or a second look, in a project that already runs the team layer.
Newest first.

## The agent-mail tool's default project label is `default`

**Before:** the vendored tool kept the upstream's own project name as its default label (the
CLI's `--project` default, the `messages.project` schema default, the store's `project=`
defaults).

**Now:** the default is `default`. The tool's content changed, so `check` reports `tool behind
checkout` for an entry whose `agent_mail-<sha>` copy predates it.

**Action:** none required. The team client passes the entry's `project_label` on every forwarded
call, so no row depends on the default. A box keeps the schema default it was created with.
Re-sync the copy when convenient (`team-mail-setup.sh <repo> --key <KEY> --resync-tool`, an
Operator action).

## The egress guard arms in role sessions and covers more forms

**Before:** `guard-team-egress.sh` armed only inside a team run (`.agents/team/session.json` or
`TEAM_RUN_TEAM`), so the Supervisor, TeamLead and Advisor sessions, which are launched with only
`TEAM_SESSION_ROLE`, ran without it.

**Now:** a set `TEAM_SESSION_ROLE` also arms it. The classifier also asks on `python -m <module>`
(the local test modules pytest/unittest/doctest/py_compile/compileall/json.tool pass), `python -`,
`node -`, a bare `python3 <<EOF`, `npx`/`pipx`/`uvx`, and on git config that points a remote at a
host outside the WebFetch allowlist (`git config remote.<n>.url|pushurl`, `git -c …url=…`,
`url.<base>.insteadOf`, `git push --repo=`). It stays a best-effort guard, not an allowlist.

**Action:** none beyond the starter sync. The settings entry calls `bash
.claude/hooks/guard-team-egress.sh` by path, so the updated file takes effect without re-running
`/setup:teams`. Role sessions now see an egress prompt where they did not before; a host the
roles need goes on the WebFetch allowlist as usual.

## The escalation adapter points at the Advisor's contract

**Before:** the operator kit's `escalate.sh` sent the reply protocol without saying where the
Advisor's rules live, and the starter had no Advisor-facing contract.

**Now:** the protocol header carries one more line, `Contract: .agents/reference/team-advisor.md
(main checkout).`, and `/setup:teams` installs that file (the reply format, tier 3 through the
Operator, the policy-log promotion exception, the solo mode).

**Action:** `bash .claude/team/sessions/operator-kit/install.sh --verify` reports
`differs <kit_dir>/escalate.sh` until the Operator re-applies the kit (`install.sh --apply`).
Until then escalations still work; the Advisor just does not see the pointer.

## The fallback conditions text is English

**Before:** a Reviewer-conditioned fallback typed `<text> — Warunki Reviewer (#<id>): …`.

**Now:** `<text> — Reviewer conditions (#<id>): …`. The payload's `## Reviewer` section names
generic critical grounds (a public contract, a schema or data migration, a sensitive path from
the profile) instead of one project's examples.

**Action:** none. A ledger with the old text stays valid: the `TeamLead-fallback` guard compares
the delivered text with the recorded one, never with a fixed wording, so an undelivered old
fallback is still delivered as recorded.

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
