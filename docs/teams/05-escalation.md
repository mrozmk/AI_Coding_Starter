# 05 — Questions and escalation

**Contract:**
- [`team-questions.md`](../../.agents/reference/team-questions.md): the ledger, the binding, delivery, the delivery-state table and the adapter contract.
- [`team-mode.md` §10](../../.agents/reference/team-mode.md#10-escalation-tiers): the rules.
- [`escalation-fallback.md`](../../.agents/reference/escalation-fallback.md): the Advisor no-reply fallback.
- [`team-advisor.md`](../../.agents/reference/team-advisor.md): the Advisor's side — the reply format, tier 3, the policy-log promotion exception, the solo mode.

## Why a ledger

A team role that needs an answer shows it on screen as a menu, a permission prompt, a `blocked` record or an idle input. The obvious approach is to read the screen and type the answer, and it fails in quiet ways:

- The prompt changes between reading and typing.
- A second identical prompt appears.
- A human is half-way through typing a draft.
- The answer reaches a role that has already moved on.

So every question becomes a **recorded question** (`team-question.sh <team> open …`) with a binding, and every answer goes through one sender that refuses on any mismatch.

## The flow

1. **Open.** `team-question.sh <team> open <role> --kind blocked|menu|permission|idle` records `questions/q-<n>.md`.

   Its binding fingerprints **only the active prompt's content**: header, command lines, question and options. Nothing above the prompt and no cursor or checkbox state goes into the fingerprint, so output scrolling past does not invalidate it. The binding also records the pane, the session and the transcript event the prompt belongs to.

   A prompt it cannot read is recorded as unreadable, and that is never a guess. `open` is idempotent and reports the question's state, which decides the next step.
2. **Classify.** The tier comes from [02](02-decision-model.md). For an Advisor-list question the escalation class is picked **critical first**: AC, contract, schema, sensitive, harness rule and conflict are checked before any eligible class. An unclassified question counts as critical.
3. **Answer.** `team-question.sh <team> answer q-<n> --tier … --author … --why … --send …` writes the answer to the journal first, then hands it to the sender.

   The sender takes the role's send lock, re-captures the pane and refuses with **zero keys** on any mismatch of fingerprint, event, session, run, attempt, cursor position or a human draft it cannot recover. For a permission `yes` it also runs the tier-1 prompt check ([06](06-permissions.md#the-tier-1-prompt-check)).

   Every key goes through an append-only key journal. Delivery counts as *confirmed* only on positive evidence: the tool result, the role going busy, or a new transcript entry. **Nothing is ever re-sent automatically.**

   A stale question is retried at most three times per decision. An unconfirmed free-text answer gets exactly one `finish`.
4. **Escalate** (tier 2/3). `team-escalate.sh` runs in the background. It writes a self-contained payload, sends it to the Advisor (and the Reviewer, in `pair` mode) on thread `esc-<run>-<qid>` with an idempotent dedup key, and waits for a reply with a fixed header (`status: answer | pending-operator | withdrawn`, `decided-by: analysts | operator`, …). A tier-3 answer counts only with a verified `operator-ref`: a signed decision note in the channel whose hash and thread line match.

## The Operator's words

The Operator speaks only in the TeamLead's window, never by mail or through another session. The words are fixed, and `/monitor` acts only on them:

- `zatwierdź <team>` (approve);
- `odrzuć <team> — <reason>` (reject);
- `odpowiedz <team>: <text>` (answer);
- `tiers off|on` (or `tryb tiers off/on`).

English canonical forms (`approve`, `reject`, `answer`, plus `revoke <team> q-<n>` and `disable|enable class <name>`) come with the role-session layer, and the current words stay accepted as aliases. A recommendation the TeamLead made is never itself consent.

## When the Advisor is silent

A missing config, a timeout, a send or wait failure, an unparseable reply, or a tier-3 answer without a verified Operator decision is a **NO-REPLY**. The TeamLead:

- prints one line, and only when the reason changed;
- re-pings at most twice;
- then waits without a deadline.

It never forwards the question to the Operator and never treats silence as consent. There are two narrow exceptions:

- **The no-reply fallback**, only for the eligible classes (`analysts-condition`, `plan-variant`, `borderline`, `policy-deviation`). After a wait timeout, the question closes on the Reviewer's `opinion: agree` over the TeamLead's recorded recommendation. The Advisor's silence must be proven by one empty poll. It is delivered as `TeamLead-fallback`. Critical classes and anything that has ever waited on the Operator never fall back. Under `advisor: solo` there is no Reviewer, so there is no fallback.
- **The wrapup (B) memory exception.** Transitional supervision rules — the scripts do not enforce them. New, unaccepted, optional memory proposals close as *skip* on no-reply. They are deferred, never accepted, and handed to the Advisor as one deduplicated `info`.

Late replies, orphaned waiters after a restart and staged replies are replayed once by mail id, never twice. [`team-questions.md`](../../.agents/reference/team-questions.md) describes the ledger lines.

## The Reviewer's part

In `pair` mode the Reviewer receives a copy of every escalation. Its first line is exactly `opinion: agree` or `opinion: disagree`, with the critical class and the reason on the next line when it disagrees. A disagreement is a result: both positions go to the Operator with a recommendation and are never averaged.
