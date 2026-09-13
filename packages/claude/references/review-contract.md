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

### Context modes

Profile `review.context` (absent → `closed`; `--context closed|hybrid` on the orchestrator overrides one run).

- **`closed`** — everything above, unchanged: the pack is the reviewer's whole world; the argv, the prompt bytes, the judge and the outbound manifest are byte-identical to before hybrid existed.
- **`hybrid`** — the closed pack is the floor, the paths the artifact cites (`## Files`, `### Relevant Codebase Files`, `### New Files to Create`, `### Patterns to Follow`, the `Reuse targets` line) ride along with role `cited` (dropped largest-first under `budget` when the pack is over `--max-bytes`; mandatory roles never), and the reviewer gets **exactly one tool**: the plugin's read broker `scripts/reader-mcp.mjs`, spawned by the reviewer CLI from a per-run MCP config (Claude: `--mcp-config <run>/reader.json` + `--allowedTools mcp__reader__*`, `--safe-mode` dropped because it disables every MCP server; Codex: `-c mcp_servers.reader.*` with `default_tools_approval_mode="approve"`, `code_mode_host` kept enabled because it routes MCP tools). Every native tool stays disabled exactly as in closed mode. The broker exposes `read_file`, `list_dir`, `search` over two roots — the project root (relative paths) and the plugin root (`plugin:<path>`) — with the shared exclusions enforced on every call (`.env*` except `.env.example`, keys, credentials, `user-profile.md`, `.agents/sources`, `.agents/handoffs`, `.agents/memory/archive`, `.agents/harness-state`, `.git`, `node_modules`, `dist`, `.playwright-mcp`; an excluded directory is refused itself and filtered out of its parent's listing), budgets of 30 distinct files / 409 600 returned bytes / 200 calls / 64 KB per read, and an **atomic read boundary**: validation, an `O_NOFOLLOW` open, a `dev`/`ino` identity check against the validating `lstat`, then read and hash from that descriptor — a path swapped for a symlink in between is refused (`replaced`). Residual window, stated: an *ancestor* directory swapped for a symlink in that instant (Node has no `openat`); the post-run re-hash and the rule that the author does not edit during a review are the mitigations. Every call appends one typed JSONL record to `<run>/reads.jsonl` (header `{review_id, instance_id, roots, budgets, started}`; `read_file` → `{seq, ts, tool, root, path, file_sha256, file_bytes, range, returned_sha256, returned_bytes}`; `list_dir` → entries; `search` → `files_opened` with hashes and `matches`; denials `{denied: true, reason ∈ budget-exhausted|excluded|outside-roots|binary|replaced}`; filesystem errors `{error: true, reason ∈ absent|not-a-file|not-a-directory|unreadable|invalid-arguments}`; trailer `{type: 'end', calls, denied, files, bytes}` on stdin close or on the CLI's shutdown signal). `reads_digest` = SHA-256 over the canonical transcript, bound into the result.
- **What rejects in hybrid** (typed outcome, outside the model): any tool other than the three broker tools, any subagent, any *native* permission denial; a successful read record that fails component-aware containment or names an excluded path (impossible by construction — the check pins the construction); `evidence_read` naming a path neither in the pack nor read through the broker (`<path>` / `plugin:<path>`); a `ship` next to a critical/major/fundamental finding. Broker denials are the enforcement working: they never reject. The **broker completion contract** also rejects: no log header (the CLI never started the broker → `reviewer context hybrid unavailable on <host>`, never a silent fallback to closed), a Claude `mcp_servers` status other than `connected`, more than one header, a missing trailer (`reader broker exited without trailer`), a call count in the CLI events that differs from the logged records (`unlogged broker activity`), a read whose file hashes differently after the run (`context changed while the review was running`).
- **Consent boundary in hybrid.** `pack.outbound.json` carries `mode: hybrid`, `roots`, `exclusions`, `budgets` and `initial_payload: true`: the file list is the initial payload, and the reviewer may still read anything the exclusions allow under the roots, within the budgets. After the run — on **every** exit path once the reviewer was spawned — `pack.outbound.final.json` = the initial manifest + the read transcript summary + `reads_digest` + `transcript: complete | incomplete (<reason>)`: the final disclosure record, printed by the author after the run. The standing consent is the profile's explicit `review.context: hybrid`.
- **Proof.** The live probe runs each host in both modes; hybrid rows are namespaced `<host>:hybrid:*` (`allowed-read-logged`, `excluded-denied-observed`, `outside-denied-observed`, `budget-enforced`, `broker-single-instance`, `broker-no-write`) and `verify-capabilities` binds the broker, `lib/reads.mjs` and the result schema into the config digest. The closed rows keep their names and receipts.

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
| `needs-context` | reviewer listed typed gaps: `missing-file` (add `--dep`, run once more; in hybrid mode the item carries `reason`: `budget` → answer with `--priority-read <path[:offset-limit]>` in the continuation, `--dep` only when the whole file fits next to the mandatory pack; `excluded` → never supplied, the author cannot either; `absent` → a finding about the artifact, not a pack gap), `required-decision` (the user decides; record it; review again only if material), `external-fact` (verify against current docs, add as dependency), `unspecified` (treat as required) | every kind blocks until resolved; before the re-run, `--dry-run yes` again and show only the files **added** since the previous `pack.outbound.json` — a host-level consent control (Codex managed permissions) may ask separately for the extended payload: stop with that question, never bypass it |
| `failed` | CLI missing or not logged in **in the orchestrator's own execution context** (probed before any spawn), exit ≠ 0, empty or malformed output, model/effort mismatch, artifact changed mid-review, timeout, cancelled | blocked; report the `error` verbatim |
| `skipped` | nested depth or `review` group disabled | not an opinion; say so |

Anything other than `completed` **blocks advancement** until resolved or explicitly waived by the user; the waiver text is recorded next to the blocked result. Empty stdout, exit 0 alone, or an old result file is never a positive review.

## Execution status — did the second model actually work?

`status` says what the opinion is worth; `execution` says whether a model ever handled the input. The orchestrator derives it from facts (`model.confirmed`, `process.exit_code`, `status`, `evidence_read`), never from `status` alone — a `needs-context` raised while packing, or a `failed` on an unauthenticated CLI, has no confirmed model and is `not-executed` even though `argv` shows a full `claude --model …` call.

| `execution` | Facts | `summary_line` |
|---|---|---|
| `not-executed` | no confirmed model, or no exit code | `Review: NOT EXECUTED — <error>` |
| `executed-rejected` | model confirmed, output rejected outside the model (`failed`) | `Review: EXECUTED, OPINION REJECTED — <error>` |
| `executed-incomplete` | model confirmed, `needs-context` with read evidence | `Review: EXECUTED, OPINION INCOMPLETE — <n> missing context item(s)` |
| `executed-complete` | validated `completed` | `Review: EXECUTED, COMPLETED — ship\|revise` |

**Every calling skill prints `summary_line` verbatim** as the first line of its review report and again in its final summary. A launched process is never called "a second opinion"; only `executed-complete` is one.

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

`reviewer <host> · model requested/confirmed · effort requested/confirmed · review_id · reviewed SHA-256 · verdict or status · findings accepted (what changed) · findings rejected (why) · round N / repeat reason · waiver (user's words) if any`; a hybrid run adds `· context hybrid · reads N (M denied) · reads_digest <sha256>`. Never hand-author `ship`.
