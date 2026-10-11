# Sync pattern — `.agents/backlog.md` → Jira (create-only)

Flow for `/jira sync`: mirror the backlog's Epics and Tasks into Jira, **create-only**, writing the
returned keys back into the backlog's `Jira` cells. Invoked when the primary skill sees subcommand
`sync` (Flow H).

The backlog is the planning source of truth; Jira is a mirror of it. Nothing about ordering,
structure, sizes or dependencies is ever read back from Jira by this flow. Status *is* read back —
but by `/brainstorm` Step 0 a′, not here (see **Status is not this flow's job**).

Transport note, non-negotiable: this flow creates issues **sequentially** with `jira_create_issue`.
Do **not** reach for the batch-create tool or a `validate_only` dry-run here — see
[Why sequential creates](#why-sequential-creates).

---

## Input

- **`.agents/backlog.md`** — required. Missing → stop: `"Brak .agents/backlog.md — uruchom najpierw /setup:create-backlog."`
- **Validate it before reading anything into a payload:**

  ```bash
  node .claude/lib/backlog-check.mjs
  ```

  Non-zero exit → **STOP** and print the errors verbatim. Never mirror an invalid backlog: a broken
  DAG or a duplicated id would become permanent Jira issues. Warnings do not block — quote them and
  continue.
- **`**Jira namespace:**`** — the kebab slug in the backlog header, written by
  `/setup:create-backlog`. Required. Absent → stop: `"Nagłówek backlogu nie ma **Jira namespace:** — dodaj go i uruchom node .claude/lib/backlog-check.mjs --write."`
  The sync refuses to run without it, because the namespace is what makes the correlation labels
  collision-free.
- **Legacy backlog** (a `## Work packages` heading, or a Task table without a `Jira` column) → stop:
  `"Legacy backlog — brak kolumny Jira. Przegeneruj przez /setup:create-backlog."`
- **`project_key`** — per HARD-GATE invariant 2: from the user's argument, else
  `$JIRA_DEFAULT_PROJECT`, else ask. Never guessed from an existing issue key in the file.

### Correlation label

Every issue this flow creates carries the label `<namespace>:<row id>` — e.g. `shopwise:E1-2` for a
Task, `shopwise:E1` for an Epic. **Never the bare row id**: two backlogs mirrored into one Jira
project would otherwise collide on `E1-2`. This label is the correlation id for recovery (Step 0)
and for post-create verification (Step 6).

---

## Flow

### Step 0 — Recover (every run, before planning)

A previous run may have crashed between `jira_create_issue` returning and the cell being written.
Reconcile before planning anything new, or the sync creates duplicates.

a. **Re-verify flagged cells.** Every cell holding `KEY (unverified)` goes through the Step 6
   verification again (a Task's estimate check needs the Step 2 target — resolve it first when any
   cell is flagged). It becomes `KEY` on success, or stays `KEY (unverified)` with the missing
   field reported. Never recreate and never delete — the issue exists.

b. **Adopt orphans.** For each row whose `Jira` cell is `—`:

   ```
   jira_search(
       jql='project = <P> AND labels = "<namespace>:<row id>"',
       fields="summary,issuetype,labels,parent",
       limit=50
   )
   ```

   - **0 hits** → nothing exists yet; the row goes into the Step 1 plan.
   - **exactly 1 hit** → an interrupted earlier create. Adopt the key into the cell as
     `KEY (unverified)` and verify it per Step 6. The row is then **not** re-created.
   - **>1 hit** → **stop the whole sync** and list the keys. Two issues share one correlation label;
     only a human can decide which is the real one. Never pick.

   Batch the rows to keep the call count sane — one `jira_search` with
   `labels in ("<ns>:E1-1","<ns>:E1-2", …)` per ≤50 rows, paging with `start_at` by 50 until every
   label is covered. Never trim the row list to fit one page.

### Step 1 — Plan what to create

Read the Epic map and the Task table. Two groups, in this order (a Task's parent must exist first):

1. **Epics** whose `Jira` cell is `—` after Step 0.
2. **Tasks** whose `Jira` cell is `—` after Step 0.

Rows that already carry a key — from this or any earlier run — are **skipped**, and listed as
skipped in the report. A row whose `Task` cell contains `(withdrawn)` is never created.

A Task whose Epic has no key yet is created in the same run, after its Epic (the Epic's fresh key
becomes the Task's `parent`). If the Epic's create failed, its Tasks are **deferred to the next
run**, not created parentless — HARD-GATE invariant 2 forbids a free-floating Task.

### Step 2 — Resolve the estimate target

Sizes are a currency: `M` = 4, `H` = 8, `XH` = 16 points (umbrella D6).

| Condition | Target |
|---|---|
| `$JIRA_ESTIMATE_FIELD` set | that custom field, with the **points** value — `'{"<field id>": 8}'` |
| unset | `'{"timetracking": {"originalEstimate": "8h"}}'` — the points value as hours |

The points-as-hours mapping is deliberate and stated to the user in the confirm step: `H` → `8h`.
It is a mirror of the size currency, not a time estimate.

If Step 4 shows the target is not on the create screen — or a create rejects it — **ask, never
silently drop**:

```
jira_search_fields(keyword="story points")
```

Offer the matching field ids plus an explicit **"bez estymaty"** option. The user's choice holds for
the rest of the run; an unanswered question stops the sync. Capture the chosen field id to
`.agents/memory/domain/jira.md` so the next run skips the probe.

### Step 3 — Build the payloads

**Epic** (one per Epic-map row):

| Field | Value |
|---|---|
| `issue_type` | `Epic` |
| `summary` | `E<n> <Title>` — e.g. `E1 Checkout` |
| `description` | Epic template (`description-templates.md`): `## Outcome`, `## Key assumption`, appetite / cut-first, the Task list |
| `additional_fields` | `'{"labels": ["<namespace>:E<n>", …$JIRA_DEFAULT_LABELS]}'` |

**Task** (one per Task-table row):

| Field | Value |
|---|---|
| `issue_type` | `Task` |
| `summary` | the `Task` cell verbatim |
| `description` | **Story** template for `Type: story`, **Tech** for `Type: tech` (`description-templates.md`) — carrying the row's `## Acceptance criteria` ids **verbatim** (`E1-2.AC1`), `## Traces`, `## Size` (`H (8 pts)`), `## Node`, `## Depends on` with the **local** ids |
| `additional_fields` | `'{"parent": "<EPIC-KEY>", "labels": ["story"\|"tech", "<namespace>:E<n>-<m>", …$JIRA_DEFAULT_LABELS], <estimate from Step 2>}'` |

Labels are **merged**, never replaced: the type label, the correlation label, and whatever
`$JIRA_DEFAULT_LABELS` carries. AC ids are copied character-for-character — `/qa-verify` joins its
verdicts on them, so a reworded id breaks the join silently.

`Depends on` stays as local ids in the description. The real Jira links are Step 7.

### Step 4 — Metadata check (there is no Jira-side dry-run)

Prove the fields exist on the create screen **before** creating anything:

1. Resolve the `Epic` and `Task` issue-type ids: `jira_get_project_issue_types(project_key="<P>")`.
2. Once per issue type:

   ```
   jira_get_create_fields(project_key="<P>", issue_type_id="<id>")
   ```

3. Confirm the fields the payloads use are present: `parent` (Tasks), `labels`, and the Step 2
   estimate target (`timetracking` or `$JIRA_ESTIMATE_FIELD`).

A missing field is **named to the user** with its options — Step 2's "pick another field / bez
estymaty" for the estimate, the `{"epic_link": …}` fallback for `parent`, dropping the labels is
**not** offered (the correlation label is load-bearing for recovery; without it the sync stops).
Never create blind on a screen you could not read: if `jira_get_create_fields` itself errors, say so
and ask whether to proceed with the documented shapes — the user's `y` is then the record of that
risk.

### Step 5 — Confirm (HARD-GATE invariant 1)

Per Epic group, in groups of **≤20 rows** (a larger group is split into consecutive groups of ten,
each confirmed on its own — nothing is dropped, only chunked), print:

- the field table — `Type · Summary · Parent · Labels · Estimate`
- **every rendered description, verbatim and whole** — not section names, not "as discussed", not
  the first Task as a sample. This is the invariant that binds hardest here, because a sync prints a
  lot of markdown.

```
Tworzę <N> issues dla E1 "<Epic title>" w projekcie <P>:

| # | Type | Summary | Parent | Labels | Estimate |
|---|------|---------|--------|--------|----------|
| 1 | Epic | E1 Checkout | — | shopwise:E1 | — |
| 2 | Task | Cart totals | <E1 key> | tech, shopwise:E1-2 | 8h |

Opisy:
<the entire rendered markdown of every row, verbatim>

Tworzę? [y/n/edit]
```

`n` → abort, nothing created. `edit` → apply the corrections, **re-print the whole draft**, re-ask.
`y` → Step 6 for that group only; the next group gets its own confirm.

### Step 6 — Create sequentially, verify, write back immediately

For each confirmed row, in order (Epics before their Tasks):

1. ```
   jira_create_issue(
       project_key="<P>",
       summary="…",
       issue_type="Task",
       description="<markdown>",
       components="<$JIRA_DEFAULT_COMPONENTS or omitted>",
       additional_fields='{"parent": "<EPIC-KEY>", "labels": [...], "timetracking": {"originalEstimate": "8h"}}'
   )
   ```

2. **Write the returned key into the row's `Jira` cell immediately**, as `KEY (unverified)` —
   before the verification read, before the next create. A crash one row later must not orphan the
   issue it just created.

3. Verify what Jira actually stored:

   ```
   jira_get_issue(key, fields="parent,labels,issuetype,timetracking,<estimate field>")
   ```

   - **Epic** — `issuetype` is `Epic` and the correlation label is present.
   - **Task** — `parent` equals the Epic's key, the correlation label is present, the estimate holds
     the expected value.

4. All checks pass → the cell becomes the bare `KEY`. Any mismatch, or a failed read → the cell
   **stays** `KEY (unverified)` and the report names exactly which field is missing. The issue is
   never deleted and never recreated; the next run's Step 0 a re-verifies it.

**Consumers of the cell** read the leading `[A-Z]+-\d+` token as the key: `backlog-check.mjs` and
`/brainstorm` Step 0 treat `KEY (unverified)` as a key — the suffix flags *our* verification state,
not the issue's existence.

On a 4xx: stop that row, show the raw error, **no automatic retry** (the documented one-shot
fallbacks are the exception: `{"parent": …}` → nested `{"parent": {"key": …}}` → `{"epic_link": …}`).
The remaining rows continue only after the user says so; already-created issues stay in Jira — there
is no rollback.

### Step 7 — Links (reconcile, every run)

Independent of what this run created, so a rerun after a partial failure completes the links.

For every `Depends on` pair where **both** Tasks now have Jira keys:

1. Read the dependent's existing links:

   ```
   jira_get_issue(key, fields="issuelinks")
   ```

2. Drop pairs already linked. Only the **missing** links are proposed.
3. Resolve the link type name once per session via `jira_get_link_types` (names vary per instance —
   "Blocks" is the usual one; no match → ask, never invent).
4. One confirm table for all of them:

   ```
   Tworzę <N> linków Blocks:

   | Dependency (inward, "blocks") | Dependent (outward, "is blocked by") |
   |-------------------------------|--------------------------------------|
   | <E1-1 key>  (E1-1)            | <E1-2 key>  (E1-2)                   |

   Tworzę? [y/n]
   ```

   Direction, per Flow F: *A blocks B* → `inward_issue_key` = A (the dependency, the blocker),
   `outward_issue_key` = B (the dependent). `E1-2 depends on E1-1` therefore means
   inward = `E1-1`'s key, outward = `E1-2`'s key. (mcp-atlassian passes the two keys straight
   through as REST `inwardIssue` / `outwardIssue`; Jira renders `inwardIssue=A, outwardIssue=B`
   with type Blocks as "A blocks B".)

5. On `y`, create the links **one at a time** and verify the first one before the rest:

   ```
   jira_create_issue_link(
       link_type="Blocks",
       inward_issue_key="<dependency key>",
       outward_issue_key="<dependent key>"
   )
   ```

   After the **first** link: `jira_get_issue(<dependent key>, fields="issuelinks")` and confirm
   the dependency's key appears under the `inward` phrase of the type (`"is blocked by"`). If it
   shows under `"blocks"` instead, the instance reads the direction the other way: **stop creating
   links**, report the mismatch (both keys, the link as created) and leave the fix to the user —
   never auto-flip or delete an existing link. Only when the first link reads correctly are the
   remaining links created.

A pair where one side has no key yet is **reported as deferred**, not linked and not silently
skipped.

### Step 8 — Report

```
## /jira sync

**Utworzone:**
- E1 → PROJ-240 — $JIRA_URL/browse/PROJ-240
- E1-2 → PROJ-241 — $JIRA_URL/browse/PROJ-241

**Zweryfikowane:** 7/8 · **Oflagowane `(unverified)`:** PROJ-245 (brak parent)
**Adoptowane w Step 0:** E1-3 → PROJ-239 (label match)
**Linki:** 1 utworzony · 2 już istniały · 1 odroczony (E2-1 bez klucza)
**Pominięte (miały już klucz):** E0-1, E0-2
**Błędy:**
- E2-4: 400 — "<raw error body>"
```

Every number above is a count of rows, and the three "not created" buckets (skipped / deferred /
failed) are always printed, `0` included — a sync that silently omits a row is the failure mode this
report exists to catch.

---

## Invariants (enforced)

- **Create-only.** This flow never updates, transitions, deletes or comments on an existing issue.
  A row that already has a key is skipped, full stop — even when the backlog's text has since
  changed (fix that by hand, or via `/jira update`).
- **Idempotent** by the `Jira` cell (filled → skip) plus the Step 0 correlation-label recovery.
  A rerun after any failure is always safe.
- **Never confirm-free.** Step 5's `y` per group and Step 7's `y` for links are mandatory, every run
  — a previous run's approval is not reusable (HARD-GATE invariant 1).
- **Key written back immediately** after each create, before the verification read.
- **Never reads ordering, structure, sizes or dependencies back from Jira.** The backlog is the
  source of truth for all of them.
- **Writes only `Jira` cells** in `.agents/backlog.md`. Never `Status`, never `Ref`, never the table
  structure, never the generated `storymap` / `lanes` regions.
- **No auto-retry on 4xx; no rollback.**
- **No sub-tasks** (HARD-GATE invariant 3) — Epics and Tasks only.

### Status is not this flow's job

Umbrella D7: a Task with a `Jira` key takes its `Status` from Jira. That refresh lives in
`/brainstorm` Step 0 a′, is **read-only**, and owns the status → `TODO`/`WIP`/`DONE` mapping (defined
there, once). `/jira sync` neither reads nor writes `Status`, and never transitions an issue.

### Why sequential creates

The batch-create tool drops `parent` and `additional_fields`, and its `validate_only=true` never
asks Jira (evidence: `.agents/reference/jira-mcp-atlassian.md` → Known transport limits). A batch
would therefore create Tasks with no parent, no labels and no estimate while "validating" clean — and
the missing correlation label would make Step 0 recovery impossible. `jira_create_issue`'s
`additional_fields` JSON string is the documented path for `parent`, labels and custom fields, so the
sync pays N calls for correctness. That is also why there is no Jira-side dry-run here; Step 4 +
Step 5 replace it.

---

## Edge cases

- **Re-run after a complete sync** — every cell filled → nothing created, Step 7 finds every link
  present, the report is all-skipped. That is the expected steady state, not a no-op worth hiding.
- **Partial failure mid-group** — created rows keep their keys in the backlog; the failed row and
  everything after it stay `—`. The next run picks them up; Step 0 b adopts anything that was
  created but never written back.
- **Interrupted between create and write-back** — exactly the case Step 0 b exists for: the label
  search finds the orphan and adopts it. This only works because *every* create sets the
  correlation label.
- **Two backlogs in one Jira project** — distinct `**Jira namespace:**` values keep the correlation
  labels disjoint. Identical namespaces are a human error the sync cannot detect; it surfaces as the
  `>1 hit` stop in Step 0 b.
- **Row id reused after a manual backlog edit** — Step 0 b adopts the old issue for the new row.
  Ids are append-only for exactly this reason (`create-backlog.md` → Maintenance contract).
- **Epic exists in Jira but its key was never written back and its label is missing** (created by
  hand, or by `/jira bulk`) → Step 0 cannot find it and Step 1 plans a duplicate. The confirm table
  is the guard: it lists the Epic summary, so the user sees the duplicate and pastes the real key
  into the `Jira` cell instead of confirming.
- **`>20` rows in one Epic group** → split into consecutive groups of ten, each with its own full
  confirm. The cap chunks the confirmation; it never reduces what gets created.
- **More than 50 keys / labels to query** in Step 0 or Step 7 → page with `start_at` by 50 until
  every row is covered. Never truncate the row set to one page.
- **Estimate target absent instance-wide** (time tracking disabled, no points field) → Step 2's
  explicit "bez estymaty" choice, recorded in the report. Sizes still live in the description's
  `## Size` section, so nothing is lost.
- **Cut-first fallback** — if the estimate or the links cannot be made to work at all, the sync's
  irreducible core is *create + key write-back*. Say which part was dropped; never drop it quietly.
