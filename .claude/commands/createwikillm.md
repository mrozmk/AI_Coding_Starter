---
description: Set up an LLM Wiki knowledge base for this project — asks questions, then creates all files
---

# Create LLM Wiki

Sets up a persistent, LLM-maintained wiki knowledge base based on the **Karpathy LLM Wiki pattern**.

## What is LLM Wiki?

Instead of re-deriving knowledge from raw files on every query, an LLM builds and maintains a **persistent wiki** — a structured set of synthesized markdown pages that compounds over time.

Three layers:
- **Raw sources** — your existing data/docs (immutable, never modified by the wiki system)
- **Wiki** — synthesized markdown pages (Claude Code writes them, they grow with every ingest)
- **Schema** — instructions on how the wiki is structured and used (in CLAUDE.md or system prompt)

---

## Step 1: Ask the user these 6 questions (send all at once, wait for all answers)

---

**1. Project domain**
What is this project about? (1–2 sentences describing the domain and purpose)

---

**2. Wiki scenario** — which type(s) do you need?

| Scenario | Maintained by | Read by | Purpose |
|----------|--------------|---------|---------|
| **A — Developer Wiki** | Claude Code | Claude Code | Project knowledge: decisions, API quirks, lessons, architecture |
| **B — Product Wiki** | Claude Code | Internal LLM (bot/agent/assistant at runtime) | Domain knowledge the product LLM uses to answer end-user questions |
| **C — Both** | Claude Code | Both (Claude Code + product LLM) | Project has a dev AI assistant AND a product-facing LLM |

> Example of C: a chatbot project where Claude Code helps you build it (needs dev wiki about architecture), and the chatbot itself uses a wiki to answer user questions better.

---

**3. Main knowledge topics**
What are the 3–5 main topics the wiki should cover?
These become the first seed pages. Be specific to your domain.

> Example (e-commerce assistant): Products, Pricing, Returns, Shipping, Promotions
> Example (internal dev-tool): Architecture, API Reference, Error Patterns, Deployment
> Example (support KB for a SaaS): Onboarding, Troubleshooting, Billing, Integrations

---

**4. Wiki location**
The wiki lives at `.agents/wiki/`. This path is fixed to keep other commands (`/plan-feature`, etc.) able to discover the wiki deterministically. Do not ask the user to choose.

---

**5. Raw sources**
What existing files or data will serve as raw material for wiki creation?
(Claude Code reads these to synthesize wiki pages — it never modifies them.)

> **Default suggestion:** `.agents/sources/` — the starter's shared input layer for raw materials (also used by `/create-PRD`). If that directory already holds relevant briefs/transcripts/data, propose it first, then ask whether additional locations should be added.
>
> Other common examples: `data/knowledge/*.json`, `docs/*.md`, `src/`, API reference files, scraped data files

---

**6. (Only if Scenario B or C) Product LLM integration**

- Which model powers the product LLM? (e.g., Gemini 2.5 Flash, GPT-4o, Claude Haiku)
- Where is the context built for that LLM? (e.g., file name like `src/utils/knowledgeLoader.ts` or a direct API call)
- Should wiki pages have **priority** over raw data in the LLM context? (Recommended: yes — wiki is synthesized, higher quality)

---

## Step 2: Confirm before creating

After receiving answers, summarize what will be created:

```
I'll create the following:

Wiki type: [Scenario X]
Location: [path]
Seed pages: [list of topics → filenames]
Raw sources identified: [list]
[If product wiki]: Integration point: [file/function]

Shall I proceed?
```

Wait for confirmation.

---

## Step 3: Create wiki structure

Create the directory and all meta files.

### Files to always create (both scenarios)

#### `.agents/wiki/SCHEMA.md`

This is the wiki specification — Claude Code reads it before every ingest or query operation.

