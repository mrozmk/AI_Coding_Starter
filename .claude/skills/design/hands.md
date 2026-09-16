# Design Hands — Greenfield / BOOTSTRAP Profiles

Adapted from `leonxlnx/taste-skill` (MIT, © 2026 Leonxlnx).

> **BOOTSTRAP only — these REPLACE the design system; never use in DS mode.**
>
> A "hand" is a complete aesthetic identity for greenfield work (no existing DS).
> Available hands: **minimalist** and **soft** (brutalist intentionally omitted — see below).
> In DS mode (FIX / NEW-to-DS) discard this file entirely — dials drive layout only,
> tokens come from the project's detected token source (`/design` Phase 0).

---

## Minimalist Hand

Locked dials: **DESIGN_VARIANCE 4 / MOTION_INTENSITY 3 / VISUAL_DENSITY 3**

| Attribute    | Specification                                                             |
| ------------ | ------------------------------------------------------------------------- |
| Palette      | 1 neutral (near-black or near-white base) + 1 accent (single strong hue)  |
| Typography   | Monospace or geometric sans (Inter, Helvetica); tight tracking; few sizes |
| Radius       | 0–4px; prefer sharp edges                                                 |
| Shadows      | None — use borders for depth; `1px solid` dividers only                   |
| Layout       | F-pattern or symmetric grid; generous whitespace; single focal point      |
| Motion       | Instant or 80–120ms opacity fade; no decorative movement                  |
| Guiding rule | Subtract until breaking; every element must justify its presence          |

---

## Soft Hand

Locked dials: **DESIGN_VARIANCE 5 / MOTION_INTENSITY 6 / VISUAL_DENSITY 4**

| Attribute    | Specification                                                             |
| ------------ | ------------------------------------------------------------------------- |
| Palette      | Pastel base + muted complementary accent; no pure white or pure black     |
| Typography   | Rounded humanist sans (Nunito, Quicksand); 400/600 only; relaxed leading  |
| Radius       | 12–24px; pill buttons; no hard corners                                    |
| Shadows      | Tinted soft shadows (`box-shadow: 0 8px 32px <accent>20`); no pure-black  |
| Layout       | Split-screen or editorial; asymmetric-hero welcome at DV 5                |
| Motion       | Spring easing for hover + reveals; 200–300ms; stagger on lists            |
| Guiding rule | Warm, approachable, never cluttered; delight through tactile micro-motion |

---

## Custom / Brand Hand (on-demand)

A third hand can be derived ad-hoc from a WebFetched brand `DESIGN.md` from
[VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) (72 brand profiles).

Workflow: WebFetch the target brand's raw `DESIGN.md` → extract palette + type + radius +
shadow → set dials to match brand personality → treat as a custom locked hand for this session.

No brand files are vendored in this repo; fetch on demand only.

---

## Brutalist Hand — omitted by default

Brutalism (raw grids, unformatted type, aggressive contrast) is intentionally left out of the
default hand set: it conflicts with most premium / trust-building product positioning, and it is
the easiest aesthetic to get wrong. If a project's brand genuinely calls for it, add it as a
custom hand (above) with the project's own brand `DESIGN.md` as the source — don't reach for it
as a default greenfield option.
