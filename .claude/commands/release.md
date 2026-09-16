# /release - Create a new version release (commit + tag)

Full version release process: update the CHANGELOG **if the project keeps one**, detect project stack and bump its version manifest, optionally update README version references, create a commit (only if any files changed), create an annotated git tag, and offer to push.

Works across Node (`package.json`), Python (`pyproject.toml`), Rust (`Cargo.toml`), Go (`go.mod` — tag-only), PHP (`composer.json`), and generic `VERSION` files.

## Steps to follow (execute all sequentially):

### 1. Detect current version and analyze changes

- Run `git tag -l | tail -10` to see recent version tags
- If no tags exist yet (first release):
  - Inform the user: "No previous tags found. This will be the first release."
  - Use `git log --oneline` to show all commits
  - Suggest starting version: `0.1.0` or `1.0.0`
- If tags exist:
  - Run `git describe --tags --abbrev=0` to get the latest tag, then run `git log --oneline <tag>..HEAD` (substitute the literal tag from the previous output) to see commits since it
- Determine suggested version bump type based on commits:
  - **Major (X.0.0)**: breaking changes
  - **Minor (x.Y.0)**: new features, backward compatible
  - **Patch (x.y.Z)**: bug fixes, minor improvements
- **Ask the user to confirm the new version number before proceeding — do not continue until confirmed**

### 2. Update CHANGELOG.md — **only if the project already keeps one**

- Check for it first: `rg --files -g 'CHANGELOG.md'`.
- **If `CHANGELOG.md` does NOT exist → skip this step entirely. Do NOT create one.** A missing CHANGELOG is a deliberate choice (e.g. this starter ships without one so each cloned project decides for itself) — generating it uninvited leaves an unwanted file the user must delete. The tag + git history are sufficient. Only create a CHANGELOG if the user **explicitly** asks for one in this `/release` invocation; in that case seed it with the standard header below, then add the entry.
  ```markdown
  # Changelog

  All notable changes to this project will be documented in this file.
  ```
- **If `CHANGELOG.md` exists** → add a new entry at the top (below the header):
  ```markdown
  ## [X.Y.Z] - YYYY-MM-DD

  ### Added
  - ...

  ### Changed
  - ...

  ### Fixed
  - ...
  ```
- Derive entries from actual commit messages since last tag — do not invent content

### 3. Update README.md (if relevant version references exist)

- If `README.md` does not exist, skip this step
- Read `README.md` fully
- If it contains any explicit version references (version badges, installation snippets showing a version, a CHANGELOG link with the version), update them to the new version
- Do not invent sections that do not already exist — only update what is already there
- Stage `README.md` if it was modified

### 3b. Documentation sync (conditional)

You already have the commit range since the last tag (from Step 1). Inspect its conventional-commit types:

- If the range contains any `feat`, `feat!`, or `BREAKING CHANGE` — i.e. user-facing surface likely changed — **offer** to sync docs: "This release includes feature/breaking changes. Run documentation-manager to sync README / `docs/` before tagging? (yes/no)"
  - If **yes**: gather the changed files (`git diff --name-only <last-tag>..HEAD`) and spawn `@documentation-manager` with that list and the instruction to sync docs narrowly to what changed (it leaves `.agents/memory/` alone). Its edits are staged with the rest in Step 5.
  - If **no**: proceed without it.
- If the range is **only** `fix` / `chore` / `docs` / `style` / `refactor` (no user-facing surface) → **skip silently**. Per documentation-manager's own rule, do not run it when docs would not drift.

This never blocks the release — it is a quality offer, not a gate.

### 4. Detect project stack and bump version manifest

Detect manifests in priority order and act on the first non-empty match (or on all matches after asking, for monorepos).

Use `rg --files -g <pattern>` (never `grep`) for presence checks, per the project's [CLAUDE.md Search Commands rule](../../CLAUDE.md#search-commands).

