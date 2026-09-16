# Self-Check — Design Quality Gate

The gate the `design` skill runs against EVERY mockup (every variant) **before** the user
sees it. This is the GATE, not the full audit — for the exhaustive property diff see
`.claude/commands/gates/design-quality-check.md`. Deep rule references:
`.claude/skills/design/emil-design.md` (motion), `.claude/skills/design/redesign.md` (anti-AI),
`.claude/skills/design/dials.md` (variance/density). The token set is the **project's detected
design system** (resolved in `design.md` Phase 0 — CSS custom properties / Tailwind theme /
`tokens.css` / `theme.ts`), not a fixed list.

**Mode is chosen by `design.md` Phase 0 and passed in — do NOT re-detect here.**
Run the gate independently per variant.

---

## Mode A — DS present (NEW-to-DS / FIX)

The design system exists; variants differ by layout/composition, NOT by palette/fonts.
Every row must PASS or the finding counts toward the verdict. "Token" below means a value
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

---

## Mode B — greenfield / BOOTSTRAP (no DS)

No tokens exist yet, so DROP all token rules above. The variant must instead be
internally consistent against the "hand" it chose (`.claude/skills/design/hands.md`).

| CHECK                | PASS criterion                                                                          |
| -------------------- | --------------------------------------------------------------------------------------- |
| Self-consistent ramp | Variant DEFINES and OBEYS its own type scale, color ramp, spacing, depth                |
| Design-system-map    | A short map (type scale / color ramp / spacing / depth) is present before markup        |
| Anti-AI              | Same redesign.md anti-AI rules as Mode A (gradient / 3-card / centered / Lorem / icons) |
| Motion               | Same emil-design.md motion rules as Mode A                                              |
| Accessibility        | Contrast meets WCAG AA; ARIA roles/labels; 44px min touch target                        |

---

## Verdict

Count findings across the active mode's rows:

| Findings | Verdict     | Action                          |
| -------- | ----------- | ------------------------------- |
| 0        | **APPROVE** | Present the variant to the user |
| 1–10     | **WARN**    | Fix in place, re-audit          |
| 11+      | **BLOCK**   | Fix in place, re-audit          |

**Fix loop: cap 2 iterations.** On WARN/BLOCK, fix the findings in-place and re-run the
gate. If still failing after 2 iterations, STOP grinding — present the remaining findings
and let the user decide. Each variant runs this gate independently; a BLOCK on one variant
does not block the others.
