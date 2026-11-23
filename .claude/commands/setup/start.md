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

Shaping rule: 3 screens, ≤4 questions each — yields only when a detected value is wrong and the user asks to change it (then re-ask that one question, nothing else). Screen 2's Q8 is its one unconditional follow-up call (the main call already holds four questions, the tool's maximum).

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

4. **Gdzie śledzicie zadania?** / **Where do you track tasks?**
   Jira · GitHub issues · Lokalny backlog / Jira · GitHub issues · The local backlog
   *Jira: będziesz potrzebować adresu Jira (np. `https://firma.atlassian.net`), maila logowania i tokenu API (podam link). GitHub issues: zadania to issues repozytorium, opcjonalnie z tablicą GitHub Project; potrzebny jest zalogowany `gh`. Lokalny backlog: zadania prowadzimy w pliku `.agents/backlog.md`, który zbudujemy z PRD. Poza Jira komendy Jira usuwam.* / *Jira: you will need the Jira URL (e.g. `https://acme.atlassian.net`), your login email and an API token (I will give the link). GitHub issues: tasks are the repo's issues, optionally on a GitHub Project board; needs a logged-in `gh`. Local backlog: tasks live in `.agents/backlog.md`, built from the PRD. Unless you pick Jira, the Jira commands are removed.* → `tracker` (`jira` | `github` | `none`)
   **GitHub only — follow-ups, in this order:**
   - **Repo:** `owner/repo`, default = `origin` when it is a github.com remote → `github.repo`.
   - **Project:** "Czy issues są na tablicy GitHub Project? / Are the issues on a GitHub Project board?" — the owner and number (from the board URL `…/users|orgs/<owner>/projects/<n>`), or **Bez Projectu / No Project**, which is a valid answer: the status moves are then skipped, never an error. With a Project, read `project_id` via `gh project view <n> --owner <o> --format json --jq .id` and the Status field via `gh project field-list <n> --owner <o> --format json`; show its options and let the user pick the one for `started` and the one for `delivered` → `github.project_owner`, `.project_number`, `.project_id`, `.status_field_id`, `.status_options.started|delivered`. A `gh` call that fails → say which, and offer **No Project** or a stop; never write half a Project.
   **QA pool (Jira or GitHub, skippable):** "Który status oznacza 'czeka na QA'? / Which status means 'waiting for QA'?" — GitHub with a Project: the Status options (`gh project field-list <n> --owner <owner> --format json`); Jira or no Project: free text; **Pomiń / Skip** = asked on the first `/qa-verify` pool run → `qa.pool_status`.
   **Jira started status (Jira only, skippable):** "Który status Jira oznacza 'w toku'? / Which Jira status means 'started'?" — free text; **Pomiń / Skip** = asked on the first `/start-team` / `/start-task` (the start's claim transitions a won ticket to it) → `jira.started_status`.
5. **Czy dokumentację piszecie w Confluence?** / **Do you write docs in Confluence?**
   Tak · Nie / Yes · No
   *Ten sam token co do Jira. Jeśli nie: usuwam komendę `/confluence`.* / *Same token as Jira. If no: the `/confluence` command is removed.* → `confluence`
6. **Czy zespół używa Codex do drugiej opinii?** / **Does the team use Codex for a second opinion?**
   *Na tym komputerze: <zainstalowany | brak> — tylko informacja.* / *On this machine: <installed | absent> — informational only.*
   Tak · Nie / Yes · No
   *Codex to drugie AI, które sprawdza plany i kod. Pytam o zespół, bo ta odpowiedź trafia do wspólnego pliku. Jeśli nie: usuwam `/codex-review`, reszta pomija Codex sama.* / *Codex is a second AI that checks plans and code. I ask about the team because this answer goes into a shared file. If no: `/codex-review` is removed; everything else skips Codex on its own.* → `codex`, `commands.codex`
7. **Czy Supervisor ma sam mergować zaakceptowane PR-y zespołów AI?** / **Should the Supervisor merge accepted AI-team PRs on its own?**
   Potwierdzam każdy merge (Recommended) · Automatycznie / I confirm each merge (Recommended) · Automatically
   *Dotyczy tylko równoległych zespołów AI (`/setup:teams`). Potwierdzam: kroki `team-merge-check.sh`, `team-integrate.sh` i `team-integrate-lock.sh` czekają na Twoje kliknięcie (reguły `ask`). Automatycznie: te trzy reguły znikają z `.claude/settings.json` — także dla ról w klonach zespołów. Merge w Azure DevOps (`/pr-merge`) i decyzja Supervisora o auto-merge ich nie czytają.* / *Only for the parallel AI teams (`/setup:teams`). I confirm: the `team-merge-check.sh`, `team-integrate.sh` and `team-integrate-lock.sh` steps wait for your click (`ask` rules). Automatically: those three rules are removed from `.claude/settings.json` — for the roles in the team clones too. The Azure DevOps merge (`/pr-merge`) and the Supervisor's auto-merge decision do not read them.* → `workflow.team_merge` (`confirm` | `auto`)

   **Asked as its own call after Q4–Q7:**
8. **Czy przypominać, kiedy trzeba uruchomić komendy porządkowe?** / **Remind you when upkeep commands are due?**
   Tak, domyślne progi (Recommended) · Nie / Yes, default thresholds (Recommended) · No
   *`/prime` i `/tasks-status` pokażą linię, gdy `/maintain:refresh-brief`, `/maintain:cleanup-workflow` albo `/architecture-review` jest do zrobienia — liczone z historii git, nic nie uruchamia się samo. Progi zmienisz w `.claude/project-profile.json` → `upkeep`.* / *`/prime` and `/tasks-status` show a line when `/maintain:refresh-brief`, `/maintain:cleanup-workflow` or `/architecture-review` is due — counted from git history, nothing runs by itself. Change the thresholds in `.claude/project-profile.json` → `upkeep`.* → `upkeep`

**Screen 3 — Podsumowanie / Summary** — after A.3 derivation, before Phase B. One table: **co utworzę / will create** · **co usunę / will remove** (files per disabled group) · **co musisz zrobić ręcznie / manual steps** (`cp .env.example .env`, keys to fill, restart; the LSP activation gate from step 6b, when a manifest is present; the step 9 restart and commit + push for the team clones, when it changes the settings; the `teams` compatibility notes from A.3, when any). Options: **Zatwierdź i wykonaj / Approve and run** · **Zmień coś / Change something** (→ re-ask the named question only). No new facts are collected here.

### A.3 Derive the profile

Expand the answers into `.claude/project-profile.json` (schema and field docs: `.claude/project-profile.json.example`).

- `workflow.*` from the preset via the table in `.claude/commands/setup/create-CLAUDE_MD.md → Identify Git Workflow` (the six-field expansion; reference it, do not copy it), `orchestrate_publish` per the same section's derivation rule (`gitflow`/PR-gated → `branch-local`, else `push`).
- **`branch_pattern` from the interview**: `tracker=jira` → `<type>/<KEY>-<slug>`, `tracker=github` → `<type>/<n>-<slug>` (the issue number, the shape team branches use), `none` → `<type>/<slug>`. Never use the file-presence predicate in `create-CLAUDE_MD` — the Jira skill exists in every fresh clone, pruning comes later.
- **Direct-push override** (`pr_required=false`): after expansion set `pr_dest` = `commit on <trunk> or short-lived branches merged locally — no PR`, `protected` = `[]`, `merge` = `ff`, `orchestrate_publish` = `push`. The `### Branch model` block gets the same values, so no consumer ever sees a PR destination the user did not choose.
- `github` (only for `tracker=github`): the Q4 follow-ups — `repo`, plus the six Project fields or none of them (No Project). It is the one github block of the profile: the team layer reads it too when `teams.github` is absent.
- `qa.pool_status` = the Q4 QA-pool answer; skipped → not written (an existing value is kept by the merge rule).
- `jira.started_status` = the Q4 answer; skipped → not written (an existing value is kept by the merge rule). It is merged into the `jira` object after the merge below (`.jira = ((.jira // {}) + {started_status: $s})`), so `estimates` and `commit_drafts` stay.
- `app_surface` = `unknown` (keeps all QA tooling; `/setup:create-CLAUDE_MD` detects it from the stack later).
- `commands`: `pr` = `git_host != none || <user keeps PR tooling>` (with `git_host=none` recommend **keep**), `jira` = **Jira in use** (below), `confluence`, `codex` = the Screen 2 answer, `qa_runtime_ui` = `true` (because `app_surface=unknown`), `herdr` = the profile's existing `commands.herdr` when the key is present, else `true` (no question: `/maintain:sync-herdr-kit` is a no-op without a Herdr app home, and a plain derived `true` would overwrite a project's `false` through the merge below).
- **Jira in use** = `tracker == jira`, or the profile keeps a `teams` block with `teams.tracker == jira`. `commands.jira`, the step 1 Jira block and the step 2 `atlassian` removal key on it — never on the Q4 answer alone — so a kept `teams.tracker=jira` keeps the Jira tooling until the two tracker answers agree.
- `workflow.team_merge` = the Q7 answer (`confirm` | `auto`).
- `upkeep` = the Q8 answer: **Yes** + an existing `upkeep` object → that object, unchanged; **Yes** + absent or `false` → `{"cleanup_workflow": {"commits": 200, "min_days": 14}, "architecture_review": {"feat_commits": 40, "min_days": 14, "repo": ""}, "refresh_brief": true}`; **No** → `false`. It goes through the merge below like any derived top-level key.

