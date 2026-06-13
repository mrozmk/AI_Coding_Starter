# Interface Design — Design It Twice

When the user picks a deepening candidate to explore (Phase 3 of the review), design its interface deliberately instead of accepting the first shape that comes to mind. Based on **"Design It Twice"** (Ousterhout): your first idea is almost never the best, so produce 2–3 radically different interfaces and choose between them on the merits.

Uses the vocabulary in [GLOSSARY.md](GLOSSARY.md): **module**, **interface**, **seam**, **adapter**, **leverage**, **depth**, **locality**. Dependency categories are in [DEEPENING.md](DEEPENING.md).

---

## Process

### 1. Frame the problem space

Before generating any variant, write a short user-facing framing of the chosen candidate:

- The **constraints** any new interface must satisfy (invariants, ordering, error modes, performance).
- The **dependencies** it relies on, and which [DEEPENING.md](DEEPENING.md) category each falls into.
- A **rough illustrative sketch** to ground the constraints — not a proposal, just a way to make the constraints concrete.

Show this to the user, then proceed straight to Step 2. The user reads and thinks while the variants are generated in parallel.

### 2. Produce 2–3 radically different variants

Generate the variants in parallel (spawn sub-agents via the Agent tool with separate calls in a single message — see how `/design` fans out three variants). Each variant must be a **genuinely different** interface for the same deepened module, driven by a different design constraint:

- **Variant A — Minimize the interface.** Aim for **1–3 entry points max**. Maximize leverage per entry point. The default reaching tool when in doubt.
- **Variant B — Maximize flexibility.** Support many use cases and future extension; accept a larger surface in exchange.
- **Variant C — Optimize for the common case.** Make the most frequent caller's path trivial (sane defaults, zero required config); rarer needs cost more.
- **Variant D (if cross-seam deps exist)** — Design around **ports & adapters** for the dependency category from [DEEPENING.md](DEEPENING.md).

Brief each generator with the concrete technical context (file paths, coupling details, dependency category, what sits behind the seam) **and** the [GLOSSARY.md](GLOSSARY.md) terms so every variant names things consistently. Each variant outputs:

1. The **interface** — types, methods, params, plus invariants, ordering, error modes.
2. A **usage example** showing how callers use it.
3. **What the implementation hides** behind the seam.
4. **Dependency strategy and adapters** (per [DEEPENING.md](DEEPENING.md)).
5. **Trade-offs** — where leverage is high, where it's thin.

### 3. The four interface-design rules

Score every variant against these (they are the rubric, not decoration):

1. **Minimize the interface** — fewest entry points that still cover the need (1–3 is the target for a deep module).
2. **Maximize leverage per entry point** — each call should buy the caller a lot of behaviour.
3. **Maximize flexibility** — without inflating the interface; flexibility that leaks into the signature is a cost, not a feature.
4. **Optimize for the common case** — the default path is trivial; complexity is opt-in.

Plus: **ports & adapters for cross-seam dependencies**, and the **seam discipline** — one adapter is a hypothetical seam, two is a real one. Don't add a port a variant only uses once.

### 4. Present, compare, recommend

Present the variants **sequentially** so the user absorbs each, then **compare them in prose** along three axes:

- **Depth** — leverage at the interface.
- **Locality** — where change concentrates after the merge.
- **Seam placement** — is the seam in the right place, and is it real (≥2 adapters)?

Then give **your own opinionated recommendation** — which variant is strongest and why. If elements of two variants combine well, propose a **hybrid** explicitly. The user wants a strong read, not a menu — be decisive.
