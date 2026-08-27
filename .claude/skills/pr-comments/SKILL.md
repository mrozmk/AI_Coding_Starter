---
name: pr-comments
description: Pull a pull request's code-review comments (GitHub, Bitbucket Cloud or GitLab — detected from `origin`) into the session, reconstruct threads, triage which still need the author (last-author heuristic), propose a reply (+ optional code fix) per thread, and — only on explicit per-thread approval — post the reply back through the host's REST API. Human-in-the-loop: no auto-post, no auto-commit, no auto-resolve. Use for answering PR / MR review comments.
when_to_use: |
  Triggered by "/pr-comments [KEY]", "answer my PR comments", "reply to PR feedback", "handle the
  review comments on my PR / MR", "odpowiedz na komentarze z PR", "ogarnij komentarze z review",
  "co mi napisali w PR", or any request to work through a pull / merge request's code-review
  comments. Optional first argument = a tracker issue key (regex `[A-Z]+-\d+`); its open PR is
  resolved by source-branch match. Omit it to pick from the open PRs that currently have comments.
argument-hint: '[ISSUE-KEY — omit to pick from open PRs with comments]'
allowed-tools: Bash Read Write Edit AskUserQuestion
---

# pr-comments skill

Guided, human-gated handling of a pull request's code-review comments. Pulls the comments, rebuilds
them into threads, triages which threads still need the PR **author**, proposes a reply and an
optional code change per thread, and posts an approved reply back to the correct thread. Nothing is
posted, committed, or resolved without the author's explicit per-thread `y`.

All network I/O goes through the bundled helper `.claude/skills/pr-comments/references/pr-api.sh`
(reference the script by its **full repo-relative path** — a skill runs from the repo root, not its
own folder). The helper detects the host from `git remote get-url origin` and prints the **same
normalised JSON on every host**, so nothing below branches on GitHub vs Bitbucket vs GitLab. Auth,
scopes, endpoints and per-host quirks: [.agents/reference/pr-host-api.md](../../../.agents/reference/pr-host-api.md).

Communication with the developer is in **Polish** (CLAUDE.md → Language Rules); reply drafts posted
to the PR follow the reviewer's language, technical English by default.

---

<HARD-GATE>
Invariants — hold for every invocation, every turn, never relaxed:

1. **Nothing leaves the session without explicit per-thread approval.** No reply is POSTed, no code
   is committed, no thread is resolved automatically. Before any `pr-api.sh reply`, re-display the
   exact reply text + the exact target thread and get a fresh `y` — even if the author pre-approved
   the draft earlier in the run. PR comments are outward-facing and visible to reviewers.

2. **Credentials are never leaked.** Never echo `$GITHUB_TOKEN`, `$BITBUCKET_TOKEN`,
   `$BITBUCKET_EMAIL` or `$GITLAB_TOKEN`, and never paste any of them into a command, file, or
   message. On a missing/invalid/under-scoped credential, fail fast with a **secret-free** message
   pointing at `.env` + the scope setup. **Never probe `.env` from Bash** (`cat`, `ls`, `rg`, …) —
   read the helper's own error output instead; it names the missing key without printing a value.

3. **Replies post as YOU.** Every host is authenticated with a *personal* token, so a reply is
   authored by your own account and publicly attributed to you — permanently, on a thread other
   people are reading. That is the intended behaviour (a repo/bot token would post as a bot). It
   raises the stakes on invariant 1: confirm the exact text and the exact target before posting,
   and be sure the PR is one you should be answering on.

4. **Threads are never auto-resolved.** Resolving stays a human decision in the host UI.
</HARD-GATE>

---

## Phase 0 — Guard & resolve the PR

### 0a. Connectivity / credential preflight

Run the helper's cheapest read as the implicit env check (a **Bash-tool** call — a non-zero exit is
a result to read, not a reason to abort the skill). For the no-arg flow this doubles as the 0b
listing; for a keyed flow, 0b's `resolve-pr` is itself the connectivity probe.

```bash
bash .claude/skills/pr-comments/references/pr-api.sh list-open-with-comments --mine
```

