# Reference: QA evidence families

The contract shared by `/qa-verify` (the router) and every verifier it spawns. A spawned sub-agent starts with fresh context and does **not** inherit the router's copy of this file — so each one reads it itself, and this file is the only thing that keeps them speaking the same protocol.

**Section numbering is a public contract.** `.claude/commands/qa-verify.md` and `.claude/agents/qa-contract.md` cite sections as `registry §N`. Do not renumber; append new sections at the end.

**Ownership.** Each `##` heading below is marked `[framework]` or `[project]`. Framework sections (§1, §3, §4, §6) are overwritten wholesale by `/maintain:sync-from-starter`; project sections (§2, §5) are preserved across syncs. See `.claude/starter-sync-playbook.md` → Category B.

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

**Role** is what the verifier is *allowed to conclude*:

- `verifier` — may decide the criterion autonomously **in this repo**, because the evidence is fully observable here.
- `collector` — gathers and presents evidence but must not emit `PASS` on its own; its rows arrive at the matrix as `NEEDS-HUMAN` unless a human judges them. Design parity ends in a human eye; `config / external` ends in a system this repo cannot reach.

### 1a. Project extensions  `[project]`

Add stack-specific families here. They participate in classification (§3), the roster (§2) and the merge rule (§6) exactly like framework families.

> Worked example — a family a web project would add:
>
> | Family | What it proves | Canonical verifier | Role |
> |---|---|---|---|
> | `SSR / hydration` | Server-rendered markup and the client hydration pass agree; no hydration mismatch, no client-only state assumed on the server | `qa-hydration` | verifier |
>
> SSR/hydration is deliberately **not** a framework family. This template also serves CLIs, libraries and backend services, and shipping it as framework would make every such project carry a row it can never fill — a permanently empty row reads as an unchecked gap rather than an inapplicable one.

*(Currently no project extensions are defined for this repo.)*

---

## 2. Verifier roster  `[project]`

Family → the verifier that owns it → the **execution lane** it must run in.

| Family | Verifier | Lane | Required tooling |
|---|---|---|---|
| `runtime / behavior` | `qa-runtime` | S | browser automation |
| `runtime-UI + a11y` | `qa-runtime-ui` | S | browser automation |
| `design parity` | `qa-design-parity` | I | design-tool MCP |
| `contract / type / boundary` | `qa-contract` | P | none — filesystem only |
| `config / external` | `qa-config` | P | none — filesystem only |

**Lanes** — forced by hard constraints, not by taste:

| Lane | Meaning | Why it exists |
|---|---|---|
| `P` | Parallel sub-agent, browser-free, non-mutating | Nothing it touches is a singleton, so any number may run at once |
| `S` | Sequential, owns the single browser / running app / working tree | A browser session and a working tree are singletons; two concurrent drivers corrupt each other's evidence |
| `I` | Inline in the parent session | Some MCP servers (design tools, trackers) exist only in the parent session and are unreachable from a spawned sub-agent |

**Build status is derived, never declared here.** There is deliberately **no build-status column** in the table above. `/qa-verify` derives it in Phase 0 from an injected `ls .claude/agents/qa-*.md` and treats any family whose canonical verifier is absent from that listing as guarded. A hand-maintained column can lie at exactly the moment the guard exists to fire — the router spawns an agent whose file does not exist and the run errors out. The roster names the *intended* verifier; whether it *exists* is a fact read off the filesystem.

**Required tooling is a class, not a product.** The column names the *kind* of capability a family needs — "browser automation", "design-tool MCP" — never a specific server, so a project that swaps one browser MCP for another does not have to edit this table. It is checked at dispatch time exactly as build status is, and against the same principle: **a present agent file with an absent tool is the worst state in the system**, because the agent still produces a confident row that reads as observed evidence. When the class is unreachable this session, the family resolves to `NEEDS-HUMAN` (`design parity`: `not-verified`) with the missing class named — never to a pass, and never by spawning the agent anyway.

At the time of writing, `qa-contract` and `qa-runtime-ui` are built. The other three rows are declared and guarded — their ACs route to `NEEDS-HUMAN` with the missing verifier named.

**Non-browser apps (mobile / desktop / TUI) — tiers of running-app evidence.** When Lane S observes an app through an app-level MCP instead of a browser (archetype: `.claude/agents/qa-runtime-app.md.example`), the verifier must state which tier it ran in, per row:

| Tier | Needs | What it can settle |
|---|---|---|
| **1 — inspection** | the app running + an inspector connection | rendered element tree, runtime errors, device screenshots — *state*, never *change* |
| **2 — interaction** | Tier 1 + a driver extension (`qa-env.json → local_serve_command_tier1` starts the app *without* it; the default `local_serve_command` starts it *with* it, or vice-versa — the project decides) | tap · scroll · text entry · wait-for · semantics finders · before/after deltas |

A criterion that can only be settled by *doing something* to the app is `NEEDS-HUMAN` while the driver is absent — never a `PASS` inferred from the static tree. The verifier detects its own tier (a driver health call) and stamps it in every row's `notes`; a matrix row without a tier is not attributable. `MOUNT_TARGETS` for such apps is a navigation recipe, not a URL. **A Tier-2 run is worth more than its verdict**: the recorded call sequence is promotable into a regression test — see `.agents/reference/qa-to-regression-test.md`.

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

## 5. Not observable in this repo  `[project]`

Criteria that **cannot** be settled here, whatever the family says. A match means the row is `NEEDS-HUMAN` with the entry's reason quoted — regardless of what any verifier would otherwise have concluded. This list exists to make a guessed `PASS` structurally impossible rather than a matter of the verifier's diligence.

| Pattern of criterion | Why it is not observable here | What would make it observable |
|---|---|---|
| *(template)* `<the shape of criterion this covers>` | `<the concrete missing capability — tooling, access, or environment>` | `<what would have to exist>` |
| Pixel-level visual regression against a previous release | No visual-regression tooling and no stored baselines in this repo | A baseline snapshot suite wired into CI |
| *(non-browser apps)* Content inside an embedded webview | The inspector sees one platform-view node with no children | A browser-automation lane pointed at the embedded page's URL |
| *(non-browser apps)* What a screen reader actually announces | A semantics/accessibility label being present and reachable is provable; VoiceOver / TalkBack output is not | A manual assistive-technology pass |
| *(non-browser apps)* Behaviour that exists only in a release build | QA runs debug/profile builds; stripped, obfuscated or flag-gated release paths never execute | A release-build QA target in `qa-env.json` |
| Behaviour gated by a remote feature flag or config the QA environment cannot toggle | The verifier observes whatever the flag currently serves; it cannot prove the other branch | A flag-override mechanism reachable from the QA build |

**Absence must be proven.** Before any *"X does not exist"* claim — a missing export, an absent config key, an unimplemented handler — **enumerate the search surface you actually checked and cite it**: the globs, the commands, the paths. A bare "not found" is not presentable evidence. An absence claim resting on a **single** method is downgraded by the router's self-audit (`/qa-verify` Phase 2.5), and the downgrade is logged in the row's `notes`. Two traps in particular:

- `rg` honours `.gitignore` — a gitignored file (`.env`, build output) reports a **false absence**. Use `rg --no-ignore` or `ls`/`test -e` for those.
- A symbol may be re-exported, aliased, or generated. Search the barrel/entry point and the generator output, not only the file you expected it in.

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
