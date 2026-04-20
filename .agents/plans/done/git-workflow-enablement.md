# Feature: Git Workflow Enablement — /push, /pull, /release

The following plan should be complete, but it's important that you validate codebase patterns and task sanity before you start implementing. Pay special attention to: (1) current `deny` patterns that block the three commands, (2) Claude Code permission-matcher behaviour with arguments after spaces, (3) hardcoded `main` branch references.

**Source spec:** _No file in `.agents/specs/` — spec is the /analysis output from the preceding conversation turn (Option 2 + user decisions on workflow-agnostic design, project-type detection in /release, and extended destructive-op deny list). This is a deliberate deviation from the standard `/brainstorm → specs/` flow, acceptable here because the task is starter-kit meta-config rather than a product feature._

**External docs required:** no — all changes are internal to the starter kit; Claude Code permission syntax is the only external reference and is resolved empirically in Task 1.

---

## Feature Description

Enable the three new git-workflow commands (`/push`, `/pull`, `/release`) that were added to `.claude/commands/` to actually run inside a fresh project cloned from this starter kit. This requires:

1. Relaxing `.claude/settings.json` from "deny almost all git" to "deny only destructive git".
2. Making the three commands **workflow-agnostic** (dynamic branch detection instead of hardcoded `main`).
3. Making `/release` **stack-agnostic** (auto-detect Node / Python / Rust / Go / PHP / generic-VERSION and bump the right manifest).
4. Updating `/create-CLAUDE_MD` to ask about the project's git workflow up-front and bake branch conventions into the generated `CLAUDE.md`.
5. Rewriting the `Git Workflow` sections of `CLAUDE.md` and `.claude/templates/CLAUDE-template.md` so they match the new policy and document the three commands.

## User Story

As a developer starting a new project from this starter kit,
I want the shipped `/push`, `/pull`, `/release` commands to work out-of-the-box on any branch/workflow/stack,
So that I don't have to edit command files or loosen permissions by hand before using them.

## Problem Statement

