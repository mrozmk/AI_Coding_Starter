# Follow-ups from the source

The team layer was ported from a private project at one pinned revision (the `source:` line in
`.claude/team/manifest.txt`). This page lists what that project had **in flight** at the pin, what
is an agreed **target** rather than running code, and what was **not ported by design**. Nothing
here is assumed to exist. An item is implemented only when a page or contract says so with its
tests.

## In flight or target at the pin

| # | Item | State | Where it would land |
|---|---|---|---|
| F1 | **Gate-lock process groups.** Every workload starts through a launcher that becomes the leader of a recorded process group. Owned identities (pid + UTC start time) are recorded at spawn. Release and reclaim require every recorded group to have ended. Every wait is bounded. A descendant that detaches itself is **outside** the guarantee, and that is written as a boundary | in progress upstream | a delta port of `gate-lock.sh` / `gate_lock.py` |
| F2 | **tmux as an execution hand-over on tier 1.** No tier-1 auto-answer for any tmux level that can send keys, run commands or start processes. The exception is exact, proven read-only argv (`list-sessions`, `has-session`, `capture-pane -p`, `display-message -p`, each in one shape) | in progress upstream | the tier-1 prompt check |
| F3 | **Dynamic words on tier 1.** Any active `$VAR`, `${…}`, `$(…)` or backtick refuses tier 1, nothing is executed or guessed, and nested levels are scanned again | unmerged upstream, waits on F2 | with F2 |
| F4 | **Wake-loop hardening.** The wake text is redacted and marked as data. The loop re-arms on a socket-token change, a hung loop with a live pid is replaced, pane probes reuse the prompt parser, and the silence threshold is at least one slow round | in progress upstream (target AC) | the wake loop |
| F5 | **Delivery finish re-check.** `finish` re-derives the event for a free-text answer and requires the visible menu to belong to the bound event; the ledger shape of `finish` is documented | in progress upstream (target AC) | the question ledger |
| F6 | **Per-class escalation deadlines.** A blocking Advisor-list question past 60 min goes to the Supervisor for the Operator's list; a non-blocking one past 30 min becomes a follow-up | **target**, never implemented | the escalation layer; documented as a target in [02](02-decision-model.md) |
| F7 | **Pilot evidence.** Pickup p50/max per role, wake-up counts, and routing READY straight to the Supervisor when the TeamLead is unpicked | runbook | acceptance |
| F8 | **Policy-log ownership.** The TeamLead is append-only and the Advisor may replace one promoted line with a pointer. Both scopes are now stated in [02](02-decision-model.md#the-policy-log) | resolved in the docs | — |
| F17 | **Role-session prompts answered by key.** The Supervisor answers a role session's own menu through the sender, with a session-bound ledger, not by pretending the role is a team | planned with the role-session layer | the role-session layer |
| F18 | **Script enforcement of `teams.policy.sensitive_paths`** (merge gate, classifier). v1 uses the list as a judgement input only | open | later |

## Operational and platform follow-ups

| # | Item | State |
|---|---|---|
| F9 | The source project becomes a downstream of this starter for the team layer, so fixes are made once | decided in principle; its own plan |
| F10 | Detecting a PR whose host auto-complete was armed outside the gate (Azure DevOps) | not ported; belongs behind the azure-devops PR provider |
| F11 | `gate_lock_scope: machine|project`. Today one build gate runs at a time per machine, by design, and the wait is visible | later |
| F12 | Linux hosts: `flock` semantics, `ps` formats, `SIGALRM`, the messaging socket, cron/systemd for the health check. The source never ran there | to verify |
| F13 | The cross-session messaging socket is an observed, undocumented interface. Re-verify on every Claude Code upgrade | standing check |
| F16 | The vendored agent-mail tool is re-synced from its upstream by a manual delta, with its tests as the oracle | standing procedure ([`agent-mail.md`](../../.agents/reference/agent-mail.md)) |
| F19 | The memory-layer key `czytelnik:` (the reader of a recommended memory entry) is Polish in a public template. It is read by the reflection protocol and the memory guard outside the team layer, so renaming it needs every reader changed together plus a migration of existing entries | a separate starter item, not part of the team-layer port |
| F20 | The channel step stores a `~/…` Codex home as `$HOME/~/…` (`team-mail-setup.sh`: the `~` in the prefix strip is itself expanded), so the registry entry and `channel.local.json` carry a wrong `codex_home`. Workaround: an absolute path in `.claude/codex-profile` | code fix needed (found by the 2026-11-05 setup walkthrough) |
| F21 | On a fresh install the channel step refuses an uncommitted vendored tool (the copy is named after its commit), while `/setup:teams` never commits, so one run cannot finish setup. Naming the copy after the content (a tree hash) would remove both this stop and F22 | code fix needed |
| F22 | The tool copy is named after the checkout's commit, so a second project with identical tool content gets a second copy | code fix needed (with F21) |
| F23 | `pr_provider: none` is reserved and refused by the profile check, so a project without a PR host cannot run teams, and a scratch acceptance checkout needs a `github.com` origin | decide: lift the reservation or document the requirement |
| F24 | `--key <KEY>` reuse of another entry takes that entry's suffix and recipients without a warning when the profile's `mail_suffix` differs | code: warn on the mismatch |
| F25 | The operator kit's `--dry-run` prints `skip … escalation.local.json (operator kit not installed)` although `--apply` writes it | code: say "written by --apply" |
| F26 | The purity test does not scan the root seed files the installer generates (`.claude/codex-profile` carried a ticket key until 2026-11-05) | code: extend the purity scope |

## Not ported by design

| # | Item | Why |
|---|---|---|
| F14 | A monitoring role (alert intake, incident triage, production restarts), an attention shadow and an Operator dispatcher with a second notification channel | project-specific. If ever ported, the contract is "journal only, never answer an agent, never touch a session" |
| F15 | Observer hooks for the second-vendor CLI | only the attention shadow used them |
| — | Chat/messaging plumbing, tracker and PR-host specifics beyond the starter's providers, local container repair steps, token accounting beyond the starter's own costs layer | project-specific |

## Standing conditions on harness changes (kept as rules)

- A harness-rule change gets a plan, AC and test-mapping update, plus an independent review **before** code. A post-code opinion is never relabelled as a pre-code review.
- QA `ready-with-warnings` on a harness safety boundary is the Advisor pair's disposition. A behaviour defect against the change's own AC is a hold, not "accepted + follow-up".
- Accepted limits are written as **boundaries** in the AC and tested as documentation, never as a positive test of the guarantee.
- A rollout step that replaces running loops or installed hooks is an Operator action with recorded evidence: a new pid, a heartbeat, the main checkout at the merge commit. It is never inferred from a merge time.
- Name the integration topology explicitly: a PR into a feature branch delivers nothing to the line. Two branches that create the same new test part collide, so test parts are named, not numbered.