```markdown
# Wiki Schema — {Project Name}

## Purpose
{One sentence: what knowledge this wiki captures and who reads it}

## Who maintains this wiki
Claude Code — on developer request via /wiki-ingest

## Who reads this wiki
{Scenario A: Claude Code during development sessions}
{Scenario B: {LLM name} at runtime, via context injection}
{Scenario C: Both}

## Directory structure
.agents/wiki/
  SCHEMA.md       — this file
  index.md        — catalog of all pages (update after every ingest)
  log.md          — append-only operation log (append after every operation)
  concepts/       — synthesized domain knowledge, strategies, cross-references
  reference/      — factual data pages (specs, tables, API notes)
  meta/           — system/project-level knowledge (events, integrations, quirks)

## Page format (REQUIRED for every page)

Every page MUST start with YAML frontmatter:

---
title: Page Title
keywords: [kw1, kw2, ...]    ← used for context matching; English base forms, min. 5
sources: [file.json, ...]    ← raw source files this page draws from
updated: YYYY-MM-DD
---

Then: # Title, **Summary** line, **Sources** line, **Last updated** line, ----, content.

Use ## headings, markdown tables for comparative data.
Pre-calculate where useful: aggregate totals, summaries, conversion tables — anything the reader would otherwise re-derive from raw sources.
Cross-link related pages using [[page-name]] syntax.

## keyword[] rules
- English base forms (e.g. `user` not `users`/`userId`, `auth` not `authentication`, `deploy` not `deployment`)
- Include synonyms and domain slang
- Minimum 5 keywords per page

## Content rules
- Pre-compute summaries: don't make the LLM re-derive
- Note contradictions between sources explicitly
- Keep pages focused — one concept per page
- Never duplicate raw stats from source files — wiki is for synthesis

## Operations

### Ingest (adding new knowledge)
1. Read the source
2. Discuss key takeaways with developer
3. Create new page or update existing one
4. Update index.md
5. Append to log.md: `## [YYYY-MM-DD] ingest | Source Name — what changed`

### Query (answering questions)
1. Read index.md to find relevant pages
2. Read those pages
3. Synthesize answer with citations: (wiki: filename.md)
4. Offer to save valuable answers as new pages

### Lint (health check)
Check for: contradictions, orphan pages, stale data, missing cross-references.
Report as a numbered list with suggested fixes.
```

#### `.agents/wiki/index.md`

```markdown
# Wiki Index — {Project Name}

LLM-maintained. Update after every ingest.
Read this first when answering queries or starting an ingest.

## Concepts
{For each seed topic:}
- [{topic}.md](concepts/{topic}.md) — {one-line description}

## Reference
(empty — add as sources are ingested)

## Meta
(empty — add as needed)
```

#### `.agents/wiki/log.md`

```markdown
# Wiki Log

Append-only. Newest entries at top.
Format: `## [YYYY-MM-DD] operation | description`

---

## [{today}] init | Wiki initialized — seed pages created from: {raw sources listed}
```

---

### Seed pages

For each topic from Question 3, create `.agents/wiki/concepts/{topic-slug}.md`:

```markdown
---
title: {Topic Name}
keywords: [{5+ relevant keywords from domain}]
sources: [{relevant raw source files}]
updated: {today}
---

# {Topic Name}

**Summary**: {One sentence describing this page.}

**Sources**: {list of raw source files}

**Last updated**: {today}

---

{Synthesize content from the raw sources.}
{Use tables for comparative data.}
{Pre-calculate useful aggregations.}
{Add cross-references to other planned pages using [[page-name]].}

## Related pages

- [[{other-topic}]]
```

> Read the identified raw sources before writing seed pages. Synthesize — don't just copy.

---

## Step 4: Scenario-specific additions

### Scenario A — Developer Wiki

**Update `CLAUDE.md` — insert a new row into the `## Project Knowledge Layers` table.** Do NOT add a separate "Developer Wiki" section. The wiki is a first-class knowledge layer, not an addendum.

Insert the new row between the existing `plans/` row and the blank line that follows it, matching the existing table's column count (5) and spacing:

