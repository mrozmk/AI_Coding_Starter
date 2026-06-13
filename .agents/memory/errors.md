# Memory: Errors & Lessons

Bugs that occurred during development, root causes, and how to avoid them next time.

Add newest entries at the **TOP**. Format: what failed · why · fix / rule.

---

## Format

```
## YYYY-MM-DD — Short title

**What failed:** {symptom observed}
**Root cause:** {why it happened}
**Fix:** {what was changed}
**Rule:** {generalized lesson — how to avoid this next time}
```

---

## 2026-06-13 — BSD `wc -c` pads output with leading spaces, breaking `^[0-9]+$` validation

**What failed:** `guard-memory.sh` size gate stayed permanently dormant — `TOTAL` never incremented, so the byte sum was always 0 and every edit passed (the hook never blocked even with large memory files).
**Root cause:** `n=$(wc -c < "$file")` on macOS (BSD `wc`) returns the count right-padded with spaces, e.g. `'     200'`. The subsequent guard `printf '%s' "$n" | grep -Eq '^[0-9]+$'` then *failed* (leading spaces aren't digits), so the `&& TOTAL=$((TOTAL + n))` never ran. GNU `wc` doesn't pad, so this only reproduces on macOS/BSD.
**Fix:** strip whitespace before validating — `n=$(wc -c < "$file" | tr -d '[:space:]')`.
**Rule:** in shell hooks meant to run on macOS, never feed raw `wc`/`awk` numeric output straight into a `^[0-9]+$` check or `[ -lt ]`. Trim with `tr -d '[:space:]'` first, or use `$(( ))` which tolerates whitespace. This repo's hooks must be BSD-safe.

## 2026-06-13 — commit-guard reads the staged set BEFORE a compound `add && commit` runs

**What failed:** `git add <files> && git commit -m ...` in a single Bash call either committed the wrong fileset or was blocked by `guard-commit.sh` ("empty staged set").
**Root cause:** the `guard-commit.sh` PreToolUse hook inspects `git diff --cached` at the moment the Bash tool call *starts* — i.e. before the `git add` half of the compound command has executed. So it sees whatever was staged *previously*, not what the command is about to stage. With nothing pre-staged → "empty staged set" block; with leftover staged renames (e.g. from an earlier `git mv`) → those get swept into the commit because `git commit` with no pathspec commits the whole index.
**Fix:** stage in one Bash call, commit in a separate, later Bash call. By the time the commit call's PreToolUse fires, the index already reflects the intended files. Verify with `git diff --cached --name-only` between the two.
**Rule:** never chain `git add` and `git commit` in the same Bash invocation in this repo. Stage first (own call), inspect `--cached`, then commit (own call). `git reset` is allow-listed for fixing a bad local commit (`git reset HEAD~1`).

## 2026-06-13 — moving a command into a subdir silently renames its invocation

**What failed:** reorganizing `.claude/commands/*.md` into subdirectories left ~193 stale `/name` references across 31 files; the commands still worked via fuzzy menu but the documented invocation names were wrong.
**Root cause:** this Claude Code version treats a subdirectory under `.claude/commands/` as an **invocation namespace prefix** — `commands/setup/create-PRD.md` registers as `/setup:create-PRD`, not `/create-PRD`. The token is `namespace:filename`. Moving a file changes how it is invoked.
**Fix:** after `git mv` into a subdir, sweep all textual `/<name>` references to `/<namespace>:<name>` (perl with a path-protecting negative lookbehind `(?<![\w/])` so file-path links like `setup/create-PRD.md` are untouched), and bump root-relative markdown links inside moved files (`../../` → `../../../`).
**Rule:** before grouping commands into subdirs, decide deliberately: subdir = menu grouping **but** a permanent doc-sweep tax + version-coupled names. To get grouping without the tax, keep files flat and use a filename prefix (`git-commit.md` → `/git-commit`) instead — no namespace, no sweep. (In zsh, `rg -l ... | xargs -0` for the sweep — unquoted `$VAR` does not word-split.)
