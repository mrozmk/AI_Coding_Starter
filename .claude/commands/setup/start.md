---
description: Guided bootstrap — interview, configure day-one files, prune unused command groups, print the next commands
argument-hint: "[--rerun]"
---

# Setup: Start — the front door of a fresh clone

## Input: $ARGUMENTS

Run once from the repo root right after cloning the starter (greenfield) or after copying `.claude/`, `.agents/`, `CLAUDE.md`, `.env.example`, `.mcp.json` into an existing repo (brownfield). `/prime` is **not** required — this command runs before any project context exists. Pass `--rerun` (or just run it again) to review and change answers; see *Re-run* below.

Three phases, each idempotent: **A — Interview** (writes `.claude/project-profile.json`) → **B — Configure** (day-one files + command pruning) → **C — Route** (prints the next commands; runs nothing).

## Guardrails (absolute — no yield)

- **Never create, edit, read, or even test for `.env`** — no existence check, no `cat`, nothing. `.env` is `deny` (`CLAUDE.md → Security`), and the SessionStart preflight `check-project-deps.sh` already reports its state. This command edits the committed **`.env.example`** contract only and prints the one human command.
- **Never touch `~/.claude/`** (user scope). Same-name shadowing is reported as a warning, never fixed.
- **Never delete without the per-group `AskUserQuestion` confirmation** in Phase B step 7, and never delete a group whose reference inventory has an unclassifiable hit.
- **Never auto-run the routed commands** — Phase C prints a list.
- **`custom` workflow is not offered.** A user whose answer fits none of the three presets is told to run `/setup:create-CLAUDE_MD` for its custom flow after this command.
- Re-enabling a pruned group is refused (see *Re-run*).

Every detection probe below follows the Probe Convention (`.agents/memory/index.md`): rooted at an always-present directory or guarded with `|| echo`, so it exits `0` when nothing matches.

---

## Phase A — Interview

### A.1 Detect defaults (never ask what the repo already says)

Run these probes and keep the results for the screens:

```bash
git remote get-url origin 2>/dev/null || echo "(no remote)"
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo "(no origin HEAD)"
git branch --list 2>/dev/null || echo "(no branches)"
rg --files 2>/dev/null | wc -l          # rg skips .claude/ and .agents/ (hidden) — counts only project files
find . -maxdepth 1 -name '.mcp.json' -exec jq -r '.mcpServers | keys[]' {} \; 2>/dev/null || echo "(no .mcp.json or jq)"
command -v codex >/dev/null 2>&1 && echo "codex: installed (informational only)" || echo "codex: not on this machine (informational only)"
find "$HOME/.claude/commands" -maxdepth 2 -name '*.md' 2>/dev/null | sed "s|$HOME/.claude/commands/||" || true
find . -maxdepth 2 -name 'project-profile.json' -path './.claude/*' 2>/dev/null || true
```

Derived facts:

- **`git_host`** from the remote URL: `github.com` → `github`, `bitbucket.org` → `bitbucket`, host containing `gitlab` → `gitlab`, no remote → `none`.
- **`mode`**: project file count (`rg --files | wc -l`, harness dirs excluded by `rg`'s hidden-dir rule) ≥ 50 → `brownfield`, else `greenfield` — the same threshold `/setup:map-codebase` uses (`map-codebase.md:19`). Shown for confirmation in Q1, never silently applied.
- **Workflow hint**: `develop` present → suggest (c); `origin/HEAD` = `main`/`master` with no `develop` → suggest (b) when a remote exists, (a) when it does not.
- **User-scope shadowing**: every file under `~/.claude/commands/` whose relative path matches a file under `.claude/commands/` (e.g. `pr-create.md`, `start-task.md`) **overrides the repo version** for this machine. Print one warning line per match: `⚠️ ~/.claude/commands/<path> shadows the repo command — the repo version will not run on this machine until you remove or rename the user-scope file.` Warn only.
- **Existing profile** → jump to *Re-run* before any screen.

### A.2 Screens

Ask with `AskUserQuestion`, one call per screen, the detected value pre-selected and marked **(Recommended)**. The copy below is the **approved wording** — ship it verbatim. Screen 0 is bilingual; every later screen renders in the language chosen on Screen 0 (English column is a 1:1 translation). `app_surface` is **not asked** — it is written as `unknown`.

Shaping rule: 3 screens, ≤4 questions each — yields only when a detected value is wrong and the user asks to change it (then re-ask that one question, nothing else).

**Screen 0 — Język / Language**

0. **W jakim języku mam z Tobą rozmawiać? / Which language should I talk to you in?**
   Polski · English
   *Dotyczy tylko rozmowy ze mną. Kod, commity i komentarze zawsze po angielsku. / Only our conversation. Code, commits and comments stay in English.* → `language` (`pl` | `en`)

**Screen 1 — Gdzie jest projekt / Where the project lives**

1. **Czy to nowy projekt, czy istniejący kod?** / **Is this a new project or existing code?**
   *Wykryłem: <nowy (N plików, brak kodu aplikacji) | istniejący (N plików)>.* / *Detected: …*
   Nowy — zaczynamy od pustego repo · Istniejący — jest już kod, który ktoś napisał / New — we start from an empty repo · Existing — there is code someone already wrote
   *Od tego zależy, czy najpierw piszemy opis produktu (PRD), czy najpierw czytam Twój kod.* / *This decides whether we write the product description (PRD) first, or I read your code first.* → `mode`
2. **Gdzie jest hostowane repozytorium?** / **Where is the repository hosted?**
   *Wykryłem z `origin`: <host>.* / *Detected from `origin`: …*
   GitHub · Bitbucket · GitLab · Jeszcze nigdzie / Nowhere yet
   *Potrzebne do: linków do Pull Requestów i narzędzia do czytania komentarzy z review. "Jeszcze nigdzie" niczego nie psuje — wrócisz tu po `git remote add`.* / *Needed for: Pull Request links and the review-comment tool. "Nowhere yet" breaks nothing — come back after `git remote add`.* → `git_host`
3. **Jak kod trafia do głównej gałęzi?** / **How does code reach the main branch?**
   *Wykryłem: <branches>.* / *Detected: …*
   (a) Pushuję prosto na `main` — pracuję sam lub w małym zespole / I push straight to `main` — solo or a small team
   (b) Przez Pull Request, który ktoś zatwierdza / Through a Pull Request someone approves
   (c) Mamy `develop` + gałęzie release (GitFlow) / We have `develop` + release branches (GitFlow)
   *Od tego zależy, z której gałęzi zaczynam nową pracę i dokąd ją kieruję. Przykład: przy (b) każde zadanie dostaje gałąź `feat/nazwa` i PR do `main`.* / *This decides which branch new work starts from and where it goes. Example: with (b) every task gets a `feat/name` branch and a PR to `main`.* → `workflow` (a = `trunk` + `pr_required=false`, b = `feature-branch`, c = `gitflow`)

**Screen 2 — Narzędzia zespołu / Team tools**

4. **Czy zadania śledzicie w Jira?** / **Do you track tasks in Jira?**
   Tak · Nie / Yes · No
   *Jeśli tak, będziesz potrzebować: adresu Jira (np. `https://firma.atlassian.net`), maila logowania i tokenu API (podam link). Jeśli nie: zadania prowadzimy w pliku `.agents/backlog.md`, który zbudujemy z PRD; komendy Jira usuwam.* / *If yes you will need: the Jira URL (e.g. `https://acme.atlassian.net`), your login email and an API token (I will give the link). If no: tasks live in `.agents/backlog.md`, built from the PRD; Jira commands are removed.* → `tracker`
5. **Czy dokumentację piszecie w Confluence?** / **Do you write docs in Confluence?**
   Tak · Nie / Yes · No
   *Ten sam token co do Jira. Jeśli nie: usuwam komendę `/confluence`.* / *Same token as Jira. If no: the `/confluence` command is removed.* → `confluence`
6. **Czy zespół używa Codex do drugiej opinii?** / **Does the team use Codex for a second opinion?**
   *Na tym komputerze: <zainstalowany | brak> — tylko informacja.* / *On this machine: <installed | absent> — informational only.*
   Tak · Nie / Yes · No
   *Codex to drugie AI, które sprawdza plany i kod. Pytam o zespół, bo ta odpowiedź trafia do wspólnego pliku. Jeśli nie: usuwam `/codex-review`, reszta pomija Codex sama.* / *Codex is a second AI that checks plans and code. I ask about the team because this answer goes into a shared file. If no: `/codex-review` is removed; everything else skips Codex on its own.* → `codex`, `commands.codex`

**Screen 3 — Podsumowanie / Summary** — after A.3 derivation, before Phase B. One table: **co utworzę / will create** · **co usunę / will remove** (files per disabled group) · **co musisz zrobić ręcznie / manual steps** (`cp .env.example .env`, keys to fill, restart). Options: **Zatwierdź i wykonaj / Approve and run** · **Zmień coś / Change something** (→ re-ask the named question only). No new facts are collected here.

### A.3 Derive the profile

Expand the answers into `.claude/project-profile.json` (schema and field docs: `.claude/project-profile.json.example`).

- `workflow.*` from the preset via the table in `.claude/commands/setup/create-CLAUDE_MD.md → Identify Git Workflow` (the six-field expansion; reference it, do not copy it), `orchestrate_publish` per the same section's derivation rule (`gitflow`/PR-gated → `branch-local`, else `push`).
- **`branch_pattern` from the interview**: `tracker=jira` → `<type>/<KEY>-<slug>`, else `<type>/<slug>`. Never use the file-presence predicate in `create-CLAUDE_MD` — the Jira skill exists in every fresh clone, pruning comes later.
- **Direct-push override** (`pr_required=false`): after expansion set `pr_dest` = `commit on <trunk> or short-lived branches merged locally — no PR`, `protected` = `[]`, `merge` = `ff`, `orchestrate_publish` = `push`. The `### Branch model` block gets the same values, so no consumer ever sees a PR destination the user did not choose.
- `app_surface` = `unknown` (keeps all QA tooling; `/setup:create-CLAUDE_MD` detects it from the stack later).
- `commands`: `pr` = `git_host != none || <user keeps PR tooling>` (with `git_host=none` recommend **keep**), `jira` = `tracker == jira`, `confluence`, `codex` = the Screen 2 answer, `qa_runtime_ui` = `true` (because `app_surface=unknown`).

Show the full profile and the `commands.*` manifest on Screen 3. Write the file only after **Approve and run**.

---

## Phase B — Configure

Seven ordered steps. Each reports one line `created | kept | skipped(<why>)`. Never rewrite a whole file — replace only the named block or entry.

**1. `.env.example` contract.** Toggle blocks by commenting/uncommenting whole lines (keep the explanatory comments):
- Jira block (`JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`) active **iff** `tracker=jira`.
- Confluence block (`CONFLUENCE_*`) active **iff** `confluence=true`.
- PR blocks: with `commands.pr && git_host != none` activate **exactly one** — `GITHUB_TOKEN` | `BITBUCKET_EMAIL`+`BITBUCKET_TOKEN` | `GITLAB_TOKEN` — and leave the other two commented. With `commands.pr && git_host=none` leave all three commented and report `PR credentials deferred — rerun /setup:start after git remote add origin`. With `!commands.pr` all three commented.
- Then print, verbatim, the human step (Claude must not run it):
  ```
  ! cp .env.example .env && chmod 600 .env
  ```
  followed by the list of active keys to fill and `restart Claude Code — MCP servers read .env at startup`. If the user already has `.env`, say: "restart Claude Code — the SessionStart preflight reports any missing keys" (this command never looks).
- Four states to verify by reading the result: Jira only · Confluence only · neither · both.

**2. `.mcp.json`.** Requires `jq`; absent → `skipped(jq not on PATH — edit .mcp.json by hand: …)` with the exact servers to remove. Remove `atlassian` when `tracker=none && !confluence`. Remove `playwright` only when `app_surface` ∈ {`none`,`mobile`,`desktop`,`tui`} — with `unknown` (always, from this command) it stays. Never add servers; never touch `context7`.

**3. `CLAUDE.md` blocks.** Edit in place, only inside these blocks:
- `### Branch model`: fill the six labelled fields (`**Preset:**`, `**Trunk:**`, `**Integration:**`, `**Branch names:**`, `**Base → PR dest:**`, `**Protected:**`) from the profile; emit `**Merge:**` only for the direct-push override (`ff`) — otherwise omit the line, as the template says.
- `**Orchestrate publish:**` line → the profile value.
- Language Rules: find the row whose first cell is `Claude ↔ developer communication` and replace its **whole second cell** with `**Polish** — always (set at bootstrap by \`/setup:start\`)` or the English equivalent. Match the row by its first cell — the seed has a literal `**Polish**`, the template has `{communication-language}`; both must work.
- Brownfield with an existing populated `CLAUDE.md` → same block-only rule; if a block is already populated and differs from the profile, STOP and ask which is right (drift), then write both.

**4. `user-profile.md`.** `[ -f .agents/memory/user-profile.md ] || cp .agents/memory/user-profile.md.example .agents/memory/user-profile.md` → `created | kept`. It is gitignored, per developer.

**5. `qa-env.json`.** Only when `app_surface=web` and the user gives a URL. From this command `app_surface` is always `unknown` → `skipped(app_surface unknown — /prime-qa will ask)`.

**6. Toolchain block in `.claude/hooks/check-project-deps.sh`.** Detect a manifest at the root: `package.json` → `node` (+ `[ -d node_modules ]`), `pyproject.toml`/`requirements.txt` → `python3` (+ `uv` if `uv.lock`), `go.mod` → `go`, `Cargo.toml` → `cargo`, `pubspec.yaml` → `flutter`. Insert one `command -v X >/dev/null 2>&1 || add "X not on PATH — Validation gates will fail."` line per detected tool **between** the `# --- toolchain ---` marker and the `# --- .env ----` marker, below the existing example comments. No manifest (greenfield) → `skipped(no manifest yet — rerun /setup:start --rerun after the scaffold; listed in Phase C)`. Validate with `bash -n`.

**7. Command pruning — validate before deleting; there is no rollback** (`git checkout -- *` is denied in `settings.json`). For each **disabled** group, in this order:

Groups and their known coupled edits:

| Group (`commands.*` = false) | Files removed | Coupled edits in the same confirmed step |
|---|---|---|
| `pr` | `.claude/commands/pr-create.md`, `.claude/skills/pr-comments/`, `.agents/reference/pr-host-api.md` | drop the `Bash(bash .claude/skills/pr-comments/references/pr-api.sh:*)` allow entry in `.claude/settings.json`; delete the **Recorded exception: `pr-api.sh`** paragraph in `CLAUDE.md → Security`; drop the `/pr-create` and `/pr-comments` rows in `README.md → Daily workflow` |
| `jira` | `.claude/skills/jira/`, `.claude/commands/start-task.md`, `.claude/commands/prime-ba.md`, `.agents/reference/jira-mcp-atlassian.md`, `.agents/memory/domain/jira.md` **only while its frontmatter says `status: empty`** (otherwise keep — project knowledge) | drop only `mcp__atlassian__jira_*` entries in `.claude/settings.json` (keep `confluence_*` while Confluence is enabled; drop all Atlassian entries only when both are disabled); `/start-task`, `/prime-ba` rows in `README.md`; the `jira-mcp-atlassian.md` links in `.claude/commands/qa-verify.md` and `docs/TUTORIAL.md` |
| `confluence` | `.claude/skills/confluence/` | `mcp__atlassian__confluence_*` entries in `.claude/settings.json` (only if Jira is also disabled — otherwise they are harmless, keep); `/confluence` row in `README.md` |
| `codex` | `.claude/commands/codex-review.md` (every other Codex hook fails open — keep them) | `/codex-review` mentions in `README.md`, `.claude/commands/check-implementation.md`, `.claude/commands/quick-change.md` |
| `qa_runtime_ui` | `.claude/agents/qa-runtime-ui.md` (keep `qa-runtime-app.md.example`) | `qa-runtime-ui` mentions in `.agents/reference/qa-evidence-families.md`, `README.md` |

(i) **Inventory.** For every identifier of the group's files — full path, basename, stem, slash name (`/codex-review`), skill name (`pr-comments`), agent name (`qa-runtime-ui`) — run `rg --hidden -g '!.git' -l -F '<identifier>' .claude .agents CLAUDE.md README.md docs`, **excluding the control documents** `.claude/commands/setup/start.md`, `.agents/specs/**`, `.agents/plans/**` (they name every group by design). Add every hit to the coupled-edit list. Classify each hit as *link/row* (delete the line) or *sentence* (reword to "(not installed in this project)"). **Any hit you cannot classify → keep the group**, print the hits, move to the next group.

(ii) **Confirm.** One `AskUserQuestion` per group listing exactly the files to delete and the coupled edits, with the recommendation **(Recommended) Remove**. A "keep" answer sets `commands.<group>=false` in the profile anyway (the user opted out of the tooling) but deletes nothing and records nothing in `excluded`.

(iii) **Coupled edits first**, with the Edit tool, one file at a time.

(iv) **Delete.** Partition: `git ls-files --error-unmatch <path> >/dev/null 2>&1` → tracked → collect for one `git rm -r -q <paths…>` call (ask-tier); untracked (brownfield right after `cp -R`) → `rm -r <paths…>` after the same confirmation. Do not chain the delete with a commit.

(v) **Record.** Append the deleted paths to `.claude/.starter-sync.json → excluded` (directory entries with a trailing `/`). `/maintain:sync-from-starter` skips them and respects the profile when merging `.mcp.json` / `settings.json`.

After all groups: run the six reference sweeps from `.claude/commands/maintain/cleanup-workflow.md → Phase 1` (markdown links 1.1, inline path refs 1.2, section anchors 1.3, slash commands 1.4, MCP refs 1.5, CLAUDE.md contract 1.6) **inline, read-only**, with the same control-document exclusion, and print leftovers verbatim. Never invoke `/maintain:cleanup-workflow` itself — it has a pruning phase. Leftovers are a report, not a gate: they mean step (i) missed an identifier; tell the user to fix them by hand.

---

## Phase C — Route

Print one numbered list. Run nothing. State that the listed commands continue in this same primed conversation, or that `/prime` must be repeated after a fresh chat (`/setup:create-backlog` and `/brainstorm` stop without it).

**Greenfield:**
1. `/setup:create-PRD` — describe the product; writes `docs/PRD.md`
2. `/setup:stack-research` — pick the stack; edits the PRD
3. `/maintain:refresh-brief` — distill the PRD into `project-brief.md`
4. `/prime`
5. `/setup:create-backlog` — `.agents/backlog.md` from the PRD (skip if `tracker=jira` and the backlog lives there)
6. `/brainstorm` — designs the next free task (`E0-1`, the scaffold)
7. `/plan-feature` → 8. `/execute`
9. `/setup:start --rerun` — fills the toolchain block now that a manifest exists
10. `/setup:create-CLAUDE_MD` — generates `CLAUDE.md`, `architecture.md`, README from the scaffold; detects `app_surface`

**Brownfield:**
1. `/prime`
2. `/setup:map-codebase` — architecture map + reconstructed PRD, then its own cascade
3. `/setup:create-backlog` — optional

---

## Re-run (profile exists, or `--rerun`)

- Show the current profile as a table; for each screen ask **keep / change**. Changed answers re-derive the profile (A.3) and re-run Phase B — steps report `kept` for anything already in place.
- Enabled → disabled for a group: the normal pruning path (step 7).
- **Disabled → enabled for a pruned group is refused.** Print exactly: `Group <x> was pruned. To restore: remove its paths from .claude/.starter-sync.json → excluded, then run /maintain:sync-from-starter — it re-offers them.` Restoring is not built into this command.
- Never re-create a file reported `kept`; never re-delete.

---

## Report

Terminal report, in the chosen language:

1. Profile summary (one line per top-level field).
2. Phase B table — step · status · detail. **The table never truncates.**
3. Pruned groups and the paths recorded in `excluded`; groups kept because of unclassifiable hits, with the hits.
4. Human TODOs: the `! cp .env.example .env && chmod 600 .env` line, keys to fill, restart.
5. The Phase C list.

Do not repeat the interview transcript. Reference-sweep leftovers, if any, go under item 3 verbatim — never summarised away.