```
| [wiki/](.agents/wiki/) | Synthesized knowledge — concepts, references, meta | Append + periodic lint | `/wiki-ingest` | Feature touches a covered domain |
```

Leave the `**Flow:**` line directly below the table untouched — the wiki is orthogonal to `brainstorm → plan → execute` and should not appear in the core flow unless the user explicitly requests it.

---

### Scenario B — Product Wiki

**Algorithm — `readWikiContext(query, extractKeywords) → string`** (language-neutral, ~30–50 lines in most stacks):

Constants:
- `WIKI_DIR = .agents/wiki/`
- `WIKI_SUBDIRS = [concepts, reference, meta]`
- `MAX_WIKI_PAGES = 3`

Steps:
1. **Scan** — if `WIKI_DIR` does not exist, return `""`. Otherwise list every `*.md` file under each `WIKI_SUBDIRS` entry.
2. **Parse frontmatter** — for each page, extract the YAML frontmatter block (`---` … `---` at file start). Read the `keywords:` array.
3. **Score** — if `query` is provided: extract keywords via `extractKeywords(query)` (English base forms, same normalization as page keywords); score each page as the count of query-keywords that overlap the page's `keywords:` array (bi-directional substring match acceptable — `user` matches `users`, `auth` matches `authentication`).
4. **Full-text fallback** — for any page with score 0 after step 3, set score to 1 if any query-keyword appears in the page body (case-insensitive); otherwise drop it.
5. **Sort + top N** — if `query` is non-empty: sort pages by score descending; take the top `MAX_WIKI_PAGES`. If `query` is empty: return all matched pages.
6. **Join + strip** — for each kept page, strip the YAML frontmatter block (leading `---` to next `---` inclusive, plus following blank line); join the results with `\n\n---\n\n`.

**Integration contract:**
- Call this at the start of your product LLM's context-building function.
- Return value is a single string — prepend it as the FIRST section of the LLM's context, before any raw-data sections.
- If the return value is empty, skip the "wiki synthesis" section entirely.

**Add to the product LLM's system prompt:**

```
=== SOURCE HIERARCHY ===
When multiple sources cover the same topic, use them in this order:
1. WIKI SYNTHESIS — pre-computed, synthesized knowledge → use as primary source
2. [Other data sections] — precise raw stats → use when wiki lacks exact numbers

Cross-references in the format [[page-name]] are internal wiki links — ignore the brackets when reading. If wiki contradicts raw data, flag the contradiction rather than silently picking one.
```

> Implement in your project's language — the algorithm is ~30–50 lines in most stacks. No external dependencies beyond what the language provides for filesystem + regex.

---

### Scenario C — Both

Execute both Scenario A and Scenario B steps.
- Wiki lives at `.agents/wiki/` — one location serves both audiences (Claude Code and the product LLM).
- Both the Knowledge Layers row (Scenario A) and the runtime integration (Scenario B) point at the same `.agents/wiki/` tree.
- Only Scenario B adds the runtime integration code / algorithm.

---

## Step 5: Create wiki-operation commands (scenario-conditional)

Create the following commands under `.claude/commands/`. **Which commands you create depends on the scenario chosen in Question 2:**

| Command | Scenario A — Developer Wiki | Scenario B — Product Wiki | Scenario C — Both |
|---------|:---------------------------:|:-------------------------:|:-----------------:|
| `wiki-ingest.md` | ✅ | ✅ | ✅ |
| `wiki-query.md`  | ✅ | ❌ *(product LLM queries wiki at runtime via `readWikiContext()`)* | ✅ |
| `wiki-lint.md`   | ✅ | ✅ | ✅ |

> Every template below references `.agents/wiki/` — this path is fixed (see Question 4). Paste the templates verbatim.

---

### 5.1 `.claude/commands/wiki-ingest.md` — always created

