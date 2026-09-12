# Reference: QA evidence families — project overlay

**Project half.** The framework half — §1 (the families), §3 (classification signals), §4 (worked examples) and §6 (the output contract) — ships with the harness at `<plugin_root>/references/qa-evidence-families.md`. This file carries only what belongs to *this* repository: §1a project extensions, §2 the verifier roster, §5 what is not observable here. The harness never rewrites it; it is seeded once, absent-only, and edited by hand thereafter.

**Section numbering is a public contract** and is shared with the framework half. Do not renumber; append new sections at the end.

**Roster completeness is enforced at runtime.** Every family in framework §1 (and every extension in §1a below) must have a row in §2. A family with no row routes to `NEEDS-HUMAN` naming the missing row — the router will not guess a verifier. Nothing syncs this file, so the rule holds only because `qa-verify` checks it on every run.

---

## 1a. Project extensions  `[project]`

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
| `cross-device / viewport` | `qa-runtime-device` | S | browser automation (device-mode server, `qa-env.json → device_mcp_server`) |

**Lanes** — forced by hard constraints, not by taste:

| Lane | Meaning | Why it exists |
|---|---|---|
| `P` | Parallel sub-agent, browser-free, non-mutating | Nothing it touches is a singleton, so any number may run at once |
| `S` | Sequential, owns the single browser / running app / working tree | A browser session and a working tree are singletons; two concurrent drivers corrupt each other's evidence |
| `I` | Inline in the parent session | Some MCP servers (design tools, trackers) exist only in the parent session and are unreachable from a spawned sub-agent |

**Build status is derived, never declared here.** There is deliberately **no build-status column** in the table above. `qa-verify` derives it in Phase 0 from the session's own agent listing — the plugin-registered `harness:qa-contract` / `harness:qa-runtime-ui` plus any project agent opted in — and treats any family whose canonical verifier is absent from that listing as guarded. A hand-maintained column can lie at exactly the moment the guard exists to fire — the router spawns an agent whose file does not exist and the run errors out. The roster names the *intended* verifier; whether it *exists* is a fact read off the filesystem.

**Required tooling is a class, not a product.** The column names the *kind* of capability a family needs — "browser automation", "design-tool MCP" — never a specific server, so a project that swaps one browser MCP for another does not have to edit this table. It is checked at dispatch time exactly as build status is, and against the same principle: **a present agent file with an absent tool is the worst state in the system**, because the agent still produces a confident row that reads as observed evidence. When the class is unreachable this session, the family resolves to `NEEDS-HUMAN` (`design parity`: `not-verified`) with the missing class named — never to a pass, and never by spawning the agent anyway.

`qa-contract` and `qa-runtime-ui` ship with the harness and are registered on Claude Code (read inline from the packaged procedures on Codex). The other rows are declared and guarded — their ACs route to `NEEDS-HUMAN` with the missing verifier named.

**Non-browser apps (mobile / desktop / TUI) — tiers of running-app evidence.** When Lane S observes an app through an app-level MCP instead of a browser (archetype: the `qa-runtime-app` agent template the harness ships), the verifier must state which tier it ran in, per row:

| Tier | Needs | What it can settle |
|---|---|---|
| **1 — inspection** | the app running + an inspector connection | rendered element tree, runtime errors, device screenshots — *state*, never *change* |
| **2 — interaction** | Tier 1 + a driver extension (`qa-env.json → local_serve_command_tier1` starts the app *without* it; the default `local_serve_command` starts it *with* it, or vice-versa — the project decides) | tap · scroll · text entry · wait-for · semantics finders · before/after deltas |

A criterion that can only be settled by *doing something* to the app is `NEEDS-HUMAN` while the driver is absent — never a `PASS` inferred from the static tree. The verifier detects its own tier (a driver health call) and stamps it in every row's `notes`; a matrix row without a tier is not attributable. `MOUNT_TARGETS` for such apps is a navigation recipe, not a URL. **A Tier-2 run is worth more than its verdict**: the recorded call sequence is promotable into a regression test — see the harness reference `qa-to-regression-test.md`.

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
| iOS-Safari-only behaviour — `100vh` vs `dvh`/`svh` under collapsing browser chrome, `env(safe-area-inset-*)`, momentum scrolling, input-focus auto-zoom, `position: fixed` with the soft keyboard open | An automation engine's WebKit is not iOS Safari and cannot be made into it; the device lane emulates a viewport and a pointer, not the OS | A manual pass on a physical iOS device |
| Cross-engine (WebKit / Firefox) rendering deltas — "renders identically in Safari/Firefox" | Both QA browser lanes run one engine by design | An engine-matrix suite in CI |

**Absence must be proven.** Before any *"X does not exist"* claim — a missing export, an absent config key, an unimplemented handler — **enumerate the search surface you actually checked and cite it**: the globs, the commands, the paths. A bare "not found" is not presentable evidence. An absence claim resting on a **single** method is downgraded by the router's self-audit (`qa-verify` Phase 2.5), and the downgrade is logged in the row's `notes`. Two traps in particular:

- `rg` honours `.gitignore` — a gitignored file (`.env`, build output) reports a **false absence**. Use `rg --no-ignore` or `ls`/`test -e` for those.
- A symbol may be re-exported, aliased, or generated. Search the barrel/entry point and the generator output, not only the file you expected it in.
