---
name: architecture-doc
description: Generate a human-readable architecture document that renders the system as a set of complementary FLOWS (technical, data, temporal, business, and more — picked per project) as Mermaid diagrams in a self-contained HTML. NOT the audit-style /architecture-review (that hunts shallow modules to refactor) and NOT /architect (that decides structure before code) — this one explains and confirms how the built system fits together. Analyze-only; never mutates code. Use when the user wants to see/understand/confirm the architecture, data flow, or "how it all connects" on a diagram.
argument-hint: "[scope — e.g. 'MVP only', a subsystem, a feature, or empty = whole system]"
---

# /architecture-doc — explain the system as flows, on a diagram

## Scope: $ARGUMENTS

<PURPOSE>
Produce a **human-facing** architecture document: a self-contained HTML with Mermaid diagrams that
render several **complementary flows** of the same system. The goal is comprehension and confirmation
— the user wants to *see* the technical flow, the data flow, the business flow, the timing — to
verify their mental model matches reality. This is the inverse of `/architecture-review`: that audits
code quality (shallow modules, deepening candidates); **this explains and confirms structure**. It is
not `/architect` either: that decides the structure *before* code, from requirements; this draws what
was built.
</PURPOSE>

<HARD-RULES>
- **Analyze-only.** Never edit source code. The only file you create is the HTML report (+ optionally
  a memory entry if a real architectural decision surfaced).
- **No invented architecture.** Every node, edge, and interface in a diagram must trace to real code,
  config, or a documented decision. If you haven't verified it, you may not draw it (see Step 2).
- **Flows, not one mega-diagram.** A single all-in-one diagram is unreadable. Pick 3–5 flows that each
  answer one question, and give each its own diagram.
</HARD-RULES>

---

## Why multiple flows (the core idea)

One diagram cannot show everything without becoming noise. Different stakeholders ask different
questions, and each question wants a different *projection* of the same system. This command renders
several, each answering one question:

| Flow | The question it answers | Best Mermaid shape |
|------|-------------------------|--------------------|
| **Technical / container** | What process/service/file talks to what? Where are the seams (network, file, IPC, DLL)? | `flowchart` with `subgraph` per runtime/host |
| **Data flow** | How does data move from source → transform → sink? Where does it change shape? | `flowchart LR` source-to-sink |
| **Temporal / sequence** | In what order do things happen for a concrete scenario? Where's the timing/race/ordering risk? | `sequenceDiagram` |
| **Business / value** | What is the pipeline of value? Where are we vs. where we're going (milestones)? | `flowchart LR` of stages/epics |
| **State / lifecycle** | What states does the core entity move through, and what triggers transitions? | `stateDiagram-v2` |
| **Deployment / runtime** | Where does each piece actually run (host, container, prefix, cloud)? | `flowchart` with host subgraphs |
| **Domain / entity** | What are the core entities and how do they relate? | `erDiagram` or `classDiagram` |
| **Decision / control** | What are the branch points in the control logic (guards, gates, branch conditions)? | `flowchart` with diamonds |

**The pool is extensible and project-agnostic.** This command is not tied to any one domain — it works
for a web app, a data pipeline, a CLI tool, an embedded system, a payments service. Pick the flows that fit
*this* project, and invent a new one if the project needs it (e.g. a "money flow" for fintech, a
"permission flow" for auth-heavy systems, a "request flow" for web backends, an "event flow" for
message-driven systems). Don't render a flow that has nothing interesting to say; don't omit one the project clearly
needs. **Default starter set for most projects: Technical + Data + Business**, add Temporal whenever
ordering/timing matters, add others on demand.

**Match the flow set to the project shape:**

| Project type | Flows that usually earn their place |
|--------------|-------------------------------------|
| Web app / API backend | Technical, Request/sequence, Data, Domain/entity, Decision (auth/routing) |
| Data / ETL pipeline | Data (primary), Technical, Temporal (batch/stream order), State (job lifecycle) |
| CLI / library | Technical, Data, Decision (command dispatch) — usually no Deployment |
| Event-driven / queue | Technical, Temporal (sequence), State, Data |
| Embedded / realtime | Technical, Temporal, State, Decision (control logic) |
| Fintech / payments | Data, Technical, Temporal, Business/value, Decision (gates) |