- Valid JSON back → credentials and auth are good; keep the result for 0b's no-arg path.
- Error → **hard-stop**, secret-free. The exit code names the cause:

  | Exit / status | Host | Cause | Tell the author (in Polish) |
  | --- | --- | --- | --- |
  | `2` | all | bad arguments | internal — fix the call |
  | `3` | all | token missing (`GITHUB_TOKEN` / `BITBUCKET_TOKEN` / `GITLAB_TOKEN`) | Dodaj token do `.env` — link i zakresy w `pr-host-api.md` |
  | `6` | Bitbucket | no `BITBUCKET_EMAIL` | Basic auth wymaga e-maila konta Atlassian jako loginu |
  | `7` | — | unsupported host (or GHE without `GITHUB_API_URL`) | Skill obsługuje github.com, bitbucket.org, gitlab.\* |
  | `4` + `401` | all | expired / wrong token; Bitbucket: **or** a wrong email alias | Wygeneruj nowy token; na Bitbucket sprawdź alias e-mail |
  | `4` + `403` on everything | all | token has no scopes for this repo | Utwórz token ponownie z właściwymi zakresami |
  | `4` + `403` on `reply` only | all | read-only token | GitHub: *Pull requests: write* · Bitbucket: `write:pullrequest:bitbucket` · GitLab: scope `api` |
  | `4` + `404` | GitHub | fine-grained PAT not granted to this repo | Dodaj repozytorium do zakresu tokenu |
  | `5` | all | `--mine` could not identify you (`GET /user` failed) | Bitbucket: dodaj `read:user:bitbucket`; GitHub/GitLab: token bez dostępu do `/user` |

  **`.env` is written by a human** — hand the author a `!`-prefixed command, never write it yourself.
  Never fail silently, never print a credential.

### 0b. Resolve which PR

**Argument given (a tracker key, e.g. `ABC-79`):**

```bash
bash .claude/skills/pr-comments/references/pr-api.sh resolve-pr ABC-79
```

Matching is case-insensitive and boundary-safe (key + trailing hyphen against the source branch):
`ABC-7` never resolves the `ABC-79` branch.

- **0 matches** → "Żaden otwarty PR nie ma gałęzi źródłowej z kluczem `<KEY>`"; suggest
  `/pr-comments` with no argument. Stop. **An empty result is not a successful match.**
- **1 match** → proceed with it.
- **>1 matches** → print a numbered table (id / title / branch / author / comment_count) and ask the
  author to pick one (`AskUserQuestion` if ≤4, else free-text number).

**No argument** → from the 0a `list-open-with-comments --mine` result (scoped to **your** PRs),
print a numbered table:

```
#  PR     Comments  Branch                                Title
1  #1231  22        feature/ABC-15-new-design-theme       …
2  #1240  4         bugfix/ABC-1412-cart-quantity-reset   …
```

`--mine` filters to PRs **you authored**, resolved via the token owner (`GET /user`).

Ask the author to pick. If the list is empty, offer to re-run showing **all** open PRs with
comments:

```bash
bash .claude/skills/pr-comments/references/pr-api.sh list-open-with-comments
```

If that is also empty → "Żaden otwarty PR nie ma komentarzy — nie ma czego obsłużyć." Stop.

### 0c. Confirm

Echo the chosen PR's `#id`, title, branch, author, url. Capture the PR `author` — Phase 2 needs it to
tell author from reviewer. If the PR was **not** authored by you (compare with `whoami`), say so
explicitly and ask whether to continue: replies will be attributed to you on someone else's review
thread (HARD-GATE 3).

---

## Phase 1 — Fetch comments + diff

```bash
bash .claude/skills/pr-comments/references/pr-api.sh comments 1231   # normalised JSON array, all pages
bash .claude/skills/pr-comments/references/pr-api.sh diff 1231       # raw unified diff (text)
```

- `comments` rows: `{id, body, author, path, line, parent_id, resolved, created_at}` — inline +
  general + replies, every page, non-deleted. `resolved` is `true|false`, or `null` where the host
  exposes no thread-resolution flag over REST (GitHub; GitLab non-resolvable notes). Resolution is
  **not** pre-filtered — Phase 2 filters at thread level.
- Save the `diff` output to a temp file in the system temp dir (e.g. `pr-<id>.diff` under `mktemp -d`)
  so Phase 3 can locate hunks by `path` + `line` without re-fetching.
- If `comments` returns `[]` → "PR #<id> nie ma komentarzy — nie ma czego obsłużyć." Stop.

---

## Phase 2 — Reconstruct threads & triage

1. **Rebuild threads.** Walk each comment's `parent_id` chain to the **root** (`parent_id == null`).
   Group all comments sharing a root into one thread. Threads are **multi-level** on Bitbucket; on
   GitHub and GitLab every reply points at the root — both shapes collapse to the same grouping.
2. **Order** each thread's comments by `created_at` (oldest → newest).
3. **Filter by resolution at the thread ROOT.** Drop a thread only if its root's `resolved == true`.
   `null` counts as open. (`resolved == false` ≠ "needs action" — an author-answered "Done" thread is
   still unresolved; that is what the last-author test is for.)
4. **Classify by LAST author** (the newest comment in the thread):
   - last author == a **reviewer** (≠ PR author) → 🔴 **needs-action**.
   - last author == the **PR author** → 🟢 **likely-handled** (collapsed, skippable).
