# Recipe: the regression visual lane

How a project adopts and runs the visual lane of the regression kit. Contract:
`.agents/reference/regression.md` §13; config keys: `.claude/regression.json.example` (`_visual_doc`).

## 1. Adopt

1. The baseline must be established (`runner` + `environments`). Then `/setup:regression --visual`:
   it asks the routes (id, path, title, devices), the volatile regions to mask and the asset hosts
   the pages load, copies `.claude/templates/regression/visual.config.ts.template` and
   `visual.spec.ts.template` into `<e2e>/visual/` (never over an existing file), fills their
   placeholders, writes the `visual` fragment and runs
   `node .claude/lib/regression/setup.mjs visual --fragment <file>` and `setup.mjs check`.
2. Keep the visual spec outside `runner.spec_dir` (the functional runner would collect it) and the
   baselines outside the spec's directory, every report directory and `.agents/regression/runs`.
3. The visual spec's `test` comes from the guarded fixtures — every screenshot is rendered in a
   guarded context. Tests are declared in the copied spec, never in a helper: the fixture refuses a
   test whose declaring file is not the selected spec.

## 2. Targets

- **Routes:** `visual.routes[]` — `id` (`[a-z0-9-]`, no `.` or `_`), `path` (starts with `/`), `title`,
  `devices` (`desktop`, `mobile`; a device without a `runner.devices` project is not run and keeps
  its baselines), `mask`, `full_page`, `wait_for` (a selector waited for before the shot). Routes are
  rendered anonymous.
- **Storybook (test environments only):** `visual.storybook.<env>` — `url` (its host must be on
  `environments.<env>.guard.hosts`; with `host: "qa-env"` list it explicitly), `ready` (required),
  `error` (e.g. `.sb-show-errordisplay`), `exclude_tags` (e.g. `visual-skip`), `build_sha_url`.
  - **The `ready` contract:** a selector that appears only after the story's render **and** its
    `play` function finished — Storybook documents no completion signal. A global decorator or the
    last `play` step sets it, e.g. `document.body.dataset.visualReady = 'true'` →
    `body[data-visual-ready]`. A story that never shows it is `story not ready`; the `error`
    selector, also when it appears after `ready`, is `story error display`; an empty story root is
    `story rendered nothing`.
  - **`build_sha_url`** is the Storybook build identity. Without it stories are rendered and
    compared but never offered for acceptance (`storybook build not established`).

## 3. Masks and hosts

- Mask volatile regions only — prices, promotions, stock levels, rotating banners, timestamps:
  `visual.mask` (every target) and a route's own `mask`, each `{selector, reason}`. `html`, `body`,
  `:root` and `*` are refused; a shot whose masked area (the union of the masked boxes) exceeds
  `max_mask_ratio` (default 0.25) is an error — masks never hide the page under comparison.
- Every font, image and script CDN host a page loads must be in `environments.<env>.guard.hosts`.
  The guard aborts any other request and the target fails (§11) — the fix is the allowlist, never
  a mask.

## 4. Renderer

The default runs the host's browser. Pixels depend on the browser build, the OS, the fonts and
whether a container renders them, so each image stores the fingerprint it was accepted under and a
different renderer makes it `not-comparable` (never `differs`). The report's `visual portability:`
line says per project what differs. To pin the renderer across machines, wrap `visual.command` in a
container (`docker run … --add-host <host>:<ip> …` when the environment needs a hosts-file entry);
the fingerprint then reads `container`. Moving to a new renderer means a fresh `visual update` and
acceptance on it — baselines never migrate silently.

## 5. First baselines and changes

1. `/regression-tests visual update [--env <name>]` — a capture pass and a stability pass (three
   read-only comparisons of the same build). Only stable, attested candidates of an unchanged,
   known build are offered; the command prints one `visual offer:` line per image.
2. Open the candidate PNGs the lines name. Answer `Accept baselines` (or `Cancel`) — only then does
   `/regression-tests` run `run.mjs visual accept --run <id> --token <token>`.
3. Commit `<baselines>/<env>/` with `/commit`. A baseline changed by hand, or a PNG that is not in
   `index.json`, is an integrity reason at the next run.
4. `visual compare` (or `run full`) compares the environment against its own baselines. Comparison
   across environments is not offered.

**Git LFS (advice):** `<baselines>/.gitattributes` with `*.png filter=lfs diff=lfs merge=lfs -text`
keeps the repository small. A checkout without `git lfs pull` holds pointer files — the lane
reports `Git LFS pointer — run git lfs pull`.

## 6. What `warn` and `block` mean

- `warn` (default): differences and an incomplete visual pass are `warning:` lines; the run's
  verdict comes from the guard and the functional cases.
- `block`: a difference makes the run `RED`, an incomplete visual pass `INCOMPLETE`.
- Under both: a guard stop or a production attestation gap is `BLOCKED/ENV`, a guard-aborted request
  `RED`, an integrity reason `INCOMPLETE`.
- **Tolerance** (`threshold`, `max_diff_pixels`) may be narrowed; no command widens it beyond the
  accepted `index.json`. Widening is a human edit of `index.json` in a reviewed commit.

## 7. Stated limits

- A wrapper script around `visual.command` that adds `--output` or another forbidden flag is not
  seen by the config check; the per-boundary digest of the baselines tree reports a loss after the
  fact (`baselines changed during the run`) and `git restore` recovers committed baselines.
- A functional `outputDir` set through an imported module cannot be resolved statically — re-copy
  `playwright.config.ts.template` (it uses `opts.outputDir` from `runnerOptions(…)`, under the run directory).

## 8. Troubleshooting by reason line

| Reason | Fix |
|---|---|
| `visual not configured` | Run the Visual stage of `/setup:regression`. |
| `visual.tolerance widened over the accepted baselines` | Restore the tolerance, or have a human edit `index.json` in a reviewed commit. |
| `visual.baselines overlaps …` | Move the baselines out of report, output and run directories. |
| `cannot resolve the functional outputDir` | Use a string literal, `runnerOptions(…).outputDir` or a variable holding `runnerOptions(…)` (`opts.outputDir`, as the template does). |
| `baselines environment is not a plain directory` | Replace the symlink (or file) at `<baselines>/<env>` with a real directory — baselines are never shared between environments. |
| `file not part of the baselines` | Remove the file (a `.DS_Store`, a README) from `<baselines>/<env>/` — only `index.json` and accepted PNGs live there. |
| `baseline altered outside visual accept` / `baseline not accepted` | `git restore` the baselines, or accept a new set through `visual update`. |
| `interrupted accept: …` | Do what the line says (remove the staging dir, or rename the previous dir back), then rerun `visual update`. |
| `baselines changed during the run (<pass>)` | Something wrote under the baselines during a runner — find the writer (outputDir, wrapper flag). |
| `visual not comparable … renderer differs in …` | Run on the renderer the baselines name, or accept new baselines on this one. |
| `renderer differs between workers of <project>` | The workers of one project disagree — pin the browser/fonts (container). |
| `visual error: … navigation <status>` | The page did not answer 2xx — check the route and the environment. |
| `visual error: … mask covers <p>%` | Narrow the mask selectors or raise `max_mask_ratio` deliberately. |
| `visual error: … render never stable` | Animations or live data — mask the region or wait for it (`wait_for`). |
| `guard blocked a request in …` | Add the asset host to `guard.hosts` (if legitimate) — never mask it. |
| `story not ready` / `story error display` / `story rendered nothing` | Fix the `ready` signal, the story, or exclude it (`visual-skip`). |
| `visual offer: none — …` | The line names why (build, guard, integrity, nothing stable); fix it and rerun `visual update`. |
