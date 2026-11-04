# Reference: team questions — ledger, delivery, escalation mechanics

The step-by-step mechanics behind [team-mode.md](team-mode.md) §10 (tiers, rules, Operator
actions) and [team-decision-model.md](team-decision-model.md) (who decides). Scripts live in
`.claude/lib/` and run from the main checkout; `/monitor` (the TeamLead) drives them.

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/05-escalation.md`.

1. `team-question.sh <team> open <role> --kind blocked|menu|permission|idle [--anchor "<screen
   line>"] --summary "…"` records `questions/q-<n>.md` with its binding v2: role,
   attempt, run, kind, newest record or anchor, `fingerprint: v2:<sha256>` of the **active
   prompt's content** only (`team_prompt.py parse` over the pane plus scrollback: header,
   description, command lines with only the `│ ` gutter stripped, reason, question, options —
   never `Tip:`, the cursor, checkbox marks or anything above the prompt's top rule), `v2:none`
   for the idle input, `v2:unreadable` + `unreadable: <reason>` for a prompt it cannot read
   (clipped, unknown renderer, multi-question tabs), `pane: <pane_id>@<session_created>`,
   `session: <session_id>` and `event: <tool_use id | last assistant uuid | ambiguous | ->` from
   the role's transcript. Dedup under `questions/.open.lock`: `blocked` by record; menu/permission
   by fingerprint + pane + event (+ anchor when unreadable); idle by anchor + pane + event — the
   anchor is a label, not the identity. On a busy role (`esc to interrupt`, or a `<glyph> <Verb>… (`
   spinner above the input), or a prompt still rendering (`incomplete:`), a `blocked` q is
   recorded with `fingerprint: -` and gets a fresh binding on the next `open` while it is
   unanswered and the role idle; the other kinds are refused. The dashboard snapshot derives
   `prompt_open`/`menu_open` from the same parse and falls back to the screen regexes only when
   the parse is not complete (detection never under-reports).
2. The supervisor classifies.
3. `team-question.sh <team> answer q-<n> --tier … --author … --why … --text … --send …` refuses an
   answered (`sent`/`consumed`/`recorded`), revoked, failed, not-sent or not-sent-stale (tier 3
   only) or `pending`/`unknown` (tier 3 `--send none` only) question, and a `--send` that does not
   fit its kind (menu `pick`/`picks`/`other`, permission `yes`/`no`, blocked/idle `say`, `none`
   always). Checks that need no screen run before the journal and leave the q unchanged (exit 1,
   `stale: … — nothing sent`): run, role/attempt, session, fingerprint `-` (busy at open), a v1
   fingerprint (`legacy binding v1 — open again`), a newer record. Then it journals `## Answer`
   (`attempt: <k>`, `send:`, `text:`, `delivery: pending`) and calls `team-answer.sh` with the
   expected binding. The sender takes `send-<role>.lock`, captures by pane id, parses, and refuses
   with zero keys on any mismatch (pane generation, fingerprint, event — a menu/permission q needs a
   uniquely associated event —, session/run/attempt, record, anchor, cursor not on option 1 / not on
   `Yes`, an unrecoverable human draft (multi-line, a `[Pasted text`/`[Image` chip, changed since
   the first capture), busy role); for `yes` it runs `team_prompt_check.py --strict --transcript`
   (ask/deny with segments, SQL guard, egress: a `Fetch`/`WebFetch` prompt or
   `curl|wget|ssh|scp|rsync|nc` as a word in the screen **or** the transcript command; an unreadable
   clone policy or a settings edit refuses; `--tier 1` adds `--classes`: `policy-class:`,
   re-bind, `class:` in the ledger). It refuses a second dispatch to an instance already in
   `send-<role>.log`, checks mode, `cancel` and identity as the last gate, appends the dispatch
   line, sends every key to the pane id through the journal and polls `TEAM_CONFIRM_SECS` for
   positive consumption evidence (`tool_result` of the event, the role busy on a complete parse, a
   new transcript user entry for `say`). A recoverable single-line draft is written to
   `runs/<run>/drafts/<role>-<attempt>-<utc>.txt`, read back and only then cleared with `C-e C-u`,
   verified empty, then the answer is typed once; the sender prints `draft saved: <path>`.
   For `say` the draft is re-checked byte for byte before the last gate and saved before any key;
   for `no` it first appears after Escape and is saved from that post-Escape capture, without a
   re-check. Limit: a human typing in the milliseconds between the last capture and `C-u` is not
   detectable. Sender exit → `delivery:` → state (read by `team_q_state`, `list`,
   `team-escalate.sh`, `/monitor`):

   | sender | `delivery:` | state | `answer`/`retry` exit |
   |---|---|---|---|
   | 0 | `sent` + `confirmed: yes (…)` | `consumed` | 0 |
   | 0 | `sent` + `confirmed: no — …` | `sent` (Operator inspects, never resend) | 0 |
   | 3 | `not sent — stale (<reason>)` | `not-sent-stale` → `retry` | 3 |
   | 5/6/7/8 | `not sent — unreadable\|changed\|policy\|mode (<reason>)` | `not-sent` | 5 |
   | 4 | `unknown — <n> keys (<reason>)` | `unknown` | 4 |
   | crash, no `try` | `failed (rc N)` | `failed` | 5 |
   | crash after a `try` | `unknown — <n> keys (rc N)` | `unknown` | 4 |
   | a stop held the lock | `unknown — stop while sender lock held by pid <X>` | `unknown` | 4 |
   | — | `recorded only` / `pending` / any other value | `recorded` / `pending` / `unknown` | — |

   The notes line is written once, when an attempt ends `sent`/`consumed`/`unknown`.
   `team-question.sh <team> retry q-<n> --run <run>` re-delivers only a `not-sent-stale` q with a
   real `event`, copying the **latest** `## Answer` decision into a new block (`retry-of:`), at
   most 3 attempts per decision; tiers/answering off, `cancel` and a run change refuse; policy is
   re-checked every time. `team-run.sh end_session` takes the same send lock
   (`TEAM_SEND_LOCK_WAIT`, default 30 s) and types `/exit` only on a recognised empty idle
   input; on a timeout it logs `stop-during-send` and kills the session without keys.
   Recovery: `team-question.sh <team> unlock open` / `unlock-send <role>` (dead holder, ≥ 10 s).
   Nothing is ever re-sent automatically.
   Single-select uses `pick:<n>` or `other` with text. A single-question checkbox multiSelect
   uses `picks:1,3` (the exact desired set, clearing any other checked options) or `picks:none`
   (explicit skip all via Other text `none - skip all`). It checks the review answer and cursor
   before final Submit. Empty Submit means unanswered, so it is never used for skip all.
   `picks:none` sends an answer; plain `--send none` is still tier 3, recorded only.
   Multiple question tabs (including completed ones) are a role error (§3), refused at tier 3. Wrong
   cursor/range, an unknown/truncated renderer or already selected Other refuse; unexpected review
   never gets a final Enter. A refusal/delivery failure follows `/monitor`'s Operator-action route
   without automatic retry.
4. Tiers 2 and 3: `team-escalate.sh <team> <role> <2|3> <q file> --blocks "<decision>"
   [--class <c>] [--recommend "<send> <text>"] [--options "<text>"] [--files "<a,b>"]` in the
   background writes the self-contained payload `q-<n>.payload.md`, sends it to Advisor on thread
   `esc-<run>-<qid>` and waits for his reply (`status: answer | pending-operator | withdrawn`,
   optional `author:`, `decided-by: analysts | operator`, `operator-ref:`, `eta:`, a blank line,
   the body). Modes: `--reping "<reason>"` (re-send an undelivered request, or a new re-ping — at
   most 2 delivered), `--resume` (wait only; on an answered q a late read), `--retier "<reason>"`
   (tier 3 after a tier-2 answer). `## Escalation` lines: `started:` / `reping:` / `retier:` /
   `resumed:` / `late:`, `recommend:`, `sent: seq <n> <utc> id <id> thread <thread>` (older
   ledgers: `sent: seq <n> <utc>`), `failed: seq <n> <utc> — no receipt|rc <n>|timeout` (one per
   failed send attempt), `reply: <mail-id> <status>`, `waited:`, `opinion:`, `fallback:`,
   `waiting: operator` (state `waiting-operator`, sticky until a final reply), `outcome: answer |
   withdrawn | reviewer-fallback | late-<status> | no-reply — <reason> | cancelled`, `ended:`. A
   staged reply (`q-<n>.reply-<id>.md`) is replayed once by mail id; a `<q>.wait/` lock keeps one
   waiter per thread. Exit 0 `ANSWER` / `WITHDRAWN` / `FALLBACK` / `LATE <status>` + the text · 1
   busy · 2 usage / refused state / reping limit / tier mismatch · 3 `NO-REPLY <reason> (repings:
   <n>, sent: <yes|no>)` · 4 final reply printed, outcome not recorded (ledger lock timeout) ·
   130/143 cancelled. A tier-3 `answer` counts only with `decided-by: operator` + an
   `operator-ref` the adapter verified. The supervisor writes the answer.
   **Config contract.** `send` and `wait` are each one simple command: first word `bash`
   or `sh` (on PATH, no absolute path), then the adapter (no option word `-…`/`+…`) and fixed
   words, ending with `"$1" "$2" "$3" "$4" "$5" "$6"`; besides those tokens only
   `[A-Za-z0-9_./~@%+=:,-]`, spaces and plain double quotes. The check is static — nothing from
   the config runs to test it — and happens before any adapter runs; a template outside it ends in
   `NO-REPLY invalid config: adapter does not forward thread/seq`. Without `$5`/`$6` the adapter
   falls back to a per-qid dedup key, so a qid reused in a later run collided and the message was
   silently dropped. **Receipt:** a send counts only when the adapter exits 0 and its last stdout
   line is `SENT id=<n>`; rc 0 without it (`failed: … — no receipt`) is retried once at once (same
   seq), then `NO-REPLY invalid adapter (no SENT receipt)`; a failed send or a `--reping` consumes
   a reply `peek` finds first; `--retier` takes max request seq + 1. A ledger with
   `started:` but no `sent:` is surfaced as `ESCALATION … started without sent | not sent — <reason>`.
5. `team-question.sh <team> revoke q-<n> --why "…"` (the developer's "revoke <team> q-<n>", alias "cofnij <team> q-<n>")
   records `## Revoked` and, when the role is idle on the same attempt with no prompt open, types
   the revoke text; the question becomes tier 3 (the Operator decides).
