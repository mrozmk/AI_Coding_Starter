# Planning contract

The shared contract between `brainstorm`, `plan-feature`, the execution/verification stage (still the legacy release) and any reviewer. Both hosts read this file; neither host owns it.

## Spec (design) file

- Path `.agents/specs/YYYY-MM-DD-<kebab-topic>.md`, structure from `templates/brainstorm-spec.template.md`.
- `**Status:**` is `Draft` at birth and becomes `Approved` only by the user's decision at the brainstorm approval point.
- `**External docs required:** yes | no` is mandatory; `approval.mjs verify` refuses a spec without a usable value, so plan-feature never plans from a spec that cannot say whether research was needed.
- Approval identity is **external**: `scripts/approval.mjs stamp` applies only the declared metadata transition (`**Status:** Approved`, `**Approval:** receipt \`.agents/approvals/<spec>.approval.json\` — approved by the user on <date>`), hashes the final bytes and writes the receipt (`spec`, `sha256`, `bytes`, `draft_sha256`, `approved_on`, `decision`). A spec never contains its own whole-file hash. `plan-feature` runs `approval.mjs verify`: Draft, missing/invalid receipt, an interrupted stamp or any byte changed after approval → refused. An editorial edit after approval needs a new stamp (user re-approves the bytes), not automatically another substantive review.
- `## Independent Review` records every review round (see `review-contract.md`). A blocked opinion is recorded as blocked, with the user's explicit waiver text if one was given. It is never rewritten as `ship`.

## Plan file

- Path `.agents/plans/active/<kebab-feature>.md`, structure from `templates/plan-feature-plan.template.md`. Moved to `.agents/plans/done/` by the execution stage; the plan's identity is its path plus `**Spec SHA-256:**` — never "the newest file by mtime".
- Header fields, all mandatory: `**Source spec:**`, `**Spec SHA-256:**`, `**External docs required:**`, `**Execution effort:**`.
- `## STEP-BY-STEP TASKS` is the counted list. Each task:
  - heading `### {CREATE|UPDATE|ADD|REMOVE|REFACTOR|MIRROR} {target}`;
  - a bare `- [ ]` line — a **parse anchor** for the verification gate. The executor never ticks it: a completion mark written by the agent being judged measures its self-report, not the filesystem;
  - `EXPECT` (required, repeatable): `present | absent | contains | not-contains — {path}[ :: {literal}]`. `contains` is a fixed-string search on the literal, never a regex;
  - `VALIDATE` (required): one executable command, exit 0 on success and non-zero on failure. A command that can run zero tests and exit 0 is a defect.
- `## ACCEPTANCE CRITERIA` are judged, never counted.
- `## VALIDATION COMMANDS → Level 1` is present and executable even when one line.
- Size budget: single file soft 600 lines / 36 000 chars, hard 1 200 / 72 000. Over the hard cap: ask (densify vs split); never split silently — a split changes the execution contract. The shapes a chosen split must produce (parallel plans, umbrella + `## Execution Plan` table, `manual` steps, per-step effort, re-measure) are in `plan-split-contract.md`; a single-file plan never carries `## Execution Plan`.

Keep the heading names, the anchor, `EXPECT` and `VALIDATE` exactly until the generator and every reader receive a coordinated, tested contract version change.

## Execution effort

- New plans always write `**Execution effort:** medium` (Opus at effort medium is the required executor target). The generator checks the field is present before reporting.
- The user may explicitly request `low`; then `low` is written. There is no third level and no model name in the field.
- Readers: an explicit `low` in an older plan stays `low`. A plan with **no** field keeps the legacy `low` fallback — readers never guess a plan's age from dates, and no version marker is added for this purpose.

## Approval and continuation

- `planning.after_brainstorm` in the profile: `stop` | `plan-feature`; absent means `stop`.
- The user's explicit `stop` / `only spec` in the brainstorm input wins over `plan-feature`.
- Continuation runs **once**, with the exact approved spec path (its receipt carries the hash), writes a plan, and never runs the execution stage. Neither host starts a planning skill from a description match; the entrypoints are user-invoked (Claude: `disable-model-invocation`; Codex: `allow_implicit_invocation: false`).
- Claude Code may block a nested user-only skill call. After the user's explicit approval the active brainstorm then reads `skills/plan-feature/SKILL.md` and performs it directly. That is the documented approved continuation; it is never used to bypass a stop.

## Grilling checklist (plan-feature Phase 4)

Anchors resolve · `VALIDATE` resolves in this repo (right runner, right target, non-zero on failure) · `EXPECT` cannot be satisfied by an empty template · sensitive paths (payment, auth, webhook, license, locale/redirect routing, permission isolation, subprocess supervision) have tests · latent product decisions surfaced · nothing contradicts the spec's `Out of Scope` or `Appetite & Cut Lines` · size within budget. Then one self-critique pass over the findings; report the survivors; ask the fix scope once.