Show the full profile and the `commands.*` manifest on Screen 3. Write the file only after **Approve and run**. No profile yet → write `schema` plus the derived keys. An existing profile → merge with `jq` (write to a temp file in `.claude/`, then move it over): each derived top-level key replaces its value, `commands` and `workflow` are merged key by key, every key A.3 does not derive is kept (`teams` from `/setup:teams`, `ba`, `status_report`, `jira`, `commands.ba`, `workflow.tracker_comments` and the other opt-ins the example documents), and A.3 never deletes a key it does not own. The `workflow` keys A.3 owns — `preset pr_required trunk integration branch_types branch_pattern pr_dest protected merge orchestrate_publish team_merge` — are dropped first when the new derivation omits them, so a Q3 change from (a) leaves no stale `pr_required: false` / `merge: ff` behind. With the derived keys in `$d` and that list in `$own`: `. as $p | $p + ($d | del(.workflow, .commands)) | .commands = (($p.commands // {}) + $d.commands) | .workflow = ((($p.workflow // {}) | with_entries(select(.key as $k | $own | index($k) | not))) + $d.workflow)`. Why: a fresh write drops the `teams` block, and step 9 then skips a changed Q7.

With a kept `teams` block (no new question):

- Q4 tracker ≠ `teams.tracker` → the top-level `tracker` is written as answered, but the effective tracker stays `teams.tracker` (`team-tracker.sh` and `/start-task` read it while a `teams` block exists). Screen 3 lists "change `teams.tracker` with `/setup:teams`" under manual steps; the Report repeats it under human TODOs. Until they agree, Phase B follows **Jira in use**: it neither comments out the `JIRA_*` block, removes `atlassian` nor offers the jira prune while either answer is `jira`.
- `tracker=github` + No Project while `teams.tracker=github` and the profile has no `teams.github` → the top-level `github` block keeps its six Project fields (the team layer reads that block and requires them — `.claude/commands/setup/teams.md`); Screen 3 says so. Otherwise No Project writes the block without them.

