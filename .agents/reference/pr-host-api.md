# Reference: PR-host REST APIs (PR comments) — GitHub · Bitbucket Cloud · GitLab

Distilled, project-local reference for the `/pr-comments` skill. Covers just the pull-request
comment surface per host: auth, the endpoints the helper uses, pagination, the comment/thread model
and its normalisation, and known gotchas. Consult this first; fall back to upstream docs only when
something here is marked **validate live** or a behaviour diverges at runtime.

The helper `.claude/skills/pr-comments/references/pr-api.sh` detects the host from `origin` and
prints the **same normalised JSON on every host** — the skill never branches on host. Everything
host-specific lives in the script and in this file.

> **Validation status:** the Bitbucket section carries live-verified facts; the GitHub and GitLab
> sections are written from the public API docs and are **not yet validated live** — see §5.

---

## 1. Normalised contract (what the skill sees)

| Subcommand | Output |
| --- | --- |
| `resolve-pr <KEY>` · `list-open-with-comments [--mine]` | `[{ id, title, branch, author, comment_count, url }]` |
| `whoami` | `{ id, login, name }` — `id` is what `--mine` compares against |
| `comments <PR>` | `[{ id, body, author, path, line, parent_id, resolved, created_at }]` |
| `diff <PR>` | raw unified diff (text) |
| `reply <PR> <PARENT_ID> <FILE>` | `{ id, created_at, url }` |

- `id` = PR number (GitHub), PR id (Bitbucket), MR **iid** (GitLab — not the global `id`).
- `author` = `user.login` (GitHub) · `display_name` (Bitbucket) · `username` (GitLab).
- `path == null` → general (non-inline) comment. `line` = new-side line, old-side as fallback.
- `parent_id == null` → thread root. **Threads are grouped by walking `parent_id` to the root**;
  the chain is multi-level on Bitbucket and flat (every reply → root) on GitHub and GitLab.
- `resolved` = `true|false`, or `null` when the host exposes no resolution flag over REST.
- `reply` targets the thread's **last comment id** on every host; the helper maps that to the
  host's own threading model (§2–4).

Exit codes: **2** bad args · **3** no token · **4** HTTP error · **5** `--mine` could not identify
you · **6** `BITBUCKET_EMAIL` missing · **7** unsupported host.

Credentials are read from the environment first, then the repo-root `.env` (**last** occurrence
wins, duplicates warned), and are sent **only as request headers** — never in a URL, never echoed.

> **Never probe `.env` with Bash** — not `ls`, not `stat`, not `rg`. To learn whether a key is set,
> read the helper's own error output (it names the key, never the value). To *change* `.env`, a
> human runs a `!`-prefixed command. A script invoked through the Bash tool **can** read `.env` —
> which is exactly why `pr-api.sh` works at all.

---

## 2. GitHub (github.com · GitHub Enterprise via `GITHUB_API_URL`)

### Auth

- **Token:** fine-grained personal access token — <https://github.com/settings/personal-access-tokens/new>.
  Repository access: the repo(s) you review on. Permissions: **Pull requests: Read and write**
  (write is what lets `reply` post; reads work with Read alone). Metadata: Read is added automatically.
- **Header:** `Authorization: Bearer <token>` + `Accept: application/vnd.github+json` +
  `X-GitHub-Api-Version: 2022-11-28`.
- **Base:** `https://api.github.com/repos/{owner}/{repo}`. GHE: set `GITHUB_API_URL=https://<host>/api/v3`
  in `.env` — a self-hosted host name is otherwise indistinguishable from "unsupported" (exit 7).
- `.env`: `GITHUB_TOKEN=<token>`.

### Endpoints used

