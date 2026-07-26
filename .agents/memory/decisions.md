# Memory: Decisions

Architectural and technical decisions with rationale.

Add newest entries at the **TOP**.

---

## Format

```
## YYYY-MM-DD — Title

**Decision:** what was decided
**Why:** reasoning
**Alternatives considered:** what was rejected and why
**Impact:** where this shows up in the code
```

---

## 2026-07-27 — Sub-agent model/effort policy: Opus 5 pinned, gates stay `high`

**Decision:** Every `.claude/agents/*.md` pins `model: claude-opus-5` explicitly. Effort is per role:
doers (`orchestrator-executor`, `-refiner`, `-committer`, `documentation-manager`) `low`, the
read-only gates (`orchestrator-verifier`, `orchestrator-designer`) **`high`**, and
`orchestrator-executor-hard` `medium`.

**Why:** Two points here are counter-intuitive and will look like bugs to a fresh reader:

1. **Gates stay `high` despite benchmark evidence that `medium` scores higher on Opus 5.**
   FrontierCode test-time-compute scaling puts Opus 5's peak at `medium` (63.6%) with `high` both
   *lower* (58.5%) and pricier. We keep `high` anyway: that benchmark measures agentic coding, not
   read-only audit, a single non-monotonic curve is weak evidence, and the risk is asymmetric — a
   false "pass" from a weakened gate reaches `main`, which costs more than the tokens saved.
   **Do not "optimize" the gates down to `medium` on the strength of that chart alone.**
2. **The model is hardcoded, not inherited.** Omitting `model:` would make the pin self-updating and
   avoid stale ids, but it also lets a session on Claude Fable 5 silently run the whole pipeline at
   ~2× Opus 5 cost. Deterministic spend beat self-maintenance. The trade-off is a known sync point:
   a model bump means editing `model:` in all seven agent files.

**Alternatives considered:**
- *Gates at `medium`* — rejected per (1).
- *Drop `model:`, pin only `effort:`* — rejected per (2). `effort` is role-derived and durable;
  `model` is perishable, and we accepted the maintenance cost to keep it explicit.
- *`CLAUDE_CODE_SUBAGENT_MODEL` env var* — rejected: it overrides per-step choices globally, and this
  pipeline chooses an agent per step.
- *Keep the `Model` column's `sonnet | opus | haiku` vocabulary and re-read it as a difficulty marker*
  (the upstream runbook's approach, to keep old plans parsing) — rejected: we had exactly one
  unreleased plan with that table, so a straight rename to `Effort` cost nothing and avoids a column
  named `Model` that selects no model.

**Impact:** `.claude/agents/*.md` (7 files); `orchestrate.md` Phase 2 + Step 5.1 (`Effort` column,
never pass the `Agent` tool's `model` parameter); `plan-feature.md` (`**Execution effort:**` header
field, `Execution Effort Recommendation` section, Quality Criteria); `README.md` → Model & effort
strategy. Commit `7c70d07`.