---

## Phase B — Configure

Ten ordered steps (0–9). Each reports one line `created | kept | skipped(<why>)`. Never rewrite a whole file — replace only the named block or entry.

**0. Fork commit.** Gives the first `/maintain:sync-from-starter` a 3-way base. `last_sync_commit` in `.claude/.starter-sync.json` already set → `kept`. Otherwise run `bash .claude/lib/starter-fork-commit.sh "$(jq -r .starter_repo .claude/.starter-sync.json)"` (needs the network; it reads committed history only, so earlier writes in this command do not affect it). It prints `<hash> <date> <method>` → set exactly `last_sync_commit` = the hash and `last_sync_date` = the date with `jq` (write to a temp file, then move it over), report `created (<method>)`. Exit 1 → write nothing, report `skipped(<its reason> — the first sync infers the base again, else runs 2-way)`. A brownfield copy has no exact evidence and is skipped by design — never type a commit in by hand. No `jq` → `skipped(jq not on PATH)`.

**1. `.env.example` contract.** Toggle blocks by commenting/uncommenting whole lines (keep the explanatory comments):
- Jira block (`JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`) active **iff** Jira is in use (A.3).
- Confluence block (`CONFLUENCE_*`) active **iff** `confluence=true`.
- PR blocks: with `commands.pr && git_host != none` activate **exactly one** — `GITHUB_TOKEN` | `BITBUCKET_EMAIL`+`BITBUCKET_TOKEN` | `GITLAB_TOKEN` — and leave the other two commented. With `commands.pr && git_host=none` leave all three commented and report `PR credentials deferred — rerun /setup:start after git remote add origin`. With `!commands.pr` all three commented.
- Then print, verbatim, the human step (Claude must not run it):
  ```
  ! cp .env.example .env && chmod 600 .env
  ```
  followed by the list of active keys to fill and `restart Claude Code — MCP servers read .env at startup`. If the user already has `.env`, say: "restart Claude Code — the SessionStart preflight reports any missing keys" (this command never looks).
