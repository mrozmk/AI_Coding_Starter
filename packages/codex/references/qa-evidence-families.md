# Reference: QA evidence families — framework half

The contract shared by the `qa-verify` router and every verifier it spawns. A spawned sub-agent starts with fresh context and does **not** inherit the router's copy of this file — so each one reads it itself, and this file is the only thing that keeps them speaking the same protocol. On Codex, where no agent exists, the router reads it before running a lane inline.

**This is the framework half, owned by the harness and replaced wholesale on upgrade.** The other half is the project overlay at `.agents/reference/qa-evidence-families.md`, which carries §1a (project extensions), §2 (the verifier roster) and §5 (what is not observable in this project). Both halves are read together; the overlay is authoritative for its own sections and the harness never rewrites it. When the overlay is absent, the router runs on this taxonomy alone and says so in its run header — an absent roster is never read as "every family is covered", and an absent §5 is never read as "nothing is excluded".

**Section numbering is a public contract.** The QA skills and the verifier procedures cite sections as `registry §N`. Do not renumber; append new sections at the end.

---

## 1. The evidence families  `[framework]`

An *evidence family* is the **kind of evidence** an acceptance criterion needs before anyone can say whether it holds. Families are not topics and not components — two ACs about the same button belong to different families when one is proven by reading types and the other only by watching the rendered page.

| Family | What it proves | Canonical verifier | Role |
|---|---|---|---|
| `runtime / behavior` | The system, when exercised, produces the required observable outcome — a returned value, a written record, a status code, a side effect | `qa-runtime` | verifier |
| `runtime-UI + a11y` | The rendered interface presents and behaves as required, including the accessibility tree, focus order and announced state | `qa-runtime-ui` | verifier |
| `design parity` | The implemented UI matches its reference design — spacing, type scale, tokens, states | `qa-design-parity` | collector |
| `contract / type / boundary` | Statically provable structure — exported surface, type contracts, layer/dependency direction, payload boundaries | `qa-contract` | verifier |
| `config / external` | Required configuration, environment wiring, or an integration with a system outside this repo is present and correctly addressed | `qa-config` | collector |
| `cross-device / viewport` | The rendered surface behaves as required at every width tier and under the input modality a real device carries — breakpoint layout, tap-target size, a `hover:`/`pointer:` branch, a `matchMedia` switch | `qa-runtime-device` | verifier |

**Role** is what the verifier is *allowed to conclude*:

- `verifier` — may decide the criterion autonomously **in this repo**, because the evidence is fully observable here.
- `collector` — gathers and presents evidence but must not emit `PASS` on its own; its rows arrive at the matrix as `NEEDS-HUMAN` unless a human judges them. Design parity ends in a human eye; `config / external` ends in a system this repo cannot reach.

`cross-device / viewport` is a sibling of `runtime-UI + a11y`, not a replacement: the latter judges the rendered surface, the former judges it **at every width and under a coarse pointer**.

### Tier coverage is split by input modality

A device profile carries `hover: none` at every width; a desktop context carries `hover: hover` at every width. So coverage is split by **modality**, one lane each: `qa-runtime-device` sweeps the touch-plausible tiers (`qa-env.json → touch_sweep_widths`), `qa-runtime-ui` sweeps the pointer tiers (`qa-env.json → pointer_sweep_widths`). One width per tier, taken at the tier's **lower edge** — where its `min-width` query first fires and the layout is tightest, which is where overflow and truncation actually break. A second width inside the same tier fires an identical set of queries and proves nothing new. Never produce a fictional combination — a touch device at a desktop width, or a mouse at a phone width: a `hover:`- or `pointer:`-gated branch judged on the wrong lane is a **guaranteed false FAIL**, because the branch under test never activates there.

---

## 3. Semantic classification signals  `[framework]`

**Classification is semantic reasoning, never keyword matching.** Do not implement, and do not imitate, `if AC contains "aria" → a11y`. An AC reading *"the API must not return the provider's raw `aria_label` field"* is a `contract / type / boundary` criterion despite the word. Ask what evidence would settle the criterion, then pick the family that produces it.

**One AC may map to several families**, and each mapping gets **its own row** with the same `ac_id`. Rows are merged only at the very end, per §6.

| Family | Reason toward it when the criterion… |
|---|---|
| `runtime / behavior` | asserts an outcome that only appears when something is executed — a value returned, a record written, an email queued, a status code, an idempotent retry, a rate limit. The proof is an observation of a run, not a reading of the source |
| `runtime-UI + a11y` | asserts what a person perceives or can operate — visible state, focus movement, keyboard reachability, screen-reader announcement, an error shown near its field. The proof requires a rendered tree |
| `design parity` | asserts likeness to a reference — spacing, scale, token, state styling, "matches the design". The proof is a comparison against an artifact outside the code |
| `contract / type / boundary` | asserts a structural fact provable without running anything — what a module exports, which types cross a boundary, which layer may import which, where an error type is constructed, whether an external payload shape leaks past its adapter |
| `config / external` | asserts something about an environment, a credential, a feature flag, a deployment target, or a third-party system's behaviour. The proof is partly or wholly outside this repo |
| `cross-device / viewport` | asserts behaviour that depends on **viewport width or input modality** — layout at a given breakpoint, touch-target size, a `hover:`/`pointer:` branch, a `matchMedia`-driven switch. The boundary against `runtime-UI + a11y`: that family answers *does it render correctly*, this family answers *at every width and on touch* |

