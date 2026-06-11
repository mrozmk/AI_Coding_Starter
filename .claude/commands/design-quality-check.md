---
description: Pixel-perfect audit of an implemented UI section vs its reference design
argument-hint: [section-name] [reference-file?]
---

# /design-quality-check — Design-Parity Audit

Compare a section of the live application against its **reference design** in `.agents/specs/design/Ready/`. Find **every** deviation — visual, structural, semantic, behavioral, responsive, accessibility. Do NOT modify code. Report findings only.

This command is the inverse of `/verify-implementation`: that one checks code quality against a plan; this one checks **design fidelity** after any implementation pass (initial build, fix-up, redesign).

> **Stack-neutral.** This skill audits parity for any UI stack — HTML/CSS, React/Vue/Svelte, native, etc. It names dimensions to check (layout, type, color, motion, a11y, …), not the syntax of one framework. Where a concept needs a concrete form (a class name, a token, a unit), resolve it in **the project's own stack** and compare values, not spellings. If your project standardized on a specific toolchain (a CSS framework, an icon set, an i18n format), apply that knowledge when locating and resolving values — but the audit categories below are the same regardless.

---

## Core principle

**There are no minor differences in design.** If the reference has a value (a color, a padding, a font weight, a letter-spacing, a transition timing, a shadow opacity, an aria attribute, a gradient stop) and the implementation has a different value — that is a **defect**. Period.

Design quality = perfection. "Similar" is not "identical." If you find yourself thinking "this difference is small, maybe skip it" — **list it anyway**. The user decides what is acceptable, not the auditor.

Only differences explicitly authorized by the user (documented in the plan or in conversation) may be omitted — and even then, record them under "Authorized deviations" so the report is complete.

---

## 0. The reference-design contract

The reference design lives in **`.agents/specs/design/Ready/`**. This directory is the opt-in trigger: if it does not exist, there is nothing to audit against (and `/orchestrate` skips the design phase entirely). A reference artifact may be any of:

- a **standalone HTML/CSS mockup** (the most precise — every value is inspectable),
- an **exported design** (e.g. a Figma/Sketch export, a design-tokens JSON, a style guide),
- **annotated screenshots** plus a spec of tokens/spacing,
- a **component storybook** entry treated as canonical.

Whatever the form, it defines the **expected** model. Read it in full before auditing.

---

## 1. Resolve scope

Parse `$ARGUMENTS`:

1. **Section / component name** (required): the area to audit (e.g. a page section, a component, a screen). May also be a filename.
2. **Reference file** (optional): explicit path to the reference artifact. If omitted:
   - Default: the most recent / best-matching artifact in `.agents/specs/design/Ready/`.
   - If multiple plausible artifacts exist, ask the user which to use.

If no section provided → STOP and ask which section to audit.
If no reference design exists at `.agents/specs/design/Ready/` → STOP and tell the user: "No reference design found at `.agents/specs/design/Ready/`. Pass an explicit reference path or add one."

---

## 2. Locate the live implementation

Find the files that render this section in the project's UI stack, following the project's own conventions (consult `architecture.md` / `patterns.md` if primed):

1. `Glob` for the section's component/template/view files (and their adjacent sub-components, cards, partials).
2. `Grep` for the section's identifying class names, ids, test-ids, or component names.
3. Walk the import/include graph: read the section file, follow every child it composes (sub-components, shared widgets, icons).
4. Read the **content/localization** sources the section consumes (i18n message files, CMS fixtures, content constants).
5. Read the **style/token** sources the section depends on (global stylesheet, theme/token definitions, design-system entry points).
6. Read the **layout/shell** the section renders inside (root layout, global font/typography setup, providers).

Build a **list of in-scope files** and print it before auditing, so the user knows the surface being checked.

---

## 3. Parse the reference → the expected model

From the reference artifact, extract for the target section:

