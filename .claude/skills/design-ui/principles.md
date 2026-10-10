# UI/UX Principles — the rubric the author designs to and the critics judge against

The judgement layer `/design-ui` was missing: `self-check.md` covers tokens, motion and anti-AI
tells, this file covers **whether the screen helps a person decide and act**, and the visual
craft that makes it read calmly. Every rule has an ID — a critic finding cites one (or names the
principle it rests on); a finding that cites nothing is taste and gets dropped (`critique.md`).

Rules are defaults, not laws. A brief or a design system can override one deliberately — say so
in the brief and the critic honours it. Numbers are floors and bands, not targets.

Distilled in our own words from the sources listed in `CREDITS.md`.

---

## H — Hierarchy and the decision

- **H1 Rank before you draw.** List what the screen shows by importance *to the user's task*
  (the brief's `Content rank`). Size, weight, colour and position follow that rank — the most
  important thing is the most prominent. Values outrank their labels (`591` big, `Views` small).
- **H2 One primary action per view.** The primary action is the most prominent control;
  secondary actions are visibly quieter (neutral, ghost, text); destructive actions are never
  styled as the default. Hue alone is not hierarchy — three buttons of equal size in three
  colours are three primaries.
- **H3 Decision information together, in decision order.** What it is → can I trust it → what it
  costs → act. Trust signals (rating, reviews, guarantees) sit next to the thing they qualify, not
  at the bottom of the page.
- **H4 The action sits with its inputs.** Controls that configure an action (quantity, variant,
  size, unit) come immediately before it, in task order. When the action commits to a cost,
  show the consequence on it (`Add to cart · €15.98`).
- **H5 Show, don't hide, a few options.** Up to ~6 choices → visible chips, swatches or a
  segmented control, not a dropdown. Surface the value itself instead of a banner that links to it.
- **H6 Cut what the task does not need.** Every element costs attention. Task flows (sign-up,
  checkout, forms) carry no unrelated promotions. Decoration that does not compete is fine.
- **H7 Size to content, not to the screen.** A form or a checkout does not stretch to fill a
  1440px canvas — give fields the width they need and let space frame the task.

## L — Layout, spacing, alignment

- **L1 One spacing scale.** A base unit (4 or 8) and its multiples — or the DS spacing tokens.
  Off-scale values (13, 19, 31, 37px) are a smell.
- **L2 Proximity carries meaning.** Space inside a group is smaller than space between groups:
  a label sits closer to its own field than to the previous field (e.g. 8 vs 24). Equal gaps
  everywhere make grouping unreadable.
- **L3 Shared edges.** One left edge per column; elements of one column start on it. Body text is
  left-aligned; centring is for ≤ 3 short lines (titles, empty states). Numbers that are compared
  are right-aligned with tabular figures.
- **L4 Separate with space first.** Then a tone/background shift, then a thin light line. Heavy
  dark dividers and stacked borders chop the page into slabs.
- **L5 Rows of cards stay even.** Same height in a row, CTAs pinned to the card bottom, similar
  copy length where the copy is ours to shape.
- **L6 Whitespace has a direction.** Start generous and tighten until groups read as groups; too
  much space between related sections disconnects them just as too little crowds them.

## T — Typography

- **T1 One family is the norm, two the ceiling.** Hierarchy comes from size, then weight, then
  colour — not from swapping families.
- **T2 Readable sizes and leading.** Body ≥ 16px on the web (≥ 15px acceptable on dense mobile
  UI); nothing a user must read below 12px. Body line-height 1.4–1.6; headings tighter (1.1–1.3)
  — a heading's line-height above the body's is a defect.
- **T3 Line length.** Body copy 45–75 characters per line on desktop, ~30–40 on a phone.
- **T4 Headings lead, body supports.** Headings darker and heavier than body; body a softened ink
  (not pure `#000` on pure `#fff`, not pure white on dark for long text).
- **T5 No extremes.** No thin/extra-light weights for text people read; no pale grey chosen for
  looks over contrast.
- **T6 Caps are for short labels.** Small uppercase labels get positive tracking; buttons, badges
  and anything over ~3 words stay in sentence case — all-caps on a large button shouts.
- **T7 Break up long text.** Short paragraphs, subheadings, bullets for scannable facts; the best
  facts are not buried in a paragraph.

## C — Colour, contrast, depth

- **C1 Accent means "act here".** Surfaces stay neutral; the primary/accent colour is reserved for
  interactive elements and the one thing that must stand out. When everything is accent, nothing is.
- **C2 A small palette.** Neutrals + one accent + semantic colours, desaturated enough to support
  the content. Several unrelated saturated hues on one screen is noise.
- **C3 Status is never colour alone.** Pair colour with text and/or an icon. Semantic colours
  follow convention: red error/destructive, green success, amber warning.
- **C4 Contrast floors (WCAG AA).** Text ≥ 4.5:1 (large text — ≥ 24px, or ≥ 18.7px bold — ≥ 3:1);
  icons and control boundaries ≥ 3:1. White text on mid-saturation orange/pink/green usually fails.
- **C5 Depth is a system.** Soft shadows tinted toward the background, a small elevation scale
  (low / mid / high); a shadow lifts what floats (menus, modals, controls over maps or photos).
- **C6 Text and icons over imagery bring their own backdrop.** A scrim, blur or chip behind them,
  so they hold on light, dark and busy images alike — design for the image you have not seen yet.
- **C7 Effects must earn their place.** Glass, gradients, texture only when they serve the brand
  and keep readability on every background they can land on.

## K — Components and consistency

- **K1 One shape language.** Radii from one scale; inner radius ≤ outer.
- **K2 One style per button role** across the page — never per-card colours for the same role.
- **K3 One icon set, one style, one stroke weight.** Outline vs filled mixed only to signal state
  (filled = active tab). Emoji are not icons.
- **K4 Imagery behaves as a system.** Same framing, background and crop across a grid or catalogue;
  a beautiful image that breaks the set is the wrong image.
- **K5 Inputs fit their data.** Field width matches the expected input (CVC short, card number
  long); one-time codes as segmented boxes; a show/hide toggle instead of a confirm-password field;
  inline validation as the user types; units inside or beside the field.
- **K6 Destructive confirmations.** The destructive button says the verb (`Delete project`), uses the
  destructive colour, and a safe way back is always present.
- **K7 Empty and error states guide.** Empty: what this place is for + the next action. Error: what
  happened + how to fix it, in the product's normal visual style.
- **K8 Badges are glanceable.** ≤ ~3 words; one idea; no emoji stacked on top of the words.

## M — Mobile and touch

- **M1 Touch targets ≥ 44×44px** (48 preferred), with ≥ 8px between neighbours. A 20px stepper
  button is a defect even when it looks tidy.
- **M2 Primary actions in the thumb zone.** On a phone the main action lives in the lower part of
  the screen; on long pages a sticky action bar keeps it reachable.
- **M3 Keep context while scrolling.** Long detail pages keep the title (e.g. collapsing into the
  top bar) and the primary action reachable.

## X — Content and robustness

- **X1 No redundancy.** No label the format already says (`Price:` before `€7.99`); no claim stated
  twice. If you label one control in a row, label its siblings too — or none.
- **X2 No contradictions.** Static text never contradicts a control (a title fixed at `1 kg` next
  to a quantity selector); a discount shows what it is discounted from.
- **X3 Stress the content.** The layout survives long and short strings, 0 / 1 / many items, light /
  dark / busy images, and translated labels (+30–40% width).
- **X4 Specific and honest.** Concrete facts over generic claims (`Picked this morning, 40 km away`
  beats `Top quality`); no invented metrics, reviews or urgency.

---

## Moves worth considering (ideas for the author — critics do not score these)

- A form laid out like the thing it creates (a listing form shaped like the listing page).
- Presets for the common choice next to the free input (`500 g · 1 kg · 2 kg` + a stepper).
- Exposing the first useful content directly instead of an intro banner.
- A content card that slides over a hero image, with the title collapsing into a sticky top bar.
- Avatars/logos as visual cues in lists people scan by sender or brand.
