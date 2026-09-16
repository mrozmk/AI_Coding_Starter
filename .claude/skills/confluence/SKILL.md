---
name: confluence
description: Read Confluence Cloud pages AND author new ones via the mcp-atlassian MCP server. Reading resolves a wiki URL, page id, or search phrase (CQL) into content. Authoring is local-first — compose the article as a local markdown "base" file, iterate, and publish ONLY on explicit confirmation (markdown is auto-converted to Confluence format at publish). Never auto-publishes; there is no draft mode in the tools, so a publish goes live immediately.
when_to_use: |
  Triggered by: a Confluence Cloud wiki URL (regex `https?://[^/]+/wiki/`, e.g. https://<workspace>.atlassian.net/wiki/spaces/<SPACE>/overview), the words "confluence", "wiki", "article", "artykuł", "space", "read this page", or authoring intents — "create/write an article", "new page", "publish", "stwórz artykuł", "nowy artykuł". Also via explicit /confluence invocation. First argument may be a wiki URL, a numeric page id, raw CQL, free-text search terms, `new "Title"`, or `publish <draft-file>`. For Jira issues use /jira — this skill is Confluence only.
argument-hint: '[url | page-id | terms | new "Title" | publish <draft>]'
allowed-tools: mcp__atlassian__confluence_search mcp__atlassian__confluence_get_page mcp__atlassian__confluence_get_page_children mcp__atlassian__confluence_get_comments mcp__atlassian__confluence_get_labels mcp__atlassian__confluence_create_page mcp__atlassian__confluence_update_page Write Read Edit Bash
---

# Confluence skill

Single entry point for Confluence Cloud on the `atlassian` MCP server (mcp-atlassian): **read** any page, and **author** new pages through a local-first, human-gated flow. Shares the same Atlassian Cloud credentials as `/jira` (one account-scoped API token authorizes both products) — no new server or token.

**Authoring flow (the contract):**
`user gives guidelines → scope agreed → write local .md base → user reviews → on explicit "publish" + [y] → AI creates the page in Confluence (live).`

<HARD-GATE>
Four invariants — they hold for every invocation, every turn, all session. Never relax them.

1. **Local base first — always.** Never call `confluence_create_page` / `confluence_update_page` until a local markdown base file exists under `.agents/handoffs/confluence-drafts/` **and the user has seen it**. No page is composed straight into Confluence.

2. **Publish is explicit and gated.** A publish happens only when the user explicitly says so (e.g. "publish", "opublikuj", "ok, twórz"), AND after a dry-run summary answered with `y`. Never publish because the user approved the *content* — approving the `.md` is not approval to publish. Re-ask every time.

3. **No draft mode — publish = live.** These MCP tools always create/update as `current`. There is no unpublished-draft option. The dry-run MUST state that the page goes live immediately. The only "draft" is the local `.md`.

4. **No fabricated content.** For reads: never paraphrase a page you didn't fetch. For authoring: put only what the user provided or approved into the base — no invented sections, facts, or filler. Cite page key/id + URL for anything reported.
</HARD-GATE>

---

## Step 1 — Environment preflight

The first MCP call of a session implicitly validates the environment. If any `confluence_*` tool returns `success: true`, the server is connected and Confluence is enabled — proceed. Skip preflight if the session already made a successful Confluence call.

**If the `confluence_*` tools do not exist / are not offered**, the server started without Confluence. Hard-stop and tell the user:

> The mcp-atlassian server has no Confluence tools available — it started without Confluence configured. Check:
>
> 1. The local `.env` (loaded by `.mcp.json` via `--env-file .env`) has real values for `CONFLUENCE_URL`, `CONFLUENCE_USERNAME`, `CONFLUENCE_API_TOKEN`. `CONFLUENCE_URL` must include the `/wiki` suffix (e.g. `https://your-site.atlassian.net/wiki`). Username + token are the **same** as the Jira ones (the Atlassian Cloud API token is account-scoped, not per-product).
> 2. The MCP client was **fully restarted** (Cmd+Q + relaunch) after editing `.env` — env is read once at startup.

**On MCP error:**
- `401` → `CONFLUENCE_API_TOKEN` invalid/expired. Regenerate at [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens) (same token also drives Jira).
- `403` → the account lacks Confluence access/licence on that site, or no permission on that space. Name the space key + username; it's a licence/permission fix, not code.

**Default space** — when a space is needed and none supplied: use `$CONFLUENCE_DEFAULT_SPACE` if set; else infer from a pasted URL; else ask (suggesting the space used most recently this session). Never silently guess.

---

## Step 2 — Dispatch

Inspect `$ARGUMENTS`:

| Input                                                          | Route                          |
| ------------------------------------------------------------- | ------------------------------ |
| `new` / `write` / `create` (+ optional `"Title"`), or a clear authoring request | **Flow W — author** |
| `publish` (+ optional draft filename)                         | **Flow X — publish**           |
| `edit` + a page URL/id, or "update page ..."                  | **Flow E — edit existing**     |
| A full wiki URL (`.../wiki/...`)                              | **Flow U — resolve URL** (read) |
| A bare numeric page id                                        | **Flow P — fetch page** (read) |
| Raw CQL, or free-text search terms                           | **Flow S — search** (read)     |
| _empty_                                                       | Ask: read something, or author a new article? |

---

## Flow W — Author a new article (local base)

1. **Scope with the user** (per HARD-GATE 4 — only what they give):
   - `title` (required)
   - target `space` (default-space rule) and optional `parent_id` / parent page (ask if a location matters; a parent keeps the tree tidy)
   - the content / outline / source material for the body
2. **Compose** the article as markdown from the agreed scope.
3. **Write the local base file** — `.agents/handoffs/confluence-drafts/<slug>.md`, where `<slug>` is the kebab-cased title. Prepend a metadata block so the file is self-describing and re-publishable:

   ```markdown
   ---
   title: '<Title>'
   space: '<SPACE>'
   parent_id: '<id or empty>'
   confluence_page_id: '' # filled in after first publish → future publishes UPDATE
   source_url: '' # set only when seeded from an existing page (Flow E)
   ---

   <article body in markdown>
   ```

4. **Show the user** the saved path and a preview of the body. Enter a **review loop**: they read/edit the file directly, or ask for revisions (edit the `.md` with `Edit`/`Write`). **Nothing goes to Confluence in this flow.**
5. When the user is happy, tell them the next step is `publish` — hand off to **Flow X**. Do not publish here even if they said "looks good"; "good" ≠ "publish" (HARD-GATE 2).

---

## Flow X — Publish a local base to Confluence

Entered only on an explicit publish request.

1. **Locate the base file** — the named draft, or the most recently edited file in `.agents/handoffs/confluence-drafts/` (list them with `Bash(ls -t)` and confirm which one if ambiguous).
2. **Read it** and parse the metadata block: `title`, `space`, `parent_id`, `confluence_page_id`.
3. **Decide create vs update**:
   - `confluence_page_id` empty → **create** a new page.
   - `confluence_page_id` set → **update** that existing page.
4. **Dry-run (HARD-GATE 2 + 3)** — present and wait for `y`:

   ```markdown
   Publishing to Confluence — this page goes LIVE immediately (no draft):

   | Field   | Value                          |
   | ------- | ------------------------------ |
   | Action  | Create new page                |
   | Title   | <Title>                        |
   | Space   | <SPACE>                        |
   | Parent  | <parent title or (space root)> |
   | Source  | drafts/<slug>.md               |

   Publish now? [y/n]
   ```

5. **On `y`** — pass the markdown body (without the metadata block) with `content_format="markdown"` so MCP converts it to Confluence storage format:

   ```
   # create
   confluence_create_page(
       space_key="<SPACE>",
       title="<Title>",
       content="<markdown body>",
       content_format="markdown",
       parent_id="<id>"          # omit if none
   )

   # update (confluence_page_id was set)
   confluence_update_page(
       page_id="<id>",
       title="<Title>",
       content="<markdown body>",
       content_format="markdown",
       version_comment="Updated from local base <slug>.md"
   )
   ```

   (Confirm exact parameter names against the tool schema on first use.)
6. **Record the result** back into the `.md` metadata: write the returned `confluence_page_id` (and `source_url`) so the base stays linked to its page and the next publish becomes an update, not a duplicate.
7. **Report**: `Published: <Title> — <$CONFLUENCE_URL/spaces/<SPACE>/pages/<ID>>`.

**Note on the permission prompt:** `confluence_create_page` / `confluence_update_page` are intentionally NOT in the settings allow-list, so the host will also ask at the permission layer — a second, deliberate confirmation on top of the `y`. Do not suggest allow-listing them away.

---

## Flow E — Edit an existing page (via a local base)

1. Resolve the page (URL → Flow U parsing, or id) and fetch it: `confluence_get_page(page_id=..., convert_to_markdown=true)`.
2. Save the current body as a local base under `drafts/`, with `confluence_page_id` and `source_url` prefilled in the metadata.
3. Review loop (as Flow W) — the user edits the local markdown.
4. On explicit publish → **Flow X**, which sees `confluence_page_id` and performs an **update** (goes live immediately; there is no unpublished edit-draft via these tools — say so in the dry-run).

---

## Read flows

### Flow U — Resolve a wiki URL
| URL pattern                                          | Extract                     | Then                          |
| ---------------------------------------------------- | --------------------------- | ----------------------------- |
| `/wiki/spaces/<SPACE>/pages/<PAGE_ID>/<slug>`        | `space`, `page_id`          | → Flow P                      |
| `/wiki/spaces/<SPACE>/overview`                      | `space` (home)              | → Flow S: browse that space   |
| `/wiki/spaces/<SPACE>/blog/<date>/<PAGE_ID>/<slug>`  | `space`, `page_id`          | → Flow P                      |
| `/wiki/x/<hash>` (tiny link) / no numeric id         | none reliably               | → Flow S, or ask              |
The **page id is the all-digit segment** after `/pages/`; ignore the trailing slug.

### Flow P — Fetch a page by id
```
confluence_get_page(page_id="<ID>", convert_to_markdown=true, include_metadata=true)
```
Report a header (title, space, id, last-updated, canonical URL), render the body as markdown (outline-first if > ~400 lines), and offer follow-ups (never unprompted): `confluence_get_page_children`, `confluence_get_comments`, `confluence_get_labels`, or a summary. Answer any specific question from the fetched content only (HARD-GATE 4).

### Flow S — Search (CQL)
1. Raw CQL → use as-is. Free text → translate, scoped to a known space, and confirm:
   `Interpreting as: space = <SPACE> AND type = page AND text ~ "<terms>". Use it? [y/edit]`
2. `confluence_search(query="<CQL>", limit=25)`
3. Render a results table (`# | Title | Space | Type | Page id | Updated`), let the user pick → Flow P. If `total > 25`, offer to narrow or page.

**CQL cookbook**

| Intent                       | CQL                                                      |
| ---------------------------- | ------------------------------------------------------- |
| Pages in a space by keyword  | `space = <SPACE> AND type = page AND text ~ "onboarding"`    |
| Title match                  | `space = <SPACE> AND title ~ "release checklist"`            |
| Everything in a space        | `space = <SPACE> AND type = page ORDER BY lastmodified DESC` |
| Recently updated             | `type = page AND lastmodified >= now("-14d")`           |
| By label                     | `label = "adr" AND type = page`                         |
| Authored by me               | `type = page AND creator = currentUser()`               |

`~` = contains (fuzzy), `=` = exact. Quote multi-word values. `text ~` = body + title; `title ~` = title only.

---

## Markdown → Confluence conversion

- Pass the body with `content_format="markdown"`; the server converts to Confluence **storage** format. Handled well: headings, bold/italic, lists, tables, fenced code, links, images-by-URL, blockquotes.
- Not expressible in plain markdown: Confluence macros/panels/expand, layout columns. If the user needs those, either keep them out of the base, or author that section in `content_format="storage"` (raw XHTML) — advanced, ask first.
- The local `.md` is the source of truth; re-publishing from it (with `confluence_page_id` set) updates the same page instead of creating a duplicate.

## Field & URL conventions
- **Page id**: all-digit segment after `/pages/`; the handle for `get_page` / `_children` / `_comments` / `_labels` and for update.
- **Space key**: segment after `/spaces/` (e.g. `DOCS`); case-sensitive.
- **Canonical URL**: `$CONFLUENCE_URL/spaces/<SPACE>/pages/<PAGE_ID>` (trailing slug is cosmetic).
- **Drafts dir**: `.agents/handoffs/confluence-drafts/` — local scratchpad, excluded per clone by the same `.git/info/exclude` rule as `/handoff` (see `handoff.md` → first-time setup); never committed.

---

## Error handling
- **`confluence_*` tools missing** → server started without Confluence; Step 1 setup message.
- **`401`** → token invalid/expired; regenerate at id.atlassian.com (shared with Jira).
- **`403`** → no Confluence access/licence, or no create/edit permission on that space; name space + username.
- **`404` on a page id** → report not-found; do not retry mangled ids; offer a title search.
- **`400` on create/update** → surface the raw error (bad `space_key`, unknown `parent_id`, duplicate title in space). No auto-retry. Keep the local base intact so nothing is lost.
- **Empty search** → report zero matches + the CQL used; offer to broaden (`title ~` → `text ~`, drop space filter).
- **4xx/5xx** → show the raw error body. No swallowing.

---

## Language
Skill internals (this file): **English**. User-facing prompts, tables, and reports follow the conversation language; page content is quoted verbatim in its original language. Example confirm prompt: `"Publish now? [y/n]"`.