| Priority | File pattern | Stack | Action |
|----------|--------------|-------|--------|
| 1 | `package.json` | Node / JS / TS | `jq '.version = "X.Y.Z"' <file> > <file>.tmp && mv <file>.tmp <file>` |
| 2 | `pyproject.toml` | Python (PEP 621 or Poetry) | Edit the `version = "..."` line under `[project]` or `[tool.poetry]` — whichever section exists |
| 3 | `Cargo.toml` | Rust | Edit the `version = "..."` line under `[package]` |
| 4 | `go.mod` | Go | **No version field in manifest** — skip manifest update; tag is authoritative |
| 5 | `composer.json` | PHP | `jq '.version = "X.Y.Z"' <file> > <file>.tmp && mv <file>.tmp <file>` |
| 6 | `VERSION` | Generic fallback | Overwrite file contents with `X.Y.Z\n` |

**Procedure:**

1. For each row above, run `rg --files -g '<pattern>'` to list matches.
2. If **no manifests** match → skip this step entirely. The tag (plus a CHANGELOG entry if the project keeps one) is sufficient.
3. If **exactly one manifest** matches → apply the action from the table.
4. If **multiple manifests** match (monorepo case):
   - List all matches to the user.
   - Ask which ones to bump — do not guess. Offer: "all" / "root only" / "select manually".
   - Apply the action to each selected file.
5. For `pyproject.toml`:
   - First check which section exists: `rg '^\[project\]' pyproject.toml` vs `rg '^\[tool\.poetry\]' pyproject.toml`.
   - Edit the `version = "..."` line in the matching section only.
6. Show the user every file that was modified.

### 5. Create commit (only if files changed) and tag

First check whether Steps 2–4 actually changed anything: `git status --porcelain`.

**If files were changed** (CHANGELOG.md, a manifest, README.md, or docs from Step 3b):

- Stage them with **explicit paths only** — `git add <path>` per file. NEVER `git add .` / `git add -A` / `git add -u`; they sweep up unrelated work from parallel sessions (same rule as `/commit`). Skip `.env`, credentials, large binaries.
- Run `git add` and `git commit` as **separate** commands, not chained with `&&` — the `guard-commit.sh` hook inspects the staged set at commit time and blocks a commit whose stage looks empty, which a single `add && commit` line can trip.
- Commit:
  ```
  chore: release vX.Y.Z

  - [key change 1 from this release]
  - [key change 2 from this release]
  ```

**If NOTHING was changed** (no CHANGELOG, no manifest, no README/version refs — e.g. a tag-only repo like this starter):

- Do **NOT** create an empty release commit. There is nothing to record in a commit; the annotated tag *is* the release. Tag the current HEAD directly and tell the user "no files to commit — tagging HEAD directly".

**Then, in both cases, create the annotated tag** (on HEAD — which is either the new release commit or the existing tip):
```
git tag -a vX.Y.Z -m "Version X.Y.Z - [one-line description]"
```
- Verify: `git tag -l | tail -3`

### 6. Offer to push

- Ask the user: "Release commit and tag created locally. Push to origin now? (yes/no)"
- If yes: run `/push` — it will detect the current branch, push commits, then push tags automatically when new local tags are detected.
- If no: inform the user: "Run /push when ready to publish the release."

## CRITICAL rules:
- NEVER proceed past step 1 without user confirming the version number
- NEVER add "Co-Authored-By: Claude" or any Claude attribution
- NEVER add "🤖 Generated with Claude Code" markers
- NEVER create a `CHANGELOG.md` that does not already exist — update it only if the project keeps one; create one solely on the user's explicit request (its absence is a deliberate choice)
- When a CHANGELOG exists, always derive its content from actual commits — never invent entries
- NEVER create an empty release commit — if Steps 2–4 changed no files, tag HEAD directly
- NEVER `git add .` / `git add -A` / `git add -u` in Step 5 — stage explicit paths only, and run `git add` and `git commit` as separate commands (per `guard-commit.sh`)
- ALWAYS use `rg` for file/content searches — never `grep` or `find` (per [CLAUDE.md](../../CLAUDE.md#search-commands))
- In monorepos with multiple manifests, ALWAYS ask the user which to bump — never guess