- Four states to verify by reading the result: Jira only · Confluence only · neither · both.

**2. `.mcp.json`.** Requires `jq`; absent → `skipped(jq not on PATH — edit .mcp.json by hand: …)` with the exact servers to remove. Remove `atlassian` when Jira is not in use (A.3) and `!confluence`. Remove `playwright` only when `app_surface` ∈ {`none`,`mobile`,`desktop`,`tui`} — with `unknown` (always, from this command) it stays. Never add servers; never touch `context7`.

**3. `CLAUDE.md` blocks.** Edit in place, only inside these blocks:
- `### Branch model`: fill the six labelled fields (`**Preset:**`, `**Trunk:**`, `**Integration:**`, `**Branch names:**`, `**Base → PR dest:**`, `**Protected:**`) from the profile; emit `**Merge:**` only for the direct-push override (`ff`) — otherwise omit the line, as the template says. `**Maintenance:**` / `**Retired:**` are never written from the profile: delete the template's placeholder lines, and keep a populated block's existing lines untouched (they are not drift). `**Protected push:** pr-only` is written only when filling the block from the placeholder with `pr_required=true` and a non-empty `protected`; otherwise delete the line. A populated block keeps its `**Protected push:**` line as it is, or its absence (an opt-out), and is never drift.
- `**Orchestrate publish:**` line → the profile value.
- Language Rules: find the row whose first cell is `Claude ↔ developer communication` and replace its **whole second cell** with `**Polish** — always (set at bootstrap by \`/setup:start\`)` or the English equivalent. Match the row by its first cell — the seed has a literal `**Polish**`, the template has `{communication-language}`; both must work.
- Brownfield with an existing populated `CLAUDE.md` → same block-only rule; if a block is already populated and differs from the profile, STOP and ask which is right (drift), then write both.

**4. `user-profile.md`.** `[ -f .agents/memory/user-profile.md ] || cp .agents/memory/user-profile.md.example .agents/memory/user-profile.md` → `created | kept`. It is gitignored, per developer.

**5. `qa-env.json`.** Only when `app_surface=web` and the user gives a URL. From this command `app_surface` is always `unknown` → `skipped(app_surface unknown — /prime-qa will ask)`.

**6. Toolchain block in `.claude/hooks/check-project-deps.sh`.** Detect a manifest at the root: `package.json` → `node` (+ `[ -d node_modules ]`), `pyproject.toml`/`requirements.txt` → `python3` (+ `uv` if `uv.lock`), `composer.json` → `php`, `go.mod` → `go`, `Cargo.toml` → `cargo`, `pubspec.yaml` → `flutter`. Insert one `command -v X >/dev/null 2>&1 || add "X not on PATH — Validation gates will fail."` line per detected tool **between** the `# --- toolchain ---` marker and the `# --- .env ----` marker, below the existing example comments. No manifest (greenfield) → `skipped(no manifest yet — rerun /setup:start --rerun after the scaffold; listed in Phase C)`. Validate with `bash -n`.

