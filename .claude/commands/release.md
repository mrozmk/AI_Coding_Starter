# /release - Create a new version release (commit + tag)

Full version release process: update CHANGELOG, detect project stack and bump its version manifest, optionally update README version references, create commit, create annotated git tag.

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

### 2. Update CHANGELOG.md

- If `CHANGELOG.md` does not exist, create it with a standard header first:
  ```markdown
  # Changelog

  All notable changes to this project will be documented in this file.
  ```
- Add new entry at the top (below the header):
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
2. If **no manifests** match → skip this step entirely. CHANGELOG + tag is sufficient.
3. If **exactly one manifest** matches → apply the action from the table.
4. If **multiple manifests** match (monorepo case):
   - List all matches to the user.
   - Ask which ones to bump — do not guess. Offer: "all" / "root only" / "select manually".
   - Apply the action to each selected file.
5. For `pyproject.toml`:
   - First check which section exists: `rg '^\[project\]' pyproject.toml` vs `rg '^\[tool\.poetry\]' pyproject.toml`.
   - Edit the `version = "..."` line in the matching section only.
6. Show the user every file that was modified.

### 5. Create commit and tag

- Stage all changed files (CHANGELOG.md + any manifest files + README.md if modified)
- Create commit:
  ```
  chore: release vX.Y.Z

  - [key change 1 from this release]
  - [key change 2 from this release]
  ```
- Create annotated tag:
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
- Always derive CHANGELOG content from actual commits — never invent entries
- ALWAYS use `rg` for file/content searches — never `grep` or `find` (per [CLAUDE.md](../../CLAUDE.md#search-commands))
- In monorepos with multiple manifests, ALWAYS ask the user which to bump — never guess