```markdown
---
description: Ingest a new knowledge source into the project wiki
argument-hint: [source file path or URL]
---

# Wiki Ingest

Add new knowledge to the wiki from a source (file, article, patch notes, data update).

## Process

### 1. Orient
- Read `.agents/wiki/SCHEMA.md` — format and rules
- Read `.agents/wiki/index.md` — existing pages

### 2. Read the source
Read the file or URL provided by the user.

### 3. Discuss with user
- What are the key takeaways?
- Which existing wiki pages are affected?
- Does this need a new page, or updates to existing ones?

### 4. Create or update wiki pages
- New page: follow format from SCHEMA.md (frontmatter required)
- Existing page: update content, change `updated:` date in frontmatter
- Location: `.agents/wiki/concepts/`, `.agents/wiki/reference/`, or `.agents/wiki/meta/`

### 5. Update `.agents/wiki/index.md`
Add new page or update description of modified page.

### 6. Append to `.agents/wiki/log.md` (at top)
## [YYYY-MM-DD] ingest | {Source Name}
{What was added or changed. Which pages were touched.}

## Decision guide: new page vs. update

| Case | Action |
|------|--------|
| New topic not covered yet | New page in concepts/ |
| Updated stats/data | Update existing page, change `updated:` |
| New event/integration | New page in meta/ or section in existing |
| New factual reference | New page in reference/ |

## Validation
ls .agents/wiki/concepts/
ls .agents/wiki/index.md

## CRITICAL rules
- Never modify source files — the wiki is a derived artifact only.
- Never skip `index.md` update — every ingest must record an entry.
- Append-only log — do not rewrite or delete prior entries in `log.md`.
```

---

### 5.2 `.claude/commands/wiki-query.md` — Scenarios A and C only

Skip this file entirely for Scenario B.

```markdown
---
description: Answer a question using the project wiki as the source of truth
argument-hint: [question]
---

# Wiki Query

Answer a question using the project wiki — not guesses, not raw sources.

## Process

### 1. Orient
- Read `.agents/wiki/SCHEMA.md` — format and rules
- Read `.agents/wiki/index.md` — page catalog
- If either file is missing, STOP and tell the user: "No wiki found. Run `/createwikillm` first."

### 2. Find relevant pages
- Extract keywords from $ARGUMENTS (English base forms, per SCHEMA `keyword[]` rules)
- Scan page frontmatter across `.agents/wiki/concepts/`, `.agents/wiki/reference/`, `.agents/wiki/meta/`
- Match against each page's `keywords:` list — higher overlap = higher score
- Fallback: full-text match across page bodies if frontmatter scores are all zero

### 3. Read the matched pages
- Read the top 3–5 pages by score
- Dereference `[[page-name]]` cross-references when they point at content needed to answer

### 4. Synthesize the answer
- Answer using ONLY content from the read pages
- Cite every factual claim inline: `(wiki: filename.md)`
- If the wiki does not cover the question, say so **explicitly** — do NOT fill the gap from general knowledge or raw sources without asking

### 5. Offer to save
If the answer synthesizes something worth preserving for future queries:
> "This answer contains knowledge worth preserving. Save as a new wiki page? (yes/no)"

On "yes": hand off to `/wiki-ingest` (or inline-create a page following SCHEMA.md).

## CRITICAL rules
- Wiki is the source of truth. Do not silently fall back to outside knowledge.
- Every factual claim must be attributable to a wiki page.
- If wiki and raw sources disagree, flag the contradiction — do not pick a side unilaterally (that is `/wiki-lint`'s job).
```

---

### 5.3 `.claude/commands/wiki-lint.md` — always created