**6b. LSP declaration — same manifest, second table.** Claude Code's built-in `LSP` tool (`goToDefinition`, `findReferences`, `incomingCalls`, `hover`, …) works only when a language-server plugin is loaded, and the plugin does not ship the server binary. This sub-step **declares** the plugin in the repo and **watches** the binary; it downloads nothing (this command installs no packages — see *Suggestions* below). Map the detected manifest:

  | Manifest | Plugin (`claude-plugins-official`) | Binary the preflight watches | Human install |
  |---|---|---|---|
  | `package.json` (JS or TS — the plugin covers both) | `typescript-lsp` | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
  | `pyproject.toml` / `requirements*.txt` | `pyright-lsp` | `pyright-langserver` | `npm install -g pyright` |
  | `composer.json` | `php-lsp` | `intelephense` | `npm install -g intelephense` |
  | `go.mod` | `gopls-lsp` | `gopls` | `go install golang.org/x/tools/gopls@latest` |
  | `Cargo.toml` | `rust-analyzer-lsp` | `rust-analyzer` | `rustup component add rust-analyzer` |
  | anything else (`pubspec.yaml`, …) | — | — | `skipped(no mapped official LSP plugin for this stack — see the Code intelligence table in the Claude Code plugin docs)` |

  For a mapped manifest, in order:
  1. **Declare.** Requires `jq`; absent → `skipped(jq not on PATH — add "<plugin>@claude-plugins-official": true under enabledPlugins in .claude/settings.json by hand)`. Merge `{"enabledPlugins": {"<plugin>@claude-plugins-official": true}}` into `.claude/settings.json` (deep merge, nothing else touched). Already `true` → `kept`. This committed entry is what makes every clone see the plugin: Claude Code reports an enabled-but-uninstalled plugin at startup and prints the install command.
  2. **Watch the binary.** Insert `command -v <binary> >/dev/null 2>&1 || add "<binary> not on PATH — the <plugin> plugin is declared but its language server cannot start; the LSP tool falls back to rg. Install: <human install>"` into the toolchain block, same markers as step 6. Already present → `kept`.
  3. **Print the activation gate** — three human steps, network included, never run from this command:
     ```
     claude plugin install <plugin>@claude-plugins-official --scope project
     <human install>
     /reload-plugins        # or restart Claude Code — plugins and their LSP servers load at startup
     ```
     Every later route that needs a loaded LSP (`/setup:create-CLAUDE_MD`, `/setup:map-codebase`) refers to this as **the activation gate**. No manifest → `skipped(no manifest yet)`, as in step 6.

  `/setup:create-CLAUDE_MD` reads this declaration (the `enabledPlugins` key with value `true`) to emit the `## Code Navigation (LSP)` section, and `/maintain:cleanup-workflow` 1.6 uses the same predicate — so the section appears only in a repo that declared the plugin, never off machine state.

**7. Command pruning — validate before deleting; there is no rollback** (`git checkout -- *` is denied in `settings.json`). For each **disabled** group, in this order:

Groups and their known coupled edits:

