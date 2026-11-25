# /wcag-audit — method and limits

`/wcag-audit` is a **scan of the given URLs** and of the states it opens, not a conformance audit:
no sampling, no complete processes, no login. The report prepares a professional accessibility and
legal review; it never states conformance.

## Evidence model

Three axes, never merged into a score:

1. **Outcome** per occurrence: `violation` · `needs-review` · `pass` · `inapplicable` · `error`.
2. **Basis:** ● verified (an engine violation or a deterministic threshold below) · ◐ suspected
   (heuristic, engine `incomplete`, model judgement) · ○ human required. In doubt, the lower basis wins.
3. **Impact:** blocker · serious · moderate · minor.

Per criterion the runner plans the expected units before the first navigation (page × viewport ×
state × contributor) and derives the status by precedence: `fails` (any ● violation) → `suspected`
(any published ◐ item) → `n/a` (the applicability detector found nothing anywhere) → `no automated
failure found` (every unit completed) → `not tested` (`no contributor`, or `partial coverage k/n`).
No criterion is ever shown as passed.

## Own measurements

| Check | SC | ● when | ◐ otherwise | Does not detect |
|---|---|---|---|---|
| keyboard-walk | 2.1.1 | — | a visible enabled native control never reached in a completed Tab cycle | delegated handlers; gestures |
| keyboard-trap | 2.1.2 | focus stays in one container for 10 Tab and 10 Shift+Tab presses and Escape does not leave | a cycle only an unusual key ends | traps in cross-origin frames |
| focus-visible | 2.4.7 | bbox ±12 px pixel-identical before/after focus and no computed style change | small pixel diff without a style change | low-contrast indicators |
| focus-obscured | 2.4.11 | every point of a 5×5 grid is covered by painted author content | full coverage by content not provably painted | user-agent UI; partial obscuring |
| arrow-widgets | 2.1.1 | — | arrow keys move neither focus nor `aria-activedescendant` in a composite role | widgets without a role |
| target-spacing | 2.5.8 | — (axe `target-size` is the ● signal) | target under 24×24 px whose 24 px circle meets another target | equivalent / essential exceptions |
| reflow | 1.4.10 | at 320 px a control is clipped and unreachable | page-level horizontal scroll | loss inside canvas/images; 2-D content is `inapplicable` |
| text-resize | 1.4.4 | — | text clipped after text-only 200 % scaling | zoom-based failures |
| text-spacing | 1.4.12 | text newly clipped after the WCAG text-spacing CSS | — | spacing set by script after load |
| contrast-render | 1.4.3 | — | worst sampled background below the threshold where axe was `incomplete` | text inside images |
| hover-focus | 1.4.13 | — | hover/focus content not dismissible with Escape | content shown by click |
| heuristics | 2.4.1, 2.2.2, 2.5.7, 3.3.8, 4.1.3, 1.3.4 | — | skip link missing or not moving focus; autoplay without pause; drag without alternative; paste blocked on credentials; form without live region; content hidden in landscape | anything needing interaction past focus |

## Browser boundary

- One headless Chrome launch per run with `chromiumSandbox: true` and a temporary profile; a fresh
  context per URL × viewport and per state; `serviceWorkers: 'block'`.
- **Destination policy at the connection boundary:** every connection goes through a loopback forward
  proxy (`bypass: '<-loopback>'`) that resolves the host itself, refuses when any address is
  link-local, unspecified, multicast or reserved, allows loopback/private addresses only for the given
  origins of a loopback/private run, and connects to the validated address. A live probe after launch
  proves the proxy refuses a runner-owned loopback origin.
- **Method enforcement and lockdown:** non-GET/HEAD requests are aborted; after the load and settle of
  a page, every request is aborted (`interaction-lockdown`), so **no request is caused by the runner's
  interactions** (banner dismissal, states, keyboard walk, CSS injections). WebSockets and WebRTC are
  blocked. Content that would need a fetch after load is ledgered.
- The browser and the proxy are closed in `finally`, on SIGINT/SIGTERM and on the time limits.

## Collection policy

Stored URLs keep scheme, host and path (query values and fragments become `…`); e-mail-shaped text
becomes `[email]`; accessibility-tree excerpts keep only role, name, description, ignored reasons and
states, never `value`; every crop masks inputs, text areas, selects, editable regions, e-mail text and
skipped frames with `#FF00FF`. No cookies, headers, storage or form values are stored, and the runner
never types into a field.

## Model phases

Only with the model on and the read guard proven: `@wcag-judge` reads only the files of the active
pack manifest (its own PreToolUse hook), judges semantic items, and a fresh disprove pass upholds or
rejects each candidate. Only upheld candidates are published, always as ◐. The model can never change
an engine or measurement outcome and can never mark a criterion as met.

## Limits

`--max-pages` 10 by default, 120 s per URL × viewport, 20 min per run, 5 opened states per page,
250 Tab presses per walk, 80 items per judge pack. Every limit hit goes to the coverage ledger.