This table is a starting heuristic, not a rule — read the actual system and choose.

---

## Process

### Step 1: Load context (cheap) and choose scope

- Read `.agents/memory/index.md`; load `architecture.md` + relevant `domain/*` files per its table.
  These are the source of truth for the directory map and module roles — don't re-walk the tree if a
  map exists.
- If `docs/architecture.md` / `docs/map/system.yaml` exist (written by `/architect`), read them as
  the **planned** shape: its nodes and decisions (`AD-n`) name the boxes worth drawing. They are a
  plan, not proof — Step 2 still verifies every box against code, and a node the code does not
  match is reported as drift, never drawn as if it existed.
- If `$ARGUMENTS` names a scope ("MVP", a subsystem, a feature, a spec/backlog), honor it — render only
  that slice. If empty, do the whole system but warn if it's large and offer to scope down.
- Check recent commits (`git log --oneline -10`) and any spec/backlog the scope refers to.

### Step 2: Verify the real shape BEFORE drawing (non-negotiable)

A diagram that lies is worse than no diagram. For every box/edge you intend to draw, confirm it against
reality:

- **Interfaces** — read the actual signatures / entry points (LSP `documentSymbol`, or `rg` the
  definitions). Note the *full contract* (inputs → outputs, invariants, error modes), not just types.
- **Seams** — confirm how modules actually communicate: direct call, file, network, queue, IPC, DLL.
  The seam type drives the technical diagram; getting it wrong misleads the reader most.
- **Data shape changes** — where the data actually changes form (parse, resample, aggregate, serialize).
- **What exists vs. what's planned** — distinguish shipped code from backlog/plans. This drives the
  status legend (below). Never render a planned module as if it exists without marking it.

If you cannot verify something, either leave it out or mark it explicitly as `?? unverified` in the
diagram — don't guess silently.

### Step 3: Pick the flows and confirm with the user

Propose the 3–5 flows you'll render and the scope, in the user's communication language (CLAUDE.md →
Language Rules). Use `AskUserQuestion` when the choice is genuinely load-bearing (scope size, which
flows, MVP-only vs whole-system) — otherwise state your pick and proceed. Keep it short; the user wants
diagrams, not an interview.

### Step 4: Establish the status legend

Every node gets a status so the reader sees *what's real*. Standard three-tier (adapt labels to the
project):

- **Exists** (green) — shipped code, verified in Step 2.
- **To build** (amber) — in the current scope/milestone but not yet written.
- **Later / out of scope** (slate) — future direction, shown for context.

Apply via Mermaid `classDef` + `class` so colors are consistent across all diagrams. If the project
has no "planned" work (pure as-built doc), collapse to a single tier and say so.

### Step 5: Render each flow as a Mermaid diagram

For each chosen flow:

- One diagram, one question. Put the question in the section intro (1–2 sentences).
- Label edges with the *mechanism* where it matters (`"cron 1 min"`, `"HTTP POST"`, `"file write"`).
- Solid line = primary data/control flow; dashed = secondary/observation/conditional. State this in an
  inline legend under the diagram.
- Keep node labels short; push detail into the surrounding prose or the module table.
- **Mermaid syntax safety** (these break rendering — avoid):
  - No unescaped `()`, `[]`, `{}`, `<>` inside node text — use `&lt;` `&gt;`, or rephrase. `<br/>` is fine.
  - Quote labels containing punctuation: `N["text, with comma"]`.
  - Every `subgraph` needs a matching `end`. Balance them.
  - Don't reuse a node id with different text.

### Step 6: Add a module/interface table

A table the diagrams point into: per module — **interface** (input → output, full contract), **role**,
**status/task ref**. This is where the detail the diagrams omit goes. Use GLOSSARY terms if the project
uses them (module / interface / seam — see `.claude/skills/architecture-review/GLOSSARY.md`); "interface"
means the full contract, not just the signature.