| Group (`commands.*` = false) | Files removed | Coupled edits in the same confirmed step |
|---|---|---|
| `pr` | `.claude/commands/pr-create.md`, `.claude/skills/pr-comments/`, `.agents/reference/pr-host-api.md` | drop the `Bash(bash .claude/skills/pr-comments/references/pr-api.sh:*)` allow entry in `.claude/settings.json`; delete the **Recorded exception: `pr-api.sh`** paragraph in `CLAUDE.md → Security`; drop the `/pr-create` and `/pr-comments` rows in `.claude/docs/guide.md → Daily workflow` |
| `jira` | `.claude/skills/jira/`, `.claude/commands/start-task.md` **only while neither tracker answer is `github`** (Q4 and, with a kept `teams` block, `teams.tracker` — `/start-task` serves `tracker=github` too), `.agents/reference/jira-mcp-atlassian.md`, `.agents/memory/domain/jira.md` **only while its frontmatter says `status: empty` or `status: seeded`** (template knowledge; `populated` = project knowledge → keep) | drop only `mcp__atlassian__jira_*` entries in `.claude/settings.json` (keep `confluence_*` while Confluence is enabled; drop all Atlassian entries only when both are disabled); the `/start-task` row in `.claude/docs/guide.md` (only when `start-task.md` is removed); the `jira-mcp-atlassian.md` links in `.claude/commands/qa-verify.md` and `docs/TUTORIAL.md` |
| `confluence` | `.claude/skills/confluence/` | `mcp__atlassian__confluence_*` entries in `.claude/settings.json` (only if Jira is also disabled — otherwise they are harmless, keep); `/confluence` row in `.claude/docs/guide.md` |
| `codex` | `.claude/commands/codex-review.md` (every other Codex hook fails open — keep them) | `/codex-review` mentions in `.claude/docs/guide.md`, `.claude/commands/check-implementation.md`, `.claude/commands/quick-change.md` |
| `qa_runtime_ui` | `.claude/agents/qa-runtime-ui.md` (keep `qa-runtime-app.md.example` and `qa-runtime-device.md.example`) | `qa-runtime-ui` and `qa-runtime-device` mentions in `.agents/reference/qa-evidence-families.md`, `.claude/docs/guide.md` |
| `herdr` | `.claude/commands/maintain/sync-herdr-kit.md`, `.claude/lib/herdr-kit-sync.sh`, `.claude/lib/tests/herdr-kit-sync-test.sh` (when present) | drop `herdr-kit-sync-test` from `STANDALONE` in `.claude/lib/tests/team-suite.sh` (when present); the `/maintain:sync-herdr-kit` mentions in `.claude/docs/guide.md` ("Session and upkeep" and the command table); the pointer line in `.claude/team/herdr-mod/panels/README.md` (when present); the mentions in `.claude/commands/maintain/sync-from-starter.md` stay — its hint checks the command file first |

(i) **Inventory.** For every identifier of the group's files — full path, basename, stem, slash name (`/codex-review`), skill name (`pr-comments`), agent name (`qa-runtime-ui`) — run `rg --hidden -g '!.git' -l -F '<identifier>' .claude .agents CLAUDE.md README.md docs`, **excluding the control documents** `.claude/commands/setup/start.md`, `.agents/specs/**`, `.agents/plans/**` (they name every group by design). Add every hit to the coupled-edit list. Classify each hit as *link/row* (delete the line) or *sentence* (reword to "(not installed in this project)"). **Any hit you cannot classify → keep the group**, print the hits, move to the next group.

(ii) **Confirm.** One `AskUserQuestion` per group listing exactly the files to delete and the coupled edits, with the recommendation **(Recommended) Remove**. A "keep" answer sets `commands.<group>=false` in the profile anyway (the user opted out of the tooling) but deletes nothing and records nothing in `excluded`.

(iii) **Coupled edits first**, with the Edit tool, one file at a time.

(iv) **Delete.** Partition: `git ls-files --error-unmatch <path> >/dev/null 2>&1` → tracked → collect for one `git rm -r -q <paths…>` call (ask-tier); untracked (brownfield right after `cp -R`) → `rm -r <paths…>` after the same confirmation. Do not chain the delete with a commit.

(v) **Record.** Append the deleted paths to `.claude/.starter-sync.json → excluded` (directory entries with a trailing `/`). `/maintain:sync-from-starter` skips them and respects the profile when merging `.mcp.json` / `settings.json`.

After all groups: run the six reference sweeps from `.claude/commands/maintain/cleanup-workflow.md → Phase 1` (markdown links 1.1, inline path refs 1.2, section anchors 1.3, slash commands 1.4, MCP refs 1.5, CLAUDE.md contract 1.6) **inline, read-only**, with the same control-document exclusion, and print leftovers verbatim. Never invoke `/maintain:cleanup-workflow` itself — it has a pruning phase. Leftovers are a report, not a gate: they mean step (i) missed an identifier; tell the user to fix them by hand.

**8. Convention docs.** Three files, each `created | kept` — never overwrite an existing one.