| Purpose | Method + path | Notes |
| --- | --- | --- |
| List open PRs | `GET /pulls?state=open&per_page=100` | Paginated. **Carries no comment counts** → |
| PR detail | `GET /pulls/{n}` | `comments` (general) + `review_comments` (inline) — the helper fetches this per open PR to fill `comment_count`. One call per PR; fine for a handful of open PRs, noticeable on dozens. |
| Inline review comments | `GET /pulls/{n}/comments?per_page=100` | `path`, `line` (**null on outdated comments** → `original_line`), `in_reply_to_id` = the **root** comment (GitHub flattens). |
| General comments | `GET /issues/{n}/comments?per_page=100` | Flat, no threading, no `path`. |
| Diff | `GET /pulls/{n}` with `Accept: application/vnd.github.v3.diff` | Text. |
| Reply inline | `POST /pulls/{n}/comments` `{ body, in_reply_to: <id> }` | 201. `in_reply_to` must be a review-comment id. |
| Reply general | `POST /issues/{n}/comments` `{ body }` | 201. No threading exists for general comments. |
| Token owner | `GET /user` | `login`. |

### Thread / resolution model

- **Two id namespaces.** Review comments (`/pulls/comments/{id}`) and issue comments
  (`/issues/comments/{id}`) are different objects with different reply endpoints. `reply` probes
  `GET /pulls/comments/{PARENT_ID}` first: 200 → inline reply; otherwise → general comment.
- **No thread-resolved flag over REST.** "Resolve conversation" lives only in GraphQL
  (`reviewThread.isResolved`). The helper emits `resolved: null` for every GitHub comment, so the
  skill's triage relies on the last-author heuristic alone. *(A GraphQL lookup is a possible v2.)*
- Pagination: `Link: <url>; rel="next"` response header — absolute URL, follow verbatim.

### Failure modes

| Status | Means | Fix |
| --- | --- | --- |
| `401` | bad / expired token | rotate at the URL above |
| `404` on a repo that exists | fine-grained PAT not granted to this repository (GitHub hides, not forbids) | edit the token's repository access |
| `403` on `reply` only | token has Pull requests: Read only | add Write |
| `403` + `x-ratelimit-remaining: 0` | rate-limited | surface it; do not retry-hammer |

---

## 3. Bitbucket Cloud (bitbucket.org)

### Auth

Auth uses a **personal Atlassian API token with scopes**, sent as HTTP **Basic** auth.

- **Repository access token → Bearer.** With `BITBUCKET_TOKEN` set and `BITBUCKET_EMAIL` unset the helper sends `Authorization: Bearer` instead. Such a token has no `/user` — `whoami` and `--mine` exit **5** — and every `reply` posts as the repository bot, not as you.

**App Passwords are gone** (removed 2026-07-28). **A Repository Access Token is the wrong tool** even
though it works: it carries no personal identity, so every reply it posts is authored by a bot
avatar, permanently — the reason the skill's HARD-GATE 3 says "replies post as you".

