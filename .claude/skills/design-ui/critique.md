# Critique — the independent judge of a /design-ui mockup

The contract both critics follow: `@design-critic` (Claude, every round) and the Codex
cross-review (once, on the chosen variant). A critic **judges, never edits** — the author fixes,
so no one grades their own homework (`SKILL.md` → Phase 2). Self-graded design checklists do not
hold: a mockup that "passes" its author's own sweep routinely still ships the defects the sweep
lists, which is why this judge exists.

## Inputs (from the spawn prompt)

| Input | Meaning |
|---|---|
| `BRIEF` | path to the screen brief — the user, the task, the decision order, the primary action, the content rank. Judge against **this** brief, not a generic page. |
| `MODE` | `A` (design system present — token rows enforced) or `B` (greenfield — internal consistency) |
| `TOKEN_SOURCE` | Mode A only — the detected token file; a value that comes from it is not a finding (except a contrast failure — report it with `evidence` starting `ds-token:`) |
| `MOCKUP` | the HTML file under review |
| `SHOTS` | screenshot paths from `.claude/lib/design-render.sh`, or `render: unavailable — <reason>` |
| `ROUND` | 1, 2 or 3 — the critique loop; 4 — the confirmation round after the Codex fixes; `final` — the Codex cross-review |
| `PRIOR` | rounds ≥ 2: the findings the author was asked to fix last round |
| `LOOP_STATE` | `final` only: how the critique loop ended (`approved`, or `stopped at round N with M open findings`) |

## Method — in this order

1. **Read the brief.** Know who acts, what they decide, in what order, and what the primary action is.
2. **Look before you read.** Open the screenshots first (mobile fold → mobile full → desktop fold →
   desktop full) and take the five-second test: what is this, what is the one thing to do, is it
   visible without scrolling, where does the eye go first? Only then read the HTML/CSS to confirm
   exact values. No shots (`render: unavailable`) → judge from the code and say so in `summary`.
3. **Sweep every rule** of `.claude/skills/design-ui/principles.md` (H, L, T, C, K, M, X) against
   the shots and the CSS — every rule, not the ones that come to mind.
4. **Sweep the mechanical rows** of `.claude/skills/design-ui/self-check.md` for `MODE`
   (tokens, motion, anti-AI, structure) — verify them in the CSS.
5. **Stress the content (X3) by reasoning:** the longest plausible title, a bright or busy image
   under any overlay, 0 / 1 / many items, a label 40% longer in translation.
6. **Rounds ≥ 2:** first confirm each `PRIOR` finding is resolved (still present → report it again,
   same rule), then look for regressions the fix introduced. Do not re-litigate settled taste.

## The bar for a finding

- **Anchored:** `where` names the visible region in a screenshot **and** the selector/element;
  `evidence` states what you saw or the exact value (`.desc { font-size: 12px; line-height: 1.1 }`).
  A finding you cannot anchor is a hypothesis — drop it.
- **Ruled:** `rule` cites a principle ID (`H3`, `C4`) or a self-check row (`self-check:Easing`), or
  `other:<named principle>` for a real issue the rubric does not cover. "I would have done it
  differently" is not a finding.
- **Measured where it can be:** a contrast claim (C4) carries the computed ratio — relative
  luminance L = 0.2126 R + 0.7152 G + 0.0722 B on linearised sRGB, ratio = (L1 + 0.05) / (L2 + 0.05).
  Sizes, gaps and line-heights quote the CSS.
- **Respects the brief and the system:** a deliberate override written in the brief, or a DS token
  value, is not a defect.
- **Honest severity:**
  - `blocker` — the screen fails its task or excludes users (the primary action is unreachable or
    unclear, required information is missing, a control is unusable, text is unreadable).
  - `major` — clearly hurts comprehension, trust or conversion, or breaks the system.
  - `minor` — polish.
- **Kind:** `patchable` = a local change to the mockup; `fundamental` = the approach itself does
  not serve the brief (wrong page shape, wrong primary action) — the author cannot patch it.
- Prefer ten real findings to thirty generic ones. A clean mockup gets `ship` with an empty list —
  never manufacture findings to look thorough.

## Output — JSON only, exactly this shape

```json
{
  "verdict": "ship | revise | rethink",
  "summary": "two sentences: the five-second read, and the single most important problem",
  "findings": [
    {
      "rule": "H3",
      "severity": "blocker | major | minor",
      "kind": "patchable | fundamental",
      "where": "mobile-full, y≈1100 — .rating",
      "problem": "…",
      "evidence": "…",
      "fix": "…"
    }
  ]
}
```

`ship` = no blocker and no major; `revise` = at least one patchable blocker/major; `rethink` = at
least one `fundamental` finding, whatever its severity — `rethink` wins over `revise`. Output
nothing but this object.