- `.claude/templates/TESTING-template.md → TESTING.md`, with the three slots resolved by this **stack table** (`/setup:create-CLAUDE_MD` references it as "the TESTING slot table in `setup/start.md` step 8" — one table, two callers; do not duplicate it):

  | Manifest | `{test-runner}` | `{test-command}` | `{coverage-tool}` |
  |---|---|---|---|
  | `package.json` | first of `vitest` / `jest` / `mocha` / `node:test` found in `devDependencies`, else `unknown` | `<pm> test`, where `<pm>` comes from the `packageManager` field, else the lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, `bun.lockb`/`bun.lock` → `bun`, `package-lock.json` or none → `npm`) — **never the raw `scripts.test` body** (local binaries are on PATH only under the package manager); `unknown` when `scripts.test` is absent | `@vitest/coverage-v8` or `@vitest/coverage-istanbul` if listed; else `jest --coverage` when the runner is jest; else `c8` / `nyc` if listed; else `unknown` |
  | `pyproject.toml` / `requirements*.txt` | `pytest` | `pytest` | `pytest-cov` — all three `unknown` if `pytest` is absent from the deps |
  | `go.mod` | `go test` | `go test ./...` | `go test -cover ./...` |
  | `Cargo.toml` | `cargo test` | `cargo test` | `cargo llvm-cov` if in dev-deps, else `unknown` |
  | `pubspec.yaml` | `flutter test` | `flutter test` | `flutter test --coverage` |
  | *(no manifest)* | `unknown` | `unknown` | `unknown` |

  Any `unknown` stays as the literal `{slot}` in the file and is listed in the report as "fill after the scaffold".
- `.claude/templates/DEFINITION-OF-DONE-template.md → docs/DEFINITION-OF-DONE.md`.
- `.claude/templates/PULL_REQUEST_TEMPLATE.md` → the host path from `pr-create.md` → PR template lookup order: `github` → `.github/PULL_REQUEST_TEMPLATE.md`, `bitbucket` → `.bitbucket/pull_request_template.md`, `gitlab` → `.gitlab/merge_request_templates/Default.md`, `none` → `skipped(no remote)`.

**`mkdir -p` the destination directory first** (`docs/`, `.github/`, `.bitbucket/`, `.gitlab/merge_request_templates/` — none exists in a fresh clone; idempotent).

**9. Team merge rules.** The three rules: `Bash(bash .claude/lib/team-merge-check.sh*)`, `Bash(bash .claude/lib/team-integrate.sh*)`, `Bash(bash .claude/lib/team-integrate-lock.sh*)`. Requires `jq`; absent → `skipped(jq not on PATH — edit permissions.ask in .claude/settings.json by hand: …)` with the three strings. Profile has no `teams` object → `skipped(team layer not installed — /setup:teams applies workflow.team_merge)`. Otherwise edit `.claude/settings.json` with `jq` (write to a temp file in `.claude/`, then move it over): `auto` → remove exactly the three strings from `.permissions.ask`; `confirm` → add each one missing. Nothing changed → `kept`; else `created (<auto: N ask rules removed | confirm: N ask rules added>)` — N is the number of exact strings actually removed or added — plus the human step "running role sessions keep their materialized copy of the ask list — restart them: `bash .claude/lib/roles.sh stop <role>`, then `/roles`; team clones are cut from `origin/<trunk>` and read their own committed `.claude/settings.json` — commit and push this change before the next team run, else the clones' roles keep the old ask list".

---

## Phase C — Route

Print one numbered list. Run nothing. State that the listed commands continue in this same primed conversation, or that `/prime` must be repeated after a fresh chat (`/discover`, `/architect`, `/setup:create-backlog` and `/brainstorm` stop without it).

**Greenfield:**
1. `/prime` — this command ran unprimed; `/discover` and `/architect` need the Loader Convention context
2. `/discover` — interview (or `--import` existing requirements); writes `docs/discovery.md` + `docs/PRD.md`
3. `/architect` — subdomains, decisions (`AD-n`), stack; writes `docs/architecture.md` + `docs/map/system.yaml`
4. `/maintain:refresh-brief` — distill the PRD into `project-brief.md`
5. `/prime` — reload with the new brief
6. `/setup:create-backlog` — Epics/Tasks, Scope, story map, a Summary per Task
7. `/setup:delivery-plan` — details the Epics and computes the plan: order per person and session, working days
8. `/jira sync` — when `tracker=jira`; `/github-sync` — when `tracker=github`
9. `/brainstorm <Task>` (H/XH) or `/quick-change <Task>` (M)
10. `/plan-feature` → 11. `/execute`
12. `/setup:start --rerun` — fills the toolchain block and declares the LSP plugin now that a manifest exists; pass its activation gate (step 6b) **before step 13**
13. `/setup:create-CLAUDE_MD` — generates `CLAUDE.md`, `architecture.md`, README from the scaffold; detects `app_surface`

