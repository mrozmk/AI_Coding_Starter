# Step 1 — Memory scope + rule rehoming

**Parent:** [context-layer-claude5.md](./context-layer-claude5.md)
**Status:** pending
**Complexity:** easy
**Blocker:** none — this step runs first
**Pre-read:** the parent umbrella; `.agents/specs/2026-07-26-context-layer-claude5.md` → *Files*

## Goal

Establish the memory-scope rule and give the two rules being evicted from `CLAUDE.md` a real home,
**before** Step 2 cuts the file that points at them. This is the only ordering constraint in the
feature.

---

## Tasks

### UPDATE `.agents/memory/index.md` — add `## Memory scope`

- **IMPLEMENT**: A new top-level section stating that `.agents/memory/` is the only memory surface
  for this project, and that the native per-user memory directory must not be written to — knowledge
  outside the repo is invisible to the team, to CI, and to any other tooling.
- **PLACEMENT**: Immediately after `## Quick Reference` (ends line 21, before `## When to Read` at
  line 23). It belongs beside the "where to write" table, not buried at the end.
- **PATTERN**: Match the file's voice — a short rule, then a `>` blockquote carrying the why. See
  `index.md:44–66` (`Loader Convention`) for the shape.
- **GOTCHA**: It **must** be a distinct `## Memory scope` heading, never a row appended to
  `Quick Reference`. `starter-sync-playbook.md:58` merges this file by taking the starter's
  *structure* and restoring project-specific *rows* — a row can be dropped as project-specific; a
  section is carried as starter structure. This is what makes the rule reach existing projects.
- **NOTE**: `index.md` is now 132 lines (it was 190 when this plan was written — `reflection-protocol.md`
  was extracted out of it by merge `d869d42`). The placement anchors above are unaffected: they name
  sections, not offsets.
- **VALIDATE**: `rg -n '^## Memory scope' .agents/memory/index.md` → 1 hit

### UPDATE `.claude/commands/setup/create-backlog.md` — absorb the backlog rule

- **IMPLEMENT**: The rule evicted from `CLAUDE.md`: `.agents/backlog.md` is the single source of
  truth for delivery order; Jira, when a team uses it, is a one-way mirror derived from the backlog
  via `/jira bulk`, never a parallel list maintained in reverse.
- **PLACEMENT**: Near the existing DAG source-of-truth prose at line 118, or as a short section
  before the output format — wherever it reads as a rule about the artifact this command produces.
- **GOTCHA**: The rule cannot go to `.agents/memory/decisions.md` — that file is a deliberately
  pristine template (reset in commit `35b23ae`) and the starter ships it empty by contract.
- **VALIDATE** — must test the *new* semantics, not a phrase the file already contains. A bare
  `rg 'source of truth'` passes **before** you write anything (`create-backlog.md:118,205` already
  say it about the DAG). Use:
  ```bash
  rg -n 'backlog\.md.*(delivery order|single source)|one-way|/jira bulk' \
     .claude/commands/setup/create-backlog.md
  ```
  → must hit the newly added rule, naming the backlog file, the one-way direction, and `/jira bulk`.

### UPDATE `.claude/skills/jira/SKILL.md` — absorb the direction rule, **scoped**

- **IMPLEMENT**: State that *when* `.agents/backlog.md` exists, delivery order mirrors one-way from
  it to Jira via `/jira bulk` (a manual/assisted export, no automatic sync), and that backlog
  ordering is never reconstructed from Jira.
- **GOTCHA — scope it, do not write a global invariant.** An unqualified "issues are derived from the
  backlog" reads as forbidding legitimate direct Jira work. The backlog is **optional**
  (`CLAUDE.md:150`), and this skill's standalone create / update / search / comment / link /
  transition flows (`SKILL.md:76–262`) must keep working in projects that never created one. Scope
  the rule to delivery-order mirroring, conditional on the backlog existing.
- **PLACEMENT**: Near the top, after `# Jira skill` (line 10) and before `## Step 1 — Environment
  preflight` (line 35).
- **VALIDATE** — `rg -n 'backlog'` is too weak; it cannot tell a correctly scoped rule from the
  unscoped one this task exists to avoid. Use:
  ```bash
  # the rule must be CONDITIONAL on the backlog existing, and about delivery order
  rg -n 'when .*backlog\.md exists|if .*backlog\.md|delivery order' .claude/skills/jira/SKILL.md
  # and must NOT restrict the standalone flows
  rg -n 'only.*from the backlog|must be derived from' .claude/skills/jira/SKILL.md   # EXPECT: no output
  ```
  Then read the added paragraph once by eye: a project with no backlog must still be able to run
  every flow at `SKILL.md:76–262`.

---

## Definition of Done

- [ ] `.agents/memory/index.md` carries a distinct `## Memory scope` section placed after
      `Quick Reference`
- [ ] `create-backlog.md` states the backlog-is-source-of-truth rule
- [ ] `jira/SKILL.md` states the one-way rule **conditioned on the backlog existing**, and none of
      its standalone flows are restricted
- [ ] All three `VALIDATE` commands run and pass

## Commit

`docs(memory): settle memory scope and rehome the backlog→Jira rule`

Body: name the two rules moved out of `CLAUDE.md` and why `.agents/memory/` stays the canonical
memory surface (committed, reviewable, portable — the native per-user directory is none of those).