### Step 7: Write the self-contained HTML

Render to a single HTML file using the visual system below (Inter + Tailwind CDN + Mermaid ESM),
adapted from `.claude/skills/architecture-review/report-template.html`. Structure:

1. **Header strip** — project name, date, scope.
2. **Intro card** — what the doc shows (one paragraph) + the status legend.
3. **One section per flow** — title, the question it answers, the Mermaid diagram, an inline legend.
4. **Module/interface table.**
5. **Top takeaway** (dark card) — the 2–4 things this picture *confirms* about the system
   (one short paragraph per flow dimension: "Data flow confirms…", "Technical flow confirms…").

**Save to:** `.agents/reference/architecture-<scope-slug>-YYYY-MM-DD.html`
(NEVER `/tmp`, NEVER the source tree). Stamp the date from the environment's current date.

**Offline option:** if the user says the CDN is blocked (corporate firewall / air-gapped), inline
Mermaid + minimal CSS instead of CDN `<script src>` so the file renders with no network. Ask only if
relevant; default to CDN (smaller file, always current).

### Step 8: Validate, then open

- Sanity-check the rendered file: count `class="mermaid"` blocks == `</pre>` closing them; `subgraph`
  count == standalone `end` count; file begins `<!doctype html>` and ends `</html>`.
- Open it: `open <path>` (macOS) or `xdg-open <path>` (Linux) so the user sees it immediately;
  elsewhere print the path.
- Tell the user the path, which flows you rendered, and that it's not yet committed. If a CDN diagram
  might not render in their environment, offer the offline variant.

### Step 9: Memory checkpoint

If verifying the architecture surfaced a real, non-obvious decision (a seam choice, a build-vs-buy
boundary, a deliberate constraint) that isn't already recorded — record it in
`.agents/memory/decisions.md` per `.agents/memory/reflection-protocol.md` (its save-or-not bar and
entry format). Skip silently if nothing qualifies. Do NOT record
"made a diagram" — only genuine architectural facts a fresh agent would otherwise miss.

---

## HTML visual system (reference)

Reuse the look from `.claude/skills/architecture-review/report-template.html`:

- **Fonts/CSS:** Inter via Google Fonts, Tailwind CDN, a `:root` palette (warm off-white `--bg: #fafaf9`,
  `--ink` greys, semantic `--green/--amber/--slate` + their `-soft` backgrounds).
- **Mermaid:** ESM import, `theme: 'base'`, Inter font, `fontSize: 13px`. Diagrams in
  `<pre class="mermaid">…</pre>` inside a bordered, rounded, padded card.
- **Cards:** white, `border-radius: 20px`, soft border, generous padding. Section labels in small caps
  with letter-spacing. Status badges as rounded pills (`badge-strong/worth/speculative` → relabel to
  your status tiers).
- **Top takeaway:** dark card (`--dark: #1a1d20`), white text — the one block that states conclusions.
- **Tone:** editorial-plain, no hedging, no emoji-spam. Descriptive prose in the developer
  communication language (CLAUDE.md → Language Rules — the document is for the human reader);
  technical terms and code identifiers stay English.

---

## Key Principles

- **One flow, one question** — never cram dimensions into a single diagram.
- **Verify before you draw** — an unverified diagram is misinformation; Step 2 is not optional.
- **Status legend always** — the reader must see what's real vs. planned at a glance.
- **Extensible flow pool** — pick what fits, invent what's missing, skip what's empty.
- **Project-agnostic** — the flow vocabulary suits any domain (web, ETL, CLI, embedded, payments); read
  the actual system and choose flows by its shape, not by a fixed template. Output paths assume the
  project's `.agents/` framework.
- **Self-contained output** — one HTML, opens in any browser, no build step.
- **Not a refactor audit** — if the user wants shallow-module/deepening analysis, that's
  `/architecture-review`, not this.