5. **Print a triage summary**: `🔴 N do odpowiedzi · 🟢 M prawdopodobnie obsłużone` plus a table:

   ```
   #  State  File:line                              Last by      Preview
   1  🔴     src/pages/home/home_cubit.ts:42        Reviewer A   "this rebuilds on every…"
   2  🟢     packages/options/src/models/foo.ts:17  (author)     "Done — pushed"
   ```

General (non-inline) comments have `path == null` → list them under a **GENERAL** bucket.

---

## Phase 3 — Per-thread loop (🔴 threads, human-in-the-loop)

For each 🔴 thread, in order:

1. **Show context.**
   - `file:line` and the matching **diff hunk** from the saved diff (GENERAL → no hunk).
   - The **normalised thread**: expand mention tokens (`@{uuid}` on Bitbucket) and unescape markdown
     for display — preserve the raw verbatim for any outbound reply (v1 does not rewrite mentions).
   - The reviewer's actual ask, distilled.

2. **Propose.**
   - **(a)** a draft reply (concise, in the reviewer's language; technical English by default).
   - **(b)** *optionally* a code change, shown as a diff, when the comment asks for one.

3. **Gate — ask the author per thread** (`apply` / `edit` / `post` / `skip`):

   - **`apply`** — make the code change with Edit, then run the project's quality gate: the
     commands listed in **`CLAUDE.md → Validation`**, in order, stop on first failure. Judge the
     result against the base branch, not against green — a pre-existing failure is not yours to
     fix here. If `Validation` carries the **Runtime smoke** paragraph and the change touches the
     paths it names while an app is running, also perform
     [.agents/reference/runtime-smoke.md](../../../.agents/reference/runtime-smoke.md).
     `/code-review` is **out of this skill's tool scope** — remind the author to run it separately
     before pushing. Applying code does **not** post anything and does **not** commit.
   - **`edit`** — revise the reply text per the author's instruction, then re-offer the gate.
   - **`post`** — publish the reply on this exact thread:
     1. Write the approved reply text to a temp file under `mktemp -d` (e.g.
        `pr-reply-<id>-<parentId>.md`) — never a repo-tracked file; this avoids shell-escaping the
        comment text.
     2. **Re-display** the exact reply text + the target (`PR #<id>`, `parent #<lastCommentId>`) and
        get a fresh `y` (HARD-GATE 1). Prompt: *"Wysłać dokładnie tę odpowiedź do PR #<id>, wątek
        #<parent>? (y/n)"*.
     3. Post it under the thread's **last** comment id (stable id threading — never re-anchor by
        line; the helper maps the id to the host's thread model itself):
        ```bash
        bash .claude/skills/pr-comments/references/pr-api.sh reply <PR> <PARENT_ID> <tmpdir>/pr-reply-<id>-<parentId>.md
        ```
     4. Confirm the returned `{id, created_at, url}`. Do **not** resolve the thread.
   - **`skip`** — leave the thread untouched, move on.

Never batch-post. One thread, one explicit approval.

---

## Phase 4 — Wrap-up

Print a summary (in Polish):

- **Odpowiedziano:** N threads posted (with their new comment ids / links).
- **Zmieniono:** M files edited via `apply` (list them) + the gate result.
- **Pominięto:** K threads left for the author.

Then:

- If any code changed → remind the author to run **`/code-review`**, then **`/commit`** + **`/push`**
  so a posted "Done" reply matches pushed code. The skill does **not** auto-commit.
- Resolving threads stays **manual** — do it in the host UI once satisfied.

---

## Notes

- **Why a skill, not a flat command.** Needs a bundled, syntax-checkable helper (`pr-api.sh`) plus
  reference material — the same criterion that makes `jira` a skill.
- **No MCP exists for PR comments** on any of the three hosts in this kit (`mcp-atlassian` is
  Jira/Confluence only). Direct REST via `pr-api.sh` (`curl` + `jq`) is the only path.
- **Boundary-safe key match:** the key plus a trailing hyphen, case-insensitive, against the source
  branch. Generic `[A-Z]+-\d+` — no project prefix is hardcoded.
- **An empty result is never a pass.** `resolve-pr` on a key with no open PR, and `--mine` with no
  authored PRs, both return `[]`. Report that as "nothing found", never as a successful match.
- **The whole of `pr-api.sh` is allowlisted in `.claude/settings.json`, `reply` (a POST)
  included.** Deliberate, and recorded in `CLAUDE.md → Security` as the one exception to the
  `curl -X` / `-d` egress denies: permissions are evaluated against the Bash command string, not
  subprocesses, so the script's internal `curl` is invisible to the deny globs either way. The
  compensating control is HARD-GATE 1: a fresh `y` with the exact reply text and target
  re-displayed before any post, and credentials that travel only as request headers.
- **Out of scope (v1):** auto-resolve, no-approval automation, auto-commit/push, hosts other than
  GitHub / Bitbucket Cloud / GitLab, one-key→many-PRs without a prompt, rewriting mention tokens.