UI-heavy product: `/design-ui` after `/architect` for the critical flow's key screens — optional, never a gate.

**Brownfield** (the manifest exists, so step 6b already ran — pass its activation gate first; `map-codebase` cascades into `/setup:create-CLAUDE_MD` in the same session):
1. `/prime`
2. `/setup:map-codebase` — architecture map + reconstructed PRD, then its own cascade
3. `/discover --import <your requirements>` — when discovery exists outside the repo
4. `/setup:create-backlog` — optional
5. `/setup:delivery-plan` — details the Epics and computes the plan: order per person and session, working days (after the backlog)

**Suggestions — printed, never executed.** `/setup:start` installs no packages and adds no MCP servers (the LSP plugin in step 6b is *declared*, its install stays a printed human step); these are for the human to copy if wanted:

- **(a) Commit-message enforcement (JS projects).** A commitlint `parserPreset.headerPattern` accepting an optional `[<KEY>-NN] ` prefix — derive the `<KEY>` regex from the tracker key pattern (default `[A-Z]+-\d+`), e.g. `^(?:\[[A-Z]+-\d+\] )?(\w+)(?:\(([^)]+)\))?!?: (.+)$` with `headerCorrespondence: ['type', 'scope', 'subject']` — plus a husky `commit-msg` hook running `commitlint --edit "$1"`. Install only if you want local enforcement of `/commit`'s format.
- **(b) Harness ownership.** A CODEOWNERS stanza routing the AI-workflow files to a tech-lead owner, so a change to the rules gets a rules-owner review:

  ```
  .claude/**                  @<tech-lead>
  .agents/**                  @<tech-lead>
  CLAUDE.md                   @<tech-lead>
  TESTING.md                  @<tech-lead>
  docs/DEFINITION-OF-DONE.md  @<tech-lead>
  ```

---

## Re-run (profile exists, or `--rerun`)

- Show the current profile as a table; for each screen ask **keep / change**. Changed answers re-derive the profile (A.3 merges into the existing file — keys it does not derive stay) and re-run Phase B — steps report `kept` for anything already in place.
- Enabled → disabled for a group: the normal pruning path (step 7).
- A profile without `workflow.team_merge` shows Q7 as `confirm (default)`; changing it re-runs step 9.
- A profile without `upkeep` shows Q8 as `yes (default)`; a kept answer keeps the block as it is.
- **Disabled → enabled for a pruned group is refused.** Print exactly: `Group <x> was pruned. To restore: remove its paths from .claude/.starter-sync.json → excluded, then run /maintain:sync-from-starter — it re-offers them.` Restoring is not built into this command.
- Never re-create a file reported `kept`; never re-delete. Step 6b is idempotent: an `enabledPlugins` entry already `true` and a preflight line already present both report `kept`. Unresolved `{slot}` tokens in `TESTING.md` are filled by `/setup:create-CLAUDE_MD`, not by a re-run.

---

## Report

Terminal report, in the chosen language:

1. Profile summary (one line per top-level field).
2. Phase B table — step · status · detail. **The table never truncates.**
3. Pruned groups and the paths recorded in `excluded`; groups kept because of unclassifiable hits, with the hits.
4. Human TODOs: the `! cp .env.example .env && chmod 600 .env` line, keys to fill, restart; the step 6b activation gate, when a manifest was present; the step 9 human step (role-session restart, commit + push for the clones), when printed; the A.3 `teams` compatibility notes, when any.
5. The Phase C list.

Do not repeat the interview transcript. Reference-sweep leftovers, if any, go under item 3 verbatim — never summarised away.