1. **Markup / structure tree** — every element/node, its identity (class/role/type), attributes, and children.
2. **Every style rule** that applies — including pseudo-elements, pseudo-classes (hover/focus/active), and responsive/conditional rules (media/container queries).
3. **Every content string** the section renders (in the design's locale).
4. **Every animation / transition** the section's elements reference (keyframes + timing).
5. **Every design token** the section reads (resolve each to its concrete value).

This is the **expected** model.

---

## 4. Build the actual model

Read each in-scope file. For every visible element, extract the same dimensions:

- Tag/node type, identity (classes, component name), inline styles, and any arbitrary/one-off style values.
- **Resolved** style values — convert framework shorthands or token references to concrete values (px, hex/rgba, ms) before comparing. A shorthand that resolves to the right value is fine; one that resolves to a different value is a defect.
- Transitions, animations, transforms.
- `aria-*`, `role`, `data-*`, and other semantic/behavioral attributes.
- For form/interactive elements: input type, input mode, autocomplete, validation attributes, labels, and the visible side-effects of handlers.
- For dynamic content: which content/i18n key feeds which slot.
- For icons: the exact icon identity (two glyphs with similar names are different glyphs), weight/variant, size, and color.

Resolve every token reference to its concrete value and compare against the design's tokens.

This is the **actual** model.

---

## 5. Diff every dimension — exhaustive checklist

Compare expected vs actual. Walk the structure depth-first. For **every element**, check **every dimension** below. **Do not skip a category** because it "looks obviously fine" — verify.

### 5.1 Layout & box model
`display` / flex / grid properties (direction, alignment, wrap, template, gaps), `position` + offsets, `z-index` (and stacking context), sizing (`width`/`height` + min/max), viewport units (`vh`/`dvh`/`svh` are not interchangeable), padding & margin **per side** (asymmetric values matter), `box-sizing`, `overflow`.

### 5.2 Typography
`font-family` (and fallback chain), `font-size` (exact; if fluid, all clamp args must match), `font-weight` (700 ≠ 800 ≠ 900), `line-height`, `letter-spacing`, `text-transform`, `text-align`, text wrapping/balancing, font-feature/variant settings (they change glyph shapes), `font-style` resets, smoothing/rendering hints.

### 5.3 Colors
`color`, background color, gradients (every stop, position %, and angle — a 2-stop gradient is not a 3-stop gradient), border color, placeholder color (alpha differences are visible). Resolve every token to its concrete value and compare hex/rgba.

### 5.4 Borders
`border-width` / `style` / `color` per side, `border-radius` per corner (a full pill ≠ a fixed radius), outline + offset (focus rings).

### 5.5 Shadows & filters
`box-shadow` (each layer: offsets, blur, spread, color, alpha, inset), text-shadow, `backdrop-filter`, `filter`, blend modes, mask images, base `opacity` (independent of any animated opacity).

### 5.6 Transforms & animations
`transform` (translate/scale/rotate — and order), transform-origin, `transition` (every property, duration, easing, delay — `transition: all` is a smell, not equivalence), `animation` (name, duration, easing, iteration, direction, fill-mode), compare **keyframe definitions** not just names, motion-reduction overrides.

### 5.7 Interactive states
`:hover`, `:focus` / `:focus-visible` / `:focus-within` (ring color, glow, background), `:active` (tactile micro-feedback like a slight scale), `:disabled` (opacity, cursor), placeholder styling, selection styling.

### 5.8 Content & localization
Compare **every visible string** literal-for-literal: ellipsis vs three dots, em-dash vs en-dash vs hyphen, smart vs straight quotes, locale-specific characters/diacritics, trailing arrows, spacing around punctuation. For non-default locales: is the translation faithful to the design? Flag rephrasings/additions/omissions. Check for dead, duplicated, or missing content keys.

### 5.9 Markup structure & semantics
Tag/element choice (a semantic landmark vs a generic container), heading levels (exactly one top-level heading per page), presence of structural wrappers that carry layout intent (max-width, stacking) even when visually similar at one viewport, inline-semantic elements and their resets, sibling order, intentional line breaks, correct list/definition structures.

### 5.10 Accessibility (a11y)
`aria-label` / `labelledby` / `describedby`, `aria-live` + atomic (rotating/async content), `aria-hidden` on decorative elements, state attributes (`aria-pressed`/`expanded`/`controls`), `role`, focus order + `tabindex`, skip-links + landmarks, image alt text, form label association + `aria-required`/`aria-invalid`.

### 5.11 Form / interactive attributes
Input type, input mode, autocomplete, validation attributes (pattern/min/max/step/maxlength), placeholder text + color, disabled/readonly behavior, submit behavior (Enter vs click), error display (position, color, alert role, live region).

### 5.12 Responsive
For **every** responsive rule in the design, verify the implementation has an equivalent override. Match breakpoints exactly. Check padding/gap shifts, layout shifts (row→column, multi-col→single), hidden/shown elements, width shifts, and font-size shifts. Desktop-only matching is not enough.

### 5.13 Icons
Exact icon identity (similarly-named glyphs are different), weight/variant, size in concrete units, color, and position relative to text. Verify the import/source, not just the rendered name.

### 5.14 Design tokens
For every token the section references: does it exist in the live app, and does its **value** match the design's? Naming differences are not defects if values match; value differences always are.

### 5.15 Animations & keyframes
Keyframe names (or intentional aliases) match, each step's property values match, animation timing/iteration/direction/delay/fill-mode match, compound animations preserve order.

### 5.16 Browser-specific & edge cases
Vendor prefixes where the design uses them, mobile viewport-unit handling, subpixel hints, print styles (if relevant), and any theme/dark-mode handling.

---

## 6. Live visual validation (Playwright MCP) — optional

If the project's dev server (or a reachable deployed URL) is available, validate rendering — otherwise do a static-only audit and say so.

1. `mcp__playwright__browser_navigate` to the page hosting the section (use the project's local dev URL; ask if unknown — do **not** assume a hardcoded host).
2. `mcp__playwright__browser_resize` to a desktop size (e.g. 1440×900), screenshot the section.
3. `mcp__playwright__browser_resize` to a mobile size (e.g. 375×812), screenshot the section.
4. If the section has multiple locales, repeat per locale.
5. `mcp__playwright__browser_snapshot` — capture the accessibility tree.
6. `mcp__playwright__browser_console_messages` — flag errors/warnings.
7. Render the reference artifact at the same viewports and screenshot the matching section.
8. Compare side-by-side; note every visible difference (alignment, color saturation, spacing, rendering).

If the dev server is **not** running: skip live screenshots (note it), do not start a long-running server without authorization, and proceed with the static audit. If the reference references external resources (web fonts, CDNs) that won't load offline, note rendering caveats — the audit of values is unaffected.

---

## 7. Catalog every finding

Number every defect sequentially. Do not collapse, deduplicate, or summarize. Group by element/component for readability, but **each property delta is its own line item**.

For each finding capture: **ID**, **Element**, **Property**, **Expected (design)**, **Actual (live)**, **Source (design)** (file:line), **Source (live)** (file:line), **Fix** (the concrete change).

Use a **stable per-element ID scheme** (e.g. group elements as `A`, `B`, `C` … and number within each: `A1`, `A2`). Reuse the same scheme across audits of the same section so reports are diffable over time.

---

## 8. Output format by volume

Count total findings:

- **0** → APPROVE. Single-paragraph report inline.
- **1–10** → WARN. Inline table in chat. Brief per-finding fix.
- **11–25** → BLOCK. Full table inline. End with: "Recommend saving this to `.agents/plans/active/<section>-design-fixes.md` for the implementer."
- **26+** → BLOCK. Do **not** dump all findings into chat. Instead:
  1. Write the full report to `.agents/plans/active/<section>-design-fixes-YYYY-MM-DD.md` (today's date).
  2. In chat: total count, breakdown by category, top 5 most impactful defects, and the file path.
  3. Recommend `/execute` (or `/orchestrate`) against the new plan once the user approves.

The threshold exists because dumping 50+ findings into chat buries the conclusion and burns context. The plan file is the artifact the implementer (and `/execute`) actually consumes.

---

## 9. Output template

```markdown
## Design Quality Check: <section> vs <reference>

### Scope
- Live files audited: [list]
- Reference design: [path + line range]
- Viewports tested: desktop [✅ / ⏭️ skipped — reason], mobile [✅ / ⏭️]
- Locales tested: [list / ⏭️]

### Summary
Total findings: N
- Layout & box model: X
- Typography: X
- Colors & gradients: X
- Borders, shadows, filters: X
- Transitions & animations: X
- Interactive states: X
- Content & localization: X
- Markup structure: X
- Accessibility: X
- Forms: X
- Responsive: X
- Icons: X
- Tokens: X

### Findings
[If ≤ 25, full table inline:]

| ID | Element | Property | Expected | Actual | Design source | Live source | Fix |
| -- | ------- | -------- | -------- | ------ | ------------- | ----------- | --- |
| A1 | ...     | ...      | ...      | ...    | ...           | ...         | ... |

[If > 25, write to .md and link:]
Full report saved to `.agents/plans/active/<section>-design-fixes-YYYY-MM-DD.md` (N findings).
Top 5 most impactful:
1. [ID] — [one-line summary]
2. ...

### Authorized deviations
[Anything the user explicitly accepted, or N/A.]

### Verdict
[✅ APPROVE / ⚠️ WARN / ❌ BLOCK]

### Next steps
- [If APPROVE: ready for next section / commit / deploy]
- [If WARN/BLOCK: implement fixes (or run /execute on the linked plan), then re-run /design-quality-check]
```

---

## CRITICAL rules

- **Never modify code.** This is a read-only audit.
- **Never collapse findings.** Two visually-similar deltas are still two deltas. The user decides what to act on.
- **Never assume a difference is acceptable** because it "looks close enough." Pixel-perfect means exact values match.
- **Never skip a category** because the section "doesn't seem to use it." Verify, don't assume.
- **Resolve every token / shorthand to its concrete value** before comparing — naming differences are not value differences, but unresolved comparisons hide real defects.
- **Icon identities are not interchangeable.** Similarly-named glyphs differ — check the import/source, not just the rendered name.
- **Diacritics, smart quotes, em-dashes, and ellipses are content, not formatting.** A wrong character is a defect.
- **For responsive, check every breakpoint in the design** — desktop matching is not enough.
- **Missing `aria-live` on rotating/async content is a defect**, even though it's invisible.
- **If you can't tell whether a property matches**, list it as a finding with "needs verification" rather than skipping.
- **Bias toward over-reporting.** A perfect audit lists every delta. The user prunes; the auditor does not.
- **Do not hardcode hosts, paths, or stack assumptions** from any one project — resolve them from the project at hand.