Three new commands ship with the kit but cannot run because `.claude/settings.json` denies `git push|pull|fetch|stash|tag|...`. Even if permissions were fixed, the commands hardcode `main` as the branch and `/release` hardcodes a TypeScript telegram-bot directory structure (`src/commands/*.ts`) plus a Polish README badge format. Additionally, `/release` uses `grep -rl`/`grep -rn` in direct violation of [CLAUDE.md:177](../../CLAUDE.md#L177) which mandates `rg`.

## Solution Statement

Refactor in three layers:

- **Permissions**: allow non-destructive git, deny destructive operations explicitly (`--force`, `--force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`, `rebase`, `config`, `reflog expire`, `gc --prune=now`).
- **Commands**: replace hardcoded branches with `git rev-parse --abbrev-ref HEAD`; replace project-specific README update with generic "if version references exist, update them"; add a stack-detection step to `/release` that reads `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `composer.json` / `VERSION`; swap `grep` → `rg`.
- **Docs & onboarding**: rewrite Git Workflow section of `CLAUDE.md` + `CLAUDE-template.md`; extend `/create-CLAUDE_MD` to ask about branch strategy and inject the answer into generated `CLAUDE.md`.

## Feature Metadata

**Feature Type**: Enhancement (starter-kit infrastructure)
**Estimated Complexity**: Medium
**Primary Systems Affected**: `.claude/settings.json`, `.claude/commands/*.md`, `.claude/templates/CLAUDE-template.md`, root `CLAUDE.md`
**Dependencies**: None external — Claude Code permission-matcher semantics only.

---

## CONTEXT REFERENCES

### Relevant Codebase Files — IMPORTANT: READ BEFORE IMPLEMENTING

- [.claude/settings.json](../../.claude/settings.json) (lines 18-34) — Current `deny` list blocks all git beyond status/diff/log/add/commit. Needs refactor into granular destructive-only denies.
- [.claude/settings.json](../../.claude/settings.json) (lines 58-100) — Existing `PreToolUse` hooks pattern (uses `jq` on `tool_input`). This is the fallback pattern if permission-matcher does not support `--force` deny.
- [.claude/commands/push.md](../../.claude/commands/push.md) (lines 11, 22, 36, 41) — Four places hardcoding `main`.
- [.claude/commands/pull.md](../../.claude/commands/pull.md) (lines 36, 46, 65-66) — Hardcoded `main` in fetch/pull/log commands.
- [.claude/commands/release.md](../../.claude/commands/release.md) (lines 47-55) — Step 3 "Update README.md" — projectowo-specyficzne (Polish badge, `src/commands/*.ts`).
- [.claude/commands/release.md](../../.claude/commands/release.md) (lines 58-63) — Step 4 uses `grep -rl`/`grep -rn`. Must be replaced with `rg` and narrowed to known manifest files.
- [.claude/commands/create-CLAUDE_MD.md](../../.claude/commands/create-CLAUDE_MD.md) (lines 22-45, 129-168) — Project-type detection already exists here. Extend with a git-workflow question and thread the answer into the generated `CLAUDE.md`.
- [CLAUDE.md](../../CLAUDE.md) (lines 108-113) — Git Workflow section to rewrite. The sentence *"All other git operations … require human hands"* becomes false and must go.
- [.claude/templates/CLAUDE-template.md](../../.claude/templates/CLAUDE-template.md) (lines 163-168) — Mirror of above. Same rewrite.
- [CLAUDE.md](../../CLAUDE.md) (line 177) — *"use rg, never grep or find"* — constraint to enforce in `/release` rewrite.

### New Files to Create

None. All changes are edits to existing files.

### Patterns to Follow

**Settings deny precedence** — based on Claude Code convention: `deny` takes precedence over `allow`. Granular denies coexisting with broad allow is the idiomatic pattern. **This must be empirically verified in Task 1 before relying on it.**

**Hook fallback pattern** — if permission-matcher does not handle `Bash(git push --force*)` correctly, replicate the hook style already used in [.claude/settings.json:58-100](../../.claude/settings.json#L58-L100):

```json
{
  "matcher": "Bash",
  "hooks": [{
    "type": "command",
    "command": "cmd=$(jq -r '.tool_input.command // \"\"'); if echo \"$cmd\" | rg -q '<destructive-regex>'; then echo 'Blocked destructive git op' >&2; exit 2; fi",
    "async": false
  }]
}
```

**Dynamic branch detection** — single helper snippet used consistently across `/push` and `/pull`:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

**Project-type detection for /release** — file-existence probes in priority order:

| Priority | File | Stack |
|----------|------|-------|
| 1 | `package.json` | Node/JS/TS — bump `"version"` field |
| 2 | `pyproject.toml` | Python — bump `[project] version` or `[tool.poetry] version` |
| 3 | `Cargo.toml` | Rust — bump `[package] version` |
| 4 | `go.mod` | Go — no version in manifest; tag only |
| 5 | `composer.json` | PHP — bump `"version"` field |
| 6 | `VERSION` (plain file) | Generic fallback — overwrite file |
| 7 | none detected | CHANGELOG + tag only |

Do not assume a project has exactly one — monorepos may have several. Flag multiple matches to user.

**Markdown conventions** — all three commands already use `###`-numbered steps with bash code fences. Keep that style.

---

## IMPLEMENTATION PLAN

### Phase 1: Foundation — verify permission semantics

Before editing `settings.json` for real, empirically verify Claude Code's permission-matcher handles space-separated arguments in deny patterns. If not, fall back to PreToolUse hook.

### Phase 2: Core — rewrite commands

Three commands updated in parallel — they are independent. Order inside Phase 2 does not matter.

### Phase 3: Integration — settings + docs + onboarding

Wire new permissions. Update `CLAUDE.md`, `CLAUDE-template.md`, and `create-CLAUDE_MD.md` so the policy and the commands are discoverable and the branch convention gets captured at project bootstrap.

### Phase 4: Testing & Validation

Manual smoke tests — this is config/markdown, not code; no automated tests warranted.

---

## STEP-BY-STEP TASKS

### Task 1: VERIFY Claude Code permission-matcher semantics — ✅ DONE

- **RESULT**: All three assumptions confirmed by official Claude Code docs ([Configure permissions — Bash](https://code.claude.com/docs/en/permissions.md#bash)). Verified via `claude-code-guide` agent on 2026-04-20.
  1. **Arg-after-space matching**: YES. `Bash(git push --force*)` in `deny` correctly blocks `git push --force main` while `Bash(git push:*)` in `allow` permits `git push origin main`. Docs: *"A single `*` matches any sequence of characters including spaces, so one wildcard can span multiple arguments."*
  2. **Deny precedence**: YES, explicit. Docs: *"Rules are evaluated in order: **deny → ask → allow**. The first matching rule wins, so deny rules always take precedence."* Precedence holds across all scopes (managed > command-line > local > project > user).
  3. **Glob semantics — space before `*` matters**:
     - `Bash(git push --force*)` (no space) — matches both `git push --force` **and** `git push --force-with-lease` ⇒ **one pattern covers both** force variants. Useful.
     - `Bash(git push --force *)` (with space) — enforces word boundary, matches `git push --force origin main` but NOT `--force-with-lease`.
     - `Bash(ls:*)` is equivalent to `Bash(ls *)` — recognized only at end of pattern.
- **IMPLICATION FOR TASK 2**: No hook fallback needed. Pure `deny` patterns in `settings.json` are sufficient. Additionally — we can collapse the three force variants (`--force`, `-f`, `--force-with-lease`) into fewer patterns by using `Bash(git push --force*)` (covers `--force` and `--force-with-lease` in one entry) + `Bash(git push -f*)`.
- **CAVEAT FROM DOCS**: For fine-grained argument filtering (e.g. URL/domain restrictions on curl), docs recommend PreToolUse hooks over pattern matching. This does not apply to our use case — we are blocking specific flag prefixes, which the pattern system handles cleanly.
- **VALIDATE**: ✅ Confirmed from official docs. Proceed to Task 2 without hook fallback.

### Task 2: UPDATE .claude/settings.json — refactor permissions

- **IMPLEMENT**: Rewrite the `permissions.allow` and `permissions.deny` arrays.
  - **Add to `allow`**: `Bash(git push:*)`, `Bash(git pull:*)`, `Bash(git fetch:*)`, `Bash(git stash:*)`, `Bash(git tag:*)`, `Bash(git describe:*)`, `Bash(git ls-remote:*)`, `Bash(git rev-parse:*)`, `Bash(git remote get-url:*)`, `Bash(git rev-list:*)`, `Bash(rg:*)`.
  - **Remove from `deny`**: the broad blanket bans on the above operations.
  - **Add to `deny`** (destructive-only). Note: `Bash(git push --force*)` with no trailing space covers BOTH `--force` and `--force-with-lease` — one pattern, two variants. Confirmed in Task 1.
    - `Bash(git push --force*)` — covers `--force` and `--force-with-lease`
    - `Bash(git push -f*)` — short-form force
    - `Bash(git reset --hard*)`
    - `Bash(git clean -f*)` — covers `-f`, `-fd`, `-fx`, `-ffd`
    - `Bash(git checkout -- *)`, `Bash(git checkout .*)`, `Bash(git restore .*)`, `Bash(git restore --staged *)`
    - `Bash(git branch -D*)`, `Bash(git branch -d*)` — deny both (lowercase too, per NOTES rationale)
    - `Bash(git rebase*)` — keep blocked; rebase is rarely scriptable safely
    - `Bash(git config*)` — keep blocked; changes identity / hooks bypass
    - `Bash(git reflog expire*)`, `Bash(git gc --prune=now*)`, `Bash(git gc --aggressive*)`
    - Keep `Bash(rm -rf:*)`, `Bash(sudo:*)` and all `.env` / secret file guards as-is.
  - **Hook fallback**: NOT NEEDED. Task 1 confirmed pure deny patterns suffice.
- **PATTERN**: Existing `allow`/`deny` format in [.claude/settings.json](../../.claude/settings.json).
- **GOTCHA**: Once `allow` includes `Bash(git push:*)`, anything starting with `git push` runs without prompt unless caught by a deny. Double-check that every destructive variant has a matching deny entry.
- **VALIDATE**: `jq . .claude/settings.json` parses without error. Manual: attempt `git push --force` from within Claude Code — should be blocked. Attempt `git push origin <branch>` — should run (may prompt user first time).

### Task 3: UPDATE .claude/commands/push.md — dynamic branch + safer protected-branch handling

- **IMPLEMENT**:
  - Replace `git log --oneline origin/main..HEAD` with `git log --oneline origin/$BRANCH..HEAD` where `BRANCH=$(git rev-parse --abbrev-ref HEAD)` is captured at the top of Step 1.
  - Replace `git push origin main` with `git push origin "$BRANCH"`.
  - Replace step-5 log `git log --oneline origin/main~3..origin/main` with `git log --oneline origin/$BRANCH~3..origin/$BRANCH`.
  - **Rewrite** CRITICAL rule "NEVER push to any branch other than `main`" → "If `$BRANCH` is a protected/default branch (`main` / `master` / `trunk` / `develop`), show a one-line confirmation prompt to the user before pushing. Otherwise push silently."
  - Preserve every other step (tag detection, non-FF handling, confirmation log) verbatim.
- **PATTERN**: Bash `$(...)` capture at the top of the command body, referenced as `$BRANCH` throughout — keeps steps readable.
- **GOTCHA**: On a freshly cloned repo, `git rev-parse --abbrev-ref HEAD` on a detached HEAD returns literal `HEAD`. Detect this and abort with: "Detached HEAD — checkout a branch before pushing." Do not assume `main`.
- **VALIDATE**: Read-back test. Manually simulate: `git checkout -b feature/foo`, then pretend to run `/push` — confirm wording in the file resolves to `origin/feature/foo..HEAD`.

### Task 4: UPDATE .claude/commands/pull.md — dynamic branch

- **IMPLEMENT**:
  - Same `BRANCH=$(git rev-parse --abbrev-ref HEAD)` capture at top of Step 3 (after repo verification).
  - Replace `git log --oneline HEAD..origin/main` with `git log --oneline HEAD..origin/$BRANCH`.
  - Replace `git pull origin main` with `git pull origin "$BRANCH"`.
  - Replace step-8 log `git log --oneline ORIG_HEAD..HEAD` stays (ORIG_HEAD is branch-agnostic — no change).
  - Replace final message "up to date with origin/main" with "up to date with origin/$BRANCH".
- **PATTERN**: Same `$BRANCH` capture as push.md — keep consistent.
- **GOTCHA**: Same detached-HEAD edge case as Task 3. Abort early if `BRANCH == HEAD`.
- **VALIDATE**: Read-back test. Verify the string "origin/main" does not appear anywhere in the final file (use `rg "origin/main" .claude/commands/pull.md` — should return nothing).

### Task 5: UPDATE .claude/commands/release.md — project-type detection + rg + generic README

- **IMPLEMENT**:
  - **Step 3 "Update README.md"**: replace the project-specific block (badge format `**Wersja:** vX.Y.Z`, `ls src/commands/*.ts`, "alerts section", "env variables section") with a generic instruction:
    > Read `README.md` if it exists. If it contains any version references (badges, installation snippets, CHANGELOG link with version), update them to the new version. Do not invent sections that aren't already there.
  - **Step 4 "Update version references"**: rewrite completely. New structure:
    1. Detect project stack by file presence in priority order (table in Patterns to Follow above).
    2. For each detected manifest, update the version field in place using `rg` + structured edits:
       - `package.json` → parse with `jq`, rewrite `.version` field, preserve formatting.
       - `pyproject.toml` → detect PEP 621 (`[project] version`) vs Poetry (`[tool.poetry] version`) and update the matching field.
       - `Cargo.toml` → update `[package] version` line.
       - `go.mod` → no version field; skip (tag is authoritative).
       - `composer.json` → parse with `jq`, rewrite `.version`.
       - `VERSION` (plain file) → overwrite with the new version string.
    3. Use `rg --files -g '<manifest>'` (not `grep`) for presence checks, respecting [CLAUDE.md:177](../../CLAUDE.md#L177).
    4. If multiple manifests exist (monorepo), list them to user and ask which to bump — do not guess.
    5. If no manifest detected, skip silently — CHANGELOG + tag is enough.
  - **Keep unchanged**: Step 1 (version detection + confirmation), Step 2 (CHANGELOG), Step 5 (commit + annotated tag), Step 6 (push offer). These are already universal.
- **PATTERN**:
  - `jq` for JSON: `jq '.version = "X.Y.Z"' package.json > tmp && mv tmp package.json`
  - In-place line rewrite for TOML: use `Edit` tool on the exact version line.
- **GOTCHA**:
  - `pyproject.toml` has two possible shapes (PEP 621 vs Poetry) — detect before editing.
  - Monorepos with a root `package.json` + per-package `package.json` files — `rg --files -g package.json` returns all; agent must ask.
  - `VERSION` plain files sometimes include trailing newline; preserve it.
- **VALIDATE**: Read-back test. Run `rg "grep -" .claude/commands/release.md` — should return zero matches (no more grep). Run `rg "Wersja" .claude/commands/release.md` — zero matches.

### Task 6: UPDATE .claude/commands/create-CLAUDE_MD.md — add git-workflow question

- **IMPLEMENT**:
  - Add a new subsection under `## Phase 1: DISCOVER` called `### Identify Git Workflow`. Place it directly after `### Map Directory Structure`.
  - Content: "Ask the user (use `AskUserQuestion` if available) which workflow the project follows, with these options:
    - **Trunk-based on `main`** — all work merges to `main` via PRs
    - **Trunk-based on `master`** — same, legacy naming
    - **GitFlow** — `main` + `develop` + feature/release/hotfix branches
    - **Feature-branch off `main`** — PR-centric, no `develop`
    - **Other** — ask user to describe
    Detect a default from `git symbolic-ref refs/remotes/origin/HEAD` if origin exists."
  - Thread the answer into `## Phase 3: GENERATE` — add a bullet under "Adapt to the project": *"Record the chosen workflow in a new `### Git Workflow` section override inside `CLAUDE.md`, naming the default branch explicitly (e.g. 'Default branch: `main`'). The three commands `/push` `/pull` `/release` detect the current branch dynamically, but baseline documentation should still name the project's convention."*
- **PATTERN**: The existing Phase 1 subsection style — `### <Title>` followed by a short prose block + table or bullets. See [.claude/commands/create-CLAUDE_MD.md:24-45](../../.claude/commands/create-CLAUDE_MD.md#L24-L45) for the project-type table style to mirror.
- **GOTCHA**: Don't make the question blocking for projects without a remote yet (greenfield). Default to "Trunk-based on `main`" silently if `git remote` returns nothing.
- **VALIDATE**: Read-back test — the file should now mention "workflow" in Phase 1 and again in Phase 3.

### Task 7: UPDATE CLAUDE.md — rewrite Git Workflow section

- **IMPLEMENT**: Replace lines 108-113 (`## Git Workflow` section) with the new policy:
  ```markdown
  ## Git Workflow

  - **Commits:** use `/commit` skill — conventional commits (`feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`).
  - **Remote sync:** use `/push` and `/pull` skills — both detect the current branch dynamically (`git rev-parse --abbrev-ref HEAD`). No need to specify a branch.
  - **Releases:** use `/release` skill — bumps version in detected manifest (package.json / pyproject.toml / Cargo.toml / go.mod / composer.json / VERSION), updates CHANGELOG, creates annotated tag.
  - **AI git policy:** AI may run non-destructive git operations (status, diff, log, add, commit, push, pull, fetch, stash, tag, describe, rev-parse, ls-remote). **Destructive operations are denied** in [.claude/settings.json](.claude/settings.json) — this includes `--force`, `--force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`, `rebase`, `config`, `reflog expire`, `gc --prune=now`. When an AI agent needs one of these, it must stop and ask the human.
  - **Never include AI attribution** in commit messages unless explicitly requested.
  - **Default branch:** recorded here at project bootstrap by `/create-CLAUDE_MD` (see below).

  ### Default branch

  > _Filled in by `/create-CLAUDE_MD` based on the git-workflow question. Example: `main` (trunk-based)._
  ```
- **PATTERN**: Same markdown style as current file — `##` section, bullet list, backtick-quoted skills.
- **GOTCHA**: Do not remove the "Never include AI attribution" rule — carry it over verbatim.
- **VALIDATE**: `rg "require human hands" CLAUDE.md` — zero matches (the old phrasing is gone). `rg "Destructive operations are denied" CLAUDE.md` — one match.

### Task 8: UPDATE .claude/templates/CLAUDE-template.md — mirror Git Workflow rewrite

- **IMPLEMENT**: Replace lines 163-168 with the same new `## Git Workflow` block from Task 7. Add the `### Default branch` placeholder as well so every generated CLAUDE.md starts with the slot ready to be filled by `/create-CLAUDE_MD`.
- **PATTERN**: Section is an exact mirror of CLAUDE.md — keep them in sync. Any future policy change must edit both.
- **GOTCHA**: Template uses `<!-- comment -->` style for placeholders in some sections (see lines 18, 26, 56). For the default-branch slot, prefer the existing `_italic placeholder_` style used in CLAUDE.md for consistency across the two files.
- **VALIDATE**: `diff <(rg -A 20 '^## Git Workflow' CLAUDE.md) <(rg -A 20 '^## Git Workflow' .claude/templates/CLAUDE-template.md)` — should show only whitespace differences, no content drift.

---

## TESTING STRATEGY

Project size: small (starter-kit config repo, no application code). Testing scope: **manual validation only**, no unit tests warranted. Every task ends with a read-back test or a grep check; those are the tests.

### Manual validation (mandatory)

1. **Permissions smoke test** — with new `settings.json` active, attempt in sequence:
   - `git status` → runs
   - `git push` (on throwaway branch) → runs, may prompt first time
   - `git push --force` → blocked
   - `git reset --hard HEAD~1` → blocked
   - `git clean -fd` → blocked
   - `git config user.email foo@bar.com` → blocked
2. **Command smoke test** — simulate each command's happy path in a test repo:
   - Create branch `test/plan-validation`, commit a change, run `/push` → should push to `origin/test/plan-validation` without editing the command.
   - Run `/pull` → should fetch/merge on same branch.
   - Run `/release` with version `0.0.1-test` in a repo with `package.json` → version field should be bumped in the manifest.
3. **Docs consistency** — after edits, run:
   ```bash
   rg "origin/main" .claude/commands/{push,pull}.md   # should be empty
   rg "grep -" .claude/commands/release.md             # should be empty
   rg "require human hands" .                          # should be empty
   ```

---

## VALIDATION COMMANDS

### Level 1: Syntax & Style

```bash
# JSON validity
jq . .claude/settings.json

# Markdown files are well-formed (no broken code fences)
rg -U '^```[a-z]*$[\s\S]*?^```$' .claude/commands/*.md --multiline-dotall -c
```

### Level 2: Tests

Skipped — no automated tests in this project.

### Level 3: Manual Validation

See "Manual validation (mandatory)" above — all three smoke tests must pass.

---

## ACCEPTANCE CRITERIA

- [ ] `.claude/settings.json` allows all non-destructive git operations used by `/push`, `/pull`, `/release`.
- [ ] `.claude/settings.json` denies every destructive operation listed in the user's decision: `--force`, `--force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`, `rebase`, `config`, `reflog expire`, `gc --prune=now`.
- [ ] `push.md` and `pull.md` contain zero occurrences of hardcoded `main` / `origin/main`.
- [ ] `release.md` contains zero `grep` invocations and zero project-specific references (`Wersja`, `src/commands/*.ts`).
- [ ] `release.md` handles at least five stacks (Node, Python, Rust, Go, PHP) plus generic VERSION.
- [ ] `create-CLAUDE_MD.md` asks about git workflow and records the answer in the generated `CLAUDE.md`.
- [ ] `CLAUDE.md` and `CLAUDE-template.md` Git Workflow sections are identical in content and reflect the new policy.
- [ ] All smoke tests in "Manual validation" pass.

---

## COMPLETION CHECKLIST

- [ ] Task 1 — permission-matcher verification done, result documented
- [ ] Task 2 — settings.json refactored (or hook fallback installed if needed)
- [ ] Task 3 — push.md dynamic branch
- [ ] Task 4 — pull.md dynamic branch
- [ ] Task 5 — release.md project-type detection + rg + generic README
- [ ] Task 6 — create-CLAUDE_MD.md git-workflow question
- [ ] Task 7 — CLAUDE.md Git Workflow rewrite
- [ ] Task 8 — CLAUDE-template.md mirror
- [ ] All acceptance criteria checked
- [ ] Plan file moved from `.agents/plans/active/` to `.agents/plans/done/` by `/execute`

---

## NOTES

- **Why not break out into per-stack release sub-commands?** Considered and rejected — six manifest parsers in one file is less surface than six files plus a dispatcher. Revisit if the list grows past ten stacks.
- **Why allow `git branch -d` but deny `-D`?** Lowercase `-d` refuses to delete unmerged branches (safe); uppercase `-D` force-deletes. Correction: **deny both** for AI — branch deletion is rare enough that a prompt is acceptable and confusion between the two is a real footgun.
- **Why keep `rebase` fully denied even though user approved the extended list?** Rebase can silently rewrite history in ways the user didn't intend (auto-squash, dropped commits). Scripting it safely requires context no AI should assume. Human hands only.
- **Confidence score: 9.5/10** (upgraded from 8/10 after Task 1 verification on 2026-04-20). The main unknown — whether pattern-based deny handles args after spaces — is resolved: it does, with `deny` winning over `allow`, and `Bash(git push --force*)` (no trailing space) elegantly covers both `--force` and `--force-with-lease` in a single entry. Remaining risk is purely mechanical: monorepo edge case in `/release` (multiple manifests), detached-HEAD edge case in `/push` and `/pull`, both explicitly handled in their tasks.
- **Source-spec caveat**: this plan was written without a `.agents/specs/` file. If future audits need the "why", read back the /analysis output from the conversation that produced this plan, or regenerate a spec via `/brainstorm "git workflow enablement"` pointing at this plan.