1. Profile icon → **Account settings → Security → API tokens → Create API token with scopes**
   (<https://id.atlassian.com/manage-profile/security/api-tokens>). Name it, set an expiry (mandatory),
   select app **Bitbucket**.
2. Scopes:

   | Scope | Grants | Needed for |
   | --- | --- | --- |
   | `read:pullrequest:bitbucket` | view pull requests **and comment** | everything except `whoami` |
   | `read:user:bitbucket` | read your own account (`GET /user`) | `whoami`, and the precise `--mine` filter |
   | `write:pullrequest:bitbucket` | create, update, approve, decline, **merge** | nothing here — add only if `reply` returns 403 |

   `GET /2.0/user` sits on the account surface, so a PR-only token answers `403` there while every PR
   read succeeds (verified live on a downstream project). Omitting `read:user:bitbucket`
   costs `whoami` and demotes `--mine` to its `git config user.name` ↔ `display_name` fallback.
   The write scope grants **merge and decline** — stay on the read scopes unless a 403 forces it.
3. `.env`: `BITBUCKET_EMAIL=<atlassian-account-email>` + `BITBUCKET_TOKEN=<token>`. The email must be
   the Atlassian **account** address — accounts carry aliases (Personal settings → *Email Aliases*);
   an address from Jira or `git config` is a guess, not proof.

- **Base:** `https://api.bitbucket.org/2.0/repositories/{workspace}/{repo}`; `GET /2.0/user` at the root.
- **Header:** `curl -u '<email>:<token>'` + `Accept: application/json`. **Not** Bearer — a leftover
  Bearer header wins over `-u` and silently defeats the change.

### Endpoints used

| Purpose | Method + path | Notes |
| --- | --- | --- |
| List open PRs | `GET /pullrequests?state=OPEN&pagelen=50` | `comment_count`, `source.branch.name`, `links.html.href`. |
| PR comments | `GET /pullrequests/{id}/comments?pagelen=100` | Inline + general + replies; `deleted: true` tombstones are dropped. |
| Diff | `GET /pullrequests/{id}/diff` | text/plain, may **302** → the helper follows with `-L`. |
| Reply | `POST /pullrequests/{id}/comments` `{ content: { raw }, parent: { id } }` | 201. A reply **inherits the parent's inline anchor** — no `inline` block. *(Per API docs — **validate live before relying**; see §5.)* |
| Token owner | `GET /2.0/user` | `uuid`, `display_name`, `nickname`. |

### Thread / resolution model

- `parent.id` chains can be **several levels deep** — the helper passes `parent_id` through as-is.
- `resolution == null` → open; non-null → resolved. Normalised to `resolved: (resolution != null)`.
- `content.raw` holds `@{account-uuid}` mention tokens and escaped markdown — normalise for display,
  preserve verbatim on outbound replies.
- Pagination: `.next` in the body — absolute URL, follow verbatim, never rebuild from `page`.

### Failure modes

| Status | Means | Fix |
| --- | --- | --- |
| `401` | missing/expired token — **or an empty username**, which looks identical (the helper pre-checks the email and exits **6** instead) — or a wrong email alias | rotate the token; check `BITBUCKET_EMAIL` |
| `403` on `whoami` while PR reads succeed | token lacks `read:user:bitbucket` — **not** a broken token | add the scope, or accept the `--mine` fallback |
| `403` on `reply` while reads succeed | token lacks a write scope | add `write:pullrequest:bitbucket`; record it here |
| `403` on *every* call | token has no Bitbucket scopes | recreate with app = Bitbucket |
| `429` | rate-limited | surface it |

**Never guess a scope name — the `403` body tells you**, and the helper prints it:

```
{"type":"error","error":{"message":"Your credentials lack one or more required privilege scopes.",
 "detail":{"required":["read:user:bitbucket"],"granted":["read:pullrequest:bitbucket"]}}}
x-oauth-scopes: read:pullrequest:bitbucket        # what this token actually carries
x-accepted-oauth-scopes: account                  # LEGACY OAuth name — not selectable in the token UI
```

Trust `error.detail.required`; the header uses the old OAuth-app naming. `x-oauth-scopes` is the
quickest way to confirm a replacement token really carries the scopes you clicked.

---

## 4. GitLab (gitlab.com and self-hosted `gitlab.*`)

### Auth

- **Token:** personal access token — <https://gitlab.com/-/user_settings/personal_access_tokens>
  (self-hosted: `https://<host>/-/user_settings/personal_access_tokens`). Scope: **`api`** (the only
  scope that allows writing notes; `read_api` covers everything except `reply`).
- **Header:** `PRIVATE-TOKEN: <token>`.
- **Base:** `https://<host>/api/v4/projects/{url-encoded owner/group/.../repo}` — nested groups are
  legal, so the whole path from `origin` is one URL-encoded project id. `GET /user` at the API root.
- `.env`: `GITLAB_TOKEN=<token>`.

### Endpoints used

| Purpose | Method + path | Notes |
| --- | --- | --- |
| List open MRs | `GET /merge_requests?state=opened&per_page=100` | `iid`, `source_branch`, `author.username`, `user_notes_count` (excludes system notes), `web_url`. |
| Discussions | `GET /merge_requests/{iid}/discussions?per_page=100` | Each discussion = `{ id: <sha>, notes: [...] }`. Notes carry `system`, `position.new_path/new_line` (inline only), `resolvable`, `resolved`. |
| Diff | `GET /merge_requests/{iid}/raw_diffs` | Text; GitLab ≥ 15.7. Older instances: the helper falls back to `GET …/changes` and assembles `diff --git` headers from `.changes[]`. |
| Reply | `POST /merge_requests/{iid}/discussions/{discussion_id}/notes` `{ body }` | 201. |
| Token owner | `GET /user` | `username`. |

### Thread / resolution model

- **The reply target is the discussion id (a sha), not a note id.** The normalised contract keeps
  comment ids as the currency, so `comments` emits `parent_id = <root note id>` for every non-root
  note, and `reply <PR> <PARENT_ID>` re-fetches the discussions and posts to the one that contains
  `PARENT_ID`. Unknown note → exit 2.
- System notes (`system: true` — "changed the description", pushes) are dropped.
- `resolved` is meaningful only when `resolvable` is true (diff notes); otherwise normalised to `null`.
- The reply `url` is constructed as `https://<host>/<project>/-/merge_requests/<iid>#note_<id>`.
- Pagination: `X-Next-Page` response header (a page number, empty on the last page) — the helper
  rewrites the `page=` query param.

### Failure modes

| Status | Means | Fix |
| --- | --- | --- |
| `401` | bad / expired token | rotate |
| `403` on `reply` only | token scoped `read_api` | recreate with `api` |
| `404` on the project | token owner is not a member, or the project path is wrong | check membership; the path is taken verbatim from `origin` |

---

## 5. Live-validation status

Nothing in this kit has been validated against a real host yet — the jq normalisation was tested
offline against fixtures (`PR_API_FIXTURE_DIR`, see the script header). Flip ⏳ → ✅ per project
once a path is exercised, and paste the response shape if it diverges.

| Path | GitHub | Bitbucket | GitLab |
| --- | --- | --- | --- |
| Auth (list PRs `200`) | ⏳ | ⏳ (Basic auth verified on the source project) | ⏳ |
| `GET /user` returns a personal identity | ⏳ | ⏳ (needs `read:user:bitbucket`) | ⏳ |
| Comment listing + pagination | ⏳ Link header | ⏳ `.next` | ⏳ `X-Next-Page` |
| Boundary-safe key match | tested offline (`abc-7` ≠ `ABC-79`) | same | same |
| POST reply threads correctly | ⏳ `in_reply_to` | ⏳ **inline anchor inherited from parent — validate before relying** | ⏳ discussion-id mapping |
| Does the documented read scope permit commenting? | n/a — write is explicit | ⏳ **open question** (scope catalogue says `read:pullrequest` covers "commenting") | n/a — `api` is explicit |
| Diff fallback (`/changes`) | n/a | n/a | ⏳ only on GitLab < 15.7 |

---

## 6. Gotchas (all hosts)

- **`developer.atlassian.com` is a JS SPA** — `WebFetch` returns a truncated shell. Use
  `support.atlassian.com/bitbucket-cloud/docs/…` (server-rendered) for Bitbucket token/scope docs.
- **`resolved == false` ≠ "needs action".** A thread the PR **author already answered** ("Done") is
  still unresolved until a reviewer resolves it. The skill classifies by the thread's **last
  author** and treats `resolved` as a thread-**root** signal only.
- **Boundary-safe key matching is load-bearing.** Two live keys `ABC-7` and `ABC-79` are common; the
  enforced trailing hyphen is what stops the short key from resolving the long branch.
- **Diff is text, not JSON.** Never pipe `diff` output through `jq`.
- **GitHub's `comment_count` costs one extra request per open PR.** If a project keeps dozens of PRs
  open, consider filtering by author first (the helper already does for `--mine`) — recorded here so
  a slow `list-open-with-comments` is not mistaken for a hang.

---

## 7. Authoritative sources

- GitHub — [Pull request review comments](https://docs.github.com/en/rest/pulls/comments) ·
  [Issue comments](https://docs.github.com/en/rest/issues/comments) ·
  [Fine-grained PAT permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).
- Bitbucket — [Using API tokens](https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/) ·
  [REST API scopes](https://developer.atlassian.com/cloud/bitbucket/bitbucket-cloud-rest-api-scopes/) (SPA) ·
  [App-password removal](https://www.atlassian.com/blog/bitbucket/bitbucket-cloud-transitions-to-api-tokens-enhancing-security-with-app-password-deprecation).
- GitLab — [Discussions API](https://docs.gitlab.com/ee/api/discussions.html) ·
  [Merge requests API](https://docs.gitlab.com/ee/api/merge_requests.html) ·
  [Personal access tokens](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html).

_Update §5 the moment a path is validated live. Update the relevant host section whenever a runtime
probe reveals a shape that diverges from what is documented._
