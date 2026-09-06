# Independent review contract

How `brainstorm` and `plan-feature` obtain a cross-model opinion. The mechanics live in `scripts/review-orchestrator.mjs`; this file is what the calling skill must know and record.

## Direction and roles

| Author host | Reviewer | Model / effort (profile `roles.reviewer.<host>`, defaults) |
|---|---|---|
| claude | codex | `gpt-6-astra` / `high` — an explicit project override wins |
| codex | claude | `fable` / `high` |

The author host is passed explicitly (`--author-host`), never guessed from prompt language or file names. Effort is pinned on the reviewer command line; the result reports requested and confirmed model/effort. No model fallback and no effort downgrade on timeout.

## Boundary (what the reviewer can and cannot do)

- **Closed context.** The reviewer receives an immutable context pack on stdin: the plugin's `prime` instructions, the project rules (`CLAUDE.md`, `AGENTS.md`, `.agents/project-rules.md`), routed non-empty memory, the reviewed artifact(s) and the dependency files the caller named, each byte-exact with a SHA-256, plus a list of omissions. Excluded always: `.env*` (except `.env.example`), keys, credentials, `user-profile.md`, `.agents/sources/`, `.agents/handoffs/`, anything outside the project root.
- **No tools.** Codex: `--sandbox read-only`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `project_doc_max_bytes=0` (the live probe showed AGENTS.md in the reviewer cwd is otherwise still loaded), no output schema, `approval_policy="never"`, `web_search="disabled"`, and every execution/delegation feature disabled with `--disable <feature>` — all of it on the command line from `adapter.json` (the single effective configuration; there is no reviewer config file). Claude: `--restricted --safe-mode --tools "" --strict-mcp-config --setting-sources ""`, JSON output with a schema, no session persistence. Both run in an empty scratch cwd. Admin-managed policy of either CLI stays in force and is recorded as external policy context.
- **Observed activity rejects the opinion.** Any tool call, subagent, denied attempt or extra turn the adapter observes, a CLI error envelope, an `evidence_read` path that is not in the pack, or a `ship` next to a critical/major/fundamental finding makes the result `failed` — outside the model, before the author scores anything.
- **Proof by effect.** Flags are configuration; the live probe (`scripts/preflight.mjs --live-reviewer-probe`) records the effective surface: canary outside the pack not read, no file written, no nested CLI spawned, planted `CLAUDE.md`/`AGENTS.md` not auto-loaded, unavailable model never counted as ship. Its evidence (`docs/harness/reviewer-capabilities.json`) is validated by `preflight --verify-capabilities`, which binds the adapter bytes' digest. A host that fails a required assertion cannot run reviews; the adapter is not weakened to pass.
- **Nesting refused.** The child runs with `HARNESS_REVIEW_DEPTH=1`; an orchestrator started at depth 1 returns `skipped`. The reviewer may not write the project or start another reviewer; only the supervising author process writes results.

## Invocation and lifecycle

```
node <plugin_root>/scripts/review-orchestrator.mjs --project-root <root> --plugin-root <plugin_root> \
  --author-host <claude|codex> --kind <spec|plan> --artifact <file> [--dep <file>]... \
  --scratch <scratch dir> [--round N --repeat-reason "..."]
```

- One child process per call, argv array, stdin closed after the full pack, unique `review_id` and scratch run directory, stale final file removed before the spawn. Ceiling: 50 minutes (adapter default); on timeout the child and its descendants are terminated and the result is `failed`. Cancellation behaves the same. Late exit notifications are deduplicated by the orchestrator.
- **Claude Code caller:** launch with `run_in_background: true`, first check after ~6 min, then every 3 min, deciding state from the printed result file (`<scratch>/review-<id>.json`), never from a PID; cancel the wake-up on every exit path. Never busy-wait.
- **Codex caller:** run the command in the foreground and wait for it; the orchestrator owns the timeout. Do not emulate wake-ups.

## Result statuses

| `status` | Meaning | Caller action |
|---|---|---|
| `completed` + `ship` | anchored, no gaps | record; advance |
| `completed` + `revise` | findings to score | score → apply patchable → rethink signals for fundamental |
| `needs-context` | reviewer listed typed gaps: `missing-file` (add `--dep`, run once more), `required-decision` (the user decides; record it; review again only if material), `external-fact` (verify against current docs, add as dependency), `unspecified` (treat as required) | every kind blocks until resolved |
| `failed` | CLI missing/unauthenticated, exit ≠ 0, empty or malformed output, model/effort mismatch, artifact changed mid-review, timeout, cancelled | blocked; report the `error` verbatim |
| `skipped` | nested depth or `review` group disabled | not an opinion; say so |

Anything other than `completed` **blocks advancement** until resolved or explicitly waived by the user; the waiver text is recorded next to the blocked result. Empty stdout, exit 0 alone, or an old result file is never a positive review.

## Scoring findings (the author decides)

1. Anchored? `evidence` names a real pack path/section/decision → else drop.
2. Real refinement (contradiction, false repo assumption, closed edge case) → else drop.
3. Severity honest → adjust.
4. Conflicts with documented decisions (`decisions.md`, `patterns.md`, rules) → drop; our memory wins.
5. Changes what gets built (capability, acceptance criterion, public contract, an out-of-scope or cut-line item)? → reclassify `fundamental`.

Apply surviving `patchable` findings in place without asking (🔴/🟠; 🟡 only on sensitive paths). `fundamental` findings are never applied silently: they go to the user at the approval point (spec) or the fix-scope question (plan) as rethink signals.

## Repeat policy

| Change after a review | New opinion |
|---|---|
| typo, formatting, fixed link, clarified name (no contract change) | no — local checks; the first opinion stands |
| scope, acceptance criteria, chosen approach, module boundaries | yes |
| API, data model, permissions, integration, side effects, concurrency | yes |
| material decision added only to the plan | yes; check spec consistency |

Maximum three substantive rounds; an unresolved material issue at the cap requires a user decision, never automatic `ship`. A technical retry of a `failed` run is not an extra opinion and never launches while the earlier process is alive (`canTechnicalRetry`).

**The orchestrator supervises this itself** from the scratch directory (`roundsLedger`): results for the same artifact set form the lineage; `completed`/`needs-context` count as substantive rounds, technical failures do not. A repeat call passes `--change <kind>` (one of the material kinds above; editorial kinds are refused with `skipped`), the fourth substantive call is refused with `requires_user_decision`, `--technical-retry yes` is accepted only after a `failed` run, and nothing spawns while a child's `pid` file is alive. Use one scratch directory per artifact lineage.

## Recording (`## Independent Review` in the artifact)

`reviewer <host> · model requested/confirmed · effort requested/confirmed · review_id · reviewed SHA-256 · verdict or status · findings accepted (what changed) · findings rejected (why) · round N / repeat reason · waiver (user's words) if any`. Never hand-author `ship`.
