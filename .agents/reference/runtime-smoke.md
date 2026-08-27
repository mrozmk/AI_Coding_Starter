# Reference: runtime smoke check (conditional fourth validation step)

The procedure behind the optional **Runtime smoke** paragraph in `CLAUDE.md → Validation`. It is
**not** a slash command — whoever runs the gate (`/gates:verify-implementation`,
`/check-implementation`, `/orchestrate`) reads and performs it when its conditions hold.

**Why it exists.** The shell gates (typecheck, lint, test) are static — none renders a frame.
None can see a layout overflow, a component whose render threw on the screen just edited, an
uncaught runtime error, or a broken import that only surfaces at load. This step does the one
thing they cannot: look at the running app after the change.

**It reports; it never fixes.** Findings go back through `/code-review --fix` like every other
gate finding.

---

## When it applies

Both must hold, or the step is `SKIPPED`:

1. The change touches the project's UI paths (`{ui-paths}` in the Validation paragraph — e.g.
   `src/components`, `app/lib/pages`). A change confined to pure logic has nothing to show here.
2. An app is running and reachable (browser: Playwright MCP + `qa-env.json → local_url`;
   non-browser: an inspector connection — `qa-runtime-app.md.example`).

**A missing device or server is `SKIPPED`, never `FAIL`.** That is an environment gap, not a
defect in the change. A gate that fails there makes Validation unpassable on a machine that
cannot run the app.

**Never report a pass when the check did not run.** `SKIPPED` with the reason named is the
honest verdict — a distinct state, not a lesser `PASS`.

## Procedure

1. **Baseline.** Read the errors already present (browser: console errors + failed requests;
   app: runtime-error list) and clear or note them. **Keep the list** — context for the report,
   never a finding.
2. **Be on the screen being judged.** Reloading a screen nobody is looking at proves nothing.
   App elsewhere → navigate per the recipe, or `SKIPPED — app is on <screen>, change targets
   <screen>`.
3. **Reload** (browser: page reload; app: hot reload). A reload that cannot apply the change —
   `const` values, DI graph, entry point, build-time config — proves nothing: ask for a full
   restart or report `SKIPPED` quoting why. Reload rejected → `SKIPPED` with the message.
4. **Read the delta.** Everything raised after the baseline is attributable to the change.
   Confirm the changed subtree is **present** — a component whose render threw is replaced by
   an error boundary or blank, so an absence is a finding, not a quiet pass.
5. **Classify**, quoting framework messages **verbatim**:

| Finding | Verdict |
|---|---|
| New uncaught error / render exception on the edited screen | `FAIL` — Critical |
| Layout overflow / constraint warning introduced by the change | `FAIL` — High |
| Console warning the baseline did not have | `WARN` |
| Pre-existing error unchanged | not a finding; listed as context |

## Report

```
Runtime smoke: [PASS / FAIL / SKIPPED — <reason>]
Screen: <route or screen>   Baseline errors: <N>   New after reload: <M>
<verbatim framework messages, one per line>
```
