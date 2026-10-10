# Self-Check — the author's pre-flight (mechanical rows)

The author runs this against EVERY mockup (every variant) **before** handing it to the critic,
and fixes every miss. It is hygiene, not the verdict: the verdict belongs to `@design-critic`
(`SKILL.md` → Phase 2), which sweeps these same rows again together with the judgement rubric in
`.claude/skills/design-ui/principles.md`. For the exhaustive property diff of implemented UI
against a reference see `.claude/commands/gates/design-quality-check.md`. Deep rule references:
`.claude/skills/design-ui/emil-design.md` (motion), `.claude/skills/design-ui/redesign.md`
(anti-AI), `.claude/skills/design-ui/dials.md` (variance/density). The token set is the
**project's detected design system** (resolved in `SKILL.md` Phase 0 — CSS custom properties /
Tailwind theme / `tokens.css` / `theme.ts`), not a fixed list.

**Mode is chosen by `SKILL.md` Phase 0 and passed in — do NOT re-detect here.**

---

## Mode A — DS present (NEW-to-DS / FIX)

The design system exists; variants differ by layout/composition, NOT by palette/fonts.
Every row must hold before the hand-off. "Token" below means a value
from the project's detected token source — substitute the project's actual variable names.

### Tokens & color (detected DS)

| CHECK              | PASS criterion                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| No hardcoded color | Zero raw hex / `rgb()` for themeable color — every themeable color references a design token (`var(--...)` / theme) |
| Borders            | Border color comes from a token, never an ad-hoc `rgba(...)` that bypasses the system                               |
| Shadows            | Shadow tokens only — tinted to the background, never pure-black `rgba(0,0,0,...)` on a tinted/dark surface          |
| Radius scale       | Only radius tokens from the scale, no stray px radii                                                                |
| Easing token       | Easing comes from the project's curve tokens (see `emil-design.md` for why custom curves beat built-ins)            |
| Typography         | The project's configured UI/body typeface for text; the numeric/mono typeface ONLY for figures/scores              |
| Numerics           | `tabular-nums` (or `font-variant-numeric`) on aligned numbers                                                       |
| Theme              | Matches the project's theme contract (e.g. dark-only vs light/dark) — no rogue mode the DS doesn't define           |

### Motion (emil-design.md)

| CHECK          | PASS criterion                                                          |
| -------------- | ----------------------------------------------------------------------- |
| Easing         | `ease-out` or custom curve on enter; never `ease-in` for UI reveals     |
| Duration       | UI transitions < 300ms                                                  |
| Press          | `:active` → `scale(0.97)` (never `scale(0)`)                            |
| Origin         | Popovers/dropdowns are origin-aware (modals exempt)                     |
| Hover gating   | Hover effects wrapped in `@media (hover: hover)`                        |
| Reduced motion | `prefers-reduced-motion` honored                                        |
| Property       | No `transition: all` / `transition: top` / `left` — explicit props only |

### Anti-AI + content (redesign.md)

| CHECK                  | PASS criterion                                                            |
| ---------------------- | ------------------------------------------------------------------------- |
| No AI-gradient         | No purple→pink gradient as the whole aesthetic                            |
| No 3-equal-card row    | Generic SaaS triptych avoided; use asymmetry / bento                      |
| No centered-everything | Real composition, not everything center-stacked                           |
| Copy                   | Sentence case; no banned marketing filler; no Lorem / "John Doe" / "Acme" |
| Icons                  | One consistent icon set with uniform stroke weight — never default Lucide/Feather mixed in ad-hoc |

### Structure

| CHECK       | PASS criterion                                                              |
| ----------- | --------------------------------------------------------------------------- |
| Frontmatter | Top-of-file frontmatter with `name` + `priority` + `status` (if the project indexes mockups) |
| Consistency | Coherent with ≥1 neighbour spec in the same area, when neighbours exist     |
| Accessibility | Contrast meets WCAG AA (`principles.md` C4); ARIA roles/labels; 44px min touch target (M1) |

---

## Mode B — greenfield / BOOTSTRAP (no DS)

No tokens exist yet, so DROP all token rules above. The variant must instead be
internally consistent against the "hand" it chose (`.claude/skills/design-ui/hands.md`).

| CHECK                | PASS criterion                                                                          |
| -------------------- | --------------------------------------------------------------------------------------- |
| Self-consistent ramp | Variant DEFINES and OBEYS its own type scale, color ramp, spacing, depth                |
| Design-system-map    | A short map (type scale / color ramp / spacing / depth) is present before markup        |
| Anti-AI              | Same redesign.md anti-AI rules as Mode A (gradient / 3-card / centered / Lorem / icons) |
| Motion               | Same emil-design.md motion rules as Mode A                                              |
| Accessibility        | Contrast meets WCAG AA; ARIA roles/labels; 44px min touch target                        |

---

## Pre-flight outcome

Every row of the active mode either holds or is fixed before the mockup goes to the critic. A row
you deliberately break (a brief-level decision) is written into `$RUN/brief.md` → `Constraints`,
so the critic reads it as a decision, not a defect. There is no score and no cap here — the
critique loop (`SKILL.md` → Phase 2) is where findings are counted, judged and capped.