```markdown
---
description: Health check — scan the wiki for contradictions, stale data, and missing cross-references
---

# Wiki Lint

Scan the project wiki for health issues and report suggested fixes.

## When to run
- After a batch of ingests (rough guideline: every ~10 ingests).
- Before relying on the wiki for a significant decision.
- When you suspect contradictions between sources.

Lint does not need to run after every ingest — it is a periodic maintenance pass.

## Process

### 1. Orient
- Read `.agents/wiki/SCHEMA.md` — format and rules
- Read `.agents/wiki/index.md` — page catalog
- List every `.md` file under `.agents/wiki/concepts/`, `.agents/wiki/reference/`, `.agents/wiki/meta/`

### 2. Check each category

**Contradictions** (severity: critical)
- Find pages making conflicting claims about the same fact, stat, or procedure
- Cross-check overlapping topics

**Orphan pages** (severity: warning)
- Pages that exist on disk but are NOT listed in `index.md`
- Pages with no incoming `[[cross-links]]` from any other page

**Stale data** (severity: warning)
- Frontmatter `updated:` older than any file in the page's `sources:` list (source has changed since last synthesis)
- `updated:` older than 6 months without an explicit "stable content" marker

**Missing cross-references** (severity: warning)
- Pages that mention topics covered elsewhere in the wiki but do not link to them with `[[page-name]]`

**Schema violations** (severity: info)
- Missing required frontmatter (`title`, `keywords`, `sources`, `updated`)
- Fewer than 5 keywords
- Keywords not in English base form (e.g. `users` instead of `user`, `authentication` instead of `auth`)
- Missing `# Title`, `**Summary**`, `**Sources**`, `**Last updated**` lines

### 3. Report

Return a numbered list, sorted by severity (critical → warning → info):

\`\`\`
1. [critical] .agents/wiki/concepts/foo.md vs. .agents/wiki/concepts/bar.md
   — conflicting claim about X
   — suggested fix: reconcile in foo.md, link bar.md

2. [warning] .agents/wiki/concepts/baz.md
   — orphan page, not in index.md
   — suggested fix: add entry or delete page

3. [info] .agents/wiki/reference/qux.md
   — keyword "users" should be "user"
   — suggested fix: update frontmatter
\`\`\`

### 4. Offer to fix
After the report:
> "Apply the suggested fixes? (yes / selective / no)"

Do NOT auto-fix without explicit confirmation.

On confirmation, apply fixes one category at a time. Update `.agents/wiki/log.md` with a single entry:
\`\`\`
## [YYYY-MM-DD] lint | Fixed N issues — {brief summary}
\`\`\`

## CRITICAL rules
- Never delete wiki pages without confirmation — orphans may be intentional drafts.
- Never silently edit content during lint; lint reports, `/wiki-ingest` edits.
- If wiki and raw sources disagree, flag and surface both — do not resolve unilaterally.
```

---

## Step 6: Report what was created

After all files are written, output a summary. **Adjust the command list to match the scenario** (see Step 5 table).

```
## LLM Wiki created ✓

Scenario: {A/B/C} — {Developer/Product/Both}

### Files created
.agents/wiki/
  SCHEMA.md        — wiki spec and workflow
  index.md         — page catalog
  log.md           — operation log
  concepts/
    {topic1}.md
    {topic2}.md
    {topic3}.md
  [meta/, reference/ if applicable]

### Commands created
.claude/commands/wiki-ingest.md  — add new knowledge to the wiki
{If Scenario A or C:} .claude/commands/wiki-query.md   — answer questions using the wiki as source of truth
.claude/commands/wiki-lint.md    — periodic health check (run ~every 10 ingests)

### Next steps
{Scenario A}:
  - Use /wiki-ingest when you discover something worth capturing.
  - Use /wiki-query when you want an answer synthesized from the wiki (with citations).
  - Run /wiki-lint periodically.
{Scenario B}:
  - Wire readWikiContext() into your context builder. Paste the system prompt snippet.
  - Run /wiki-lint periodically — the product LLM handles queries at runtime via readWikiContext().
{Scenario C}: Both of the above.

### First ingest suggestion
Your raw sources are: {list from Q5}
Run /wiki-ingest and point me at the richest one to deepen the seed pages.
```

