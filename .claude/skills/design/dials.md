# Design Dials — Reference

Adapted from `leonxlnx/taste-skill` (MIT, © 2026 Leonxlnx). Method distilled; the dials drive
composition/motion/density only — palette, fonts, and tokens come from the **project's own design
system** when one exists (see the DS-mode caveat below), never from upstream defaults.

---

## The Three Dials (1–10)

| Dial               | What it controls                                                            | Low (1–3)                              | Mid (4–6)                                | High (7–10)                                   |
| ------------------ | --------------------------------------------------------------------------- | -------------------------------------- | ---------------------------------------- | --------------------------------------------- |
| `DESIGN_VARIANCE`  | How far the layout/composition departs from conventional grids and symmetry | Safe, predictable, grid-aligned        | Mild breaks, one hero departure          | Asymmetric, editorial, high-contrast zoning   |
| `MOTION_INTENSITY` | Density and expressiveness of transitions, reveals, and micro-interactions  | Instant or near-instant; no decorative | Short enter + hover only; < 150ms        | Orchestrated sequences; spring; stagger       |
| `VISUAL_DENSITY`   | Information packing — whitespace vs. content per viewport                   | Sparse, breathing room, single focus   | Balanced sections; standard card padding | Dense bento, packed grids, minimal whitespace |

---

## Per-Surface Defaults

| Surface         | DESIGN_VARIANCE | MOTION_INTENSITY | VISUAL_DENSITY | Notes                                                       |
| --------------- | --------------- | ---------------- | -------------- | ----------------------------------------------------------- |
| Dashboard / app | 5               | 4                | 7–8            | Dense data; motion stays subtle; layout conventional        |
| Landing / hero  | 7               | 7                | 3              | Bold composition + expressive motion; roomy breathing space |
| Dev-tool / docs | 5               | 4                | 6              | Functional; density moderate; minimal decorative motion     |
| Global default  | 6               | 5                | 5              | Balanced starting point when surface type is ambiguous      |

---

## Dial-Set → Layout Pattern + Motion Vocabulary

| DESIGN_VARIANCE | Preferred Layout Patterns                               | Motion Vocabulary                                               |
| --------------- | ------------------------------------------------------- | --------------------------------------------------------------- |
| 1–3             | Z-pattern / F-pattern, symmetric columns, standard grid | Fade-in on enter, hover color-shift only                        |
| 4–6             | Split-screen, sidebar + canvas, editorial               | Short slide-up (12–16px, 200ms), hover lift (translateY -2px)   |
| 7–10            | Bento grid, asymmetric-hero, full-bleed editorial       | Staggered reveals, spring overshoot (decorative), hero parallax |

### Layout-Pattern Glossary

- **Bento grid** — mosaic of unequal-height tiles; high density, non-uniform column spans.
- **Split-screen** — viewport halved into two distinct content zones (text/visual, dark/light).
- **Editorial** — text-dominant, large leading, wide gutters, pull-quotes or super-sized type.
- **Sidebar + canvas** — fixed nav/controls rail + dynamic main area (dashboards, tools).
- **Z-pattern** — diagonal eye path: top-left logo → top-right CTA → bottom-left feature → bottom-right CTA.
- **F-pattern** — two horizontal scan lines then vertical skim; works for text-heavy / list-heavy pages.
- **Asymmetric-hero** — off-center headline, oversized visual element bleeding past column bounds.

---

## DS-mode Caveat (critical)

When the project **has a design system** (DS mode / FIX / NEW-to-DS), the dials drive
**layout composition, motion intensity, and information density only**.

They do NOT change:

- **Color palette** — always the project's themeable tokens (CSS custom properties / Tailwind
  theme / `theme.ts` — whatever `/design` Phase 0 detected). No ad-hoc hex, no new accents.
- **Typography** — always the project's configured UI/body and numeric typefaces.
- **Token set** — always pulled from the project's detected token source; no pastel substitution,
  no font swap, no light-bg in a dark DS (or vice versa).

In DS mode, two variants at DESIGN_VARIANCE 4 vs 8 look genuinely different (editorial vs
bento) while sharing every design token. The dials provide compositional differentiation,
not aesthetic substitution.

The "hands" (minimalist / soft) defined in `hands.md` are for **greenfield only** and must
never be applied in DS mode.