**An AC that maps to no family is a legitimate outcome.** *"The code should be maintainable"* carries no evidence family at all. It gets one row with `family: "(unclassifiable)"` and `verdict: "NEEDS-HUMAN"`, and a note saying it carries no evidence family. Do **not** stretch a classification to fit — a forced family produces a confident answer to a question nobody asked.

---

## 4. Worked examples  `[framework]`

**Example A — single family, resolves cleanly.**

> AC-3: *"`createInvoice` must never accept a raw Stripe `PaymentIntent`; it takes the mapped domain `Payment` type."*

One family: `contract / type / boundary` — the claim is settled by reading the signature and the call sites, with nothing executed. One row, dispatched to `qa-contract` in lane P:

```json
[{ "ac_id": "AC-3", "family": "contract / type / boundary", "agent": "qa-contract",
   "verdict": "PASS",
   "methods": ["signature read at src/billing/invoice.ts:41", "call-site sweep: rg 'createInvoice\\(' → 4 hits, all pass Payment"],
   "evidence": ["createInvoice(p: Payment): Invoice — no Stripe type in the signature", "no PaymentIntent import in src/billing/"],
   "artifacts": [], "notes": "" }]
```

Merged verdict for AC-3: `PASS`.

**Example B — multi-family, one verifier unbuilt.**

> AC-7: *"The failed-payment banner shows the provider's decline reason and is announced to screen readers."*

Two families, two rows, same `ac_id`:

- `contract / type / boundary` — is the decline reason actually carried through to the component's props, or dropped at the adapter? Provable statically → `qa-contract`, lane P → returns `PASS`.
- `runtime-UI + a11y` — is it announced? Provable only against a rendered accessibility tree → `qa-runtime-ui`, which is **not present** in the Phase-0 listing → the row is guarded before anything is spawned:

```json
[{ "ac_id": "AC-7", "family": "runtime-UI + a11y", "agent": "(none)",
   "verdict": "NEEDS-HUMAN", "methods": [], "evidence": [], "artifacts": [],
   "notes": "canonical verifier qa-runtime-ui is not built in this repo — no row may be decided from static evidence alone" }]
```

Merged verdict for AC-7: **`NEEDS-HUMAN`** — the `PASS` does not carry the criterion, because it answers only half of it. **Both source rows survive into the matrix**; the merge produces an additional verdict, it never replaces the evidence that produced it.

---

## 6. Canonical output contract  `[framework]`

Every verifier ends its turn with **only** this JSON array — no prose before or after it. One object per `ac_id` it was handed, echoing the ids exactly as given.

```json
[
  {
    "ac_id": "AC-1",
    "family": "contract / type / boundary",
    "agent": "qa-contract",
    "verdict": "PASS",
    "methods": ["<one entry per independent method used, each naming what it inspected>"],
    "evidence": ["<concrete observed values — a signature, a line, a returned status — not a conclusion>"],
    "artifacts": ["<path to a file or capture backing the row; [] if none>"],
    "notes": "<caveats, downgrade trail, or why the verdict is what it is>"
  }
]
```

**Field rules:**

| Field | Rule |
|---|---|
| `ac_id` | Exactly as handed in. Never renumbered, never invented. The join key for the whole run |
| `family` | One of §1 / §1a, or `"(unclassifiable)"` |
| `agent` | The verifier's own name, or `"(none)"` for a row decided by the router (guarded or unclassifiable) |
| `verdict` | Exactly one of `PASS` · `FAIL` · `NEEDS-HUMAN`. No other value, no qualifiers |
| `methods` | One entry per **independent** method. Two greps over the same file are one method. This array is what the router's self-audit counts |
| `evidence` | Observed values, quoted. *"The signature is `createInvoice(p: Payment)`"* is evidence; *"the type is correct"* is not |
| `artifacts` | Paths only. Never inline a screenshot or a dump |
| `severity` | **Present only when `verdict` is `FAIL`; absent otherwise** — not `null`, not `""`. One of `blocker` · `major` · `minor`. A schema that *usually* carries a field produces rows that cannot be counted, and the blocker tally is a count |
| `notes` | Empty string when there is nothing to say. Always present |

**Multi-family merge rule.** When one `ac_id` has several rows, the merged verdict is the **worst** across them, in this order:

`FAIL` › `NEEDS-HUMAN` › `PASS`

- Any `FAIL` → merged `FAIL`, carrying the highest severity among the failing rows.
- Else any `NEEDS-HUMAN` → merged `NEEDS-HUMAN`. A `PASS` from another family never rescues it: that `PASS` answered a different question.
- Only all-`PASS` → merged `PASS`.

**Both source rows always survive into the matrix.** The merge adds a verdict; it never replaces or hides the rows that produced it.
