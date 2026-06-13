---
name: handoff
description: Compact the current conversation into a handoff document so a fresh session (or another agent) can pick the work up without context loss. Writes a markdown file to .agents/handoffs/ (gitignored — a local session scratchpad). Run it at a session boundary, before /clear, or when context is getting long. Optional argument describes what the next session will focus on.
argument-hint: [what the next session will focus on]
---

# /handoff — Session Handoff Document

Write a handoff document that summarizes the current conversation so a fresh agent can continue the work without re-deriving context. The goal is **transfer, not archive**: capture the live state of the work and the next move, not a full transcript.

## When to run

- At a session boundary, before `/clear`, or when the conversation is getting long.
- When passing work to another window / agent / teammate.
- This is a manual end-of-session tool — not part of the automated pipeline.

## Where it writes

Save to **`.agents/handoffs/handoff-YYYY-MM-DD-<short-kebab-topic>.md`** (the date and a 2-4 word topic from `$ARGUMENTS` or the work in progress). This directory is gitignored — handoffs are a local scratchpad, not versioned repo content. Do **not** write to the project's tracked files. Do **not** write to `/tmp` (it is wiped on restart and the handoff would be lost between sessions).

If a handoff for the same day+topic already exists, append a new `## Update <time>` section rather than overwriting.

## What goes in the document

Use this structure. Keep it scannable — bullets over prose. Omit a section if it's genuinely empty (don't pad).

```markdown
# Handoff: <topic>

**Date:** YYYY-MM-DD · **Next session focus:** <from $ARGUMENTS, or "open">

## Where we are
- 2-5 bullets: what was being worked on and the current state (done / in-progress / blocked).

## What's done
- Shipped/committed work this session — reference commits by SHA, plans by path, NOT re-explained.

## In progress / next step
- The immediate next action a fresh agent should take. Be concrete: "edit X to do Y", not "continue work".
- Any decision the user already made that constrains the next step.

## Open questions / blockers
- Anything waiting on a user decision or an external dependency. Mark what's blocking what.

## Key context the next agent needs
- Non-obvious facts, gotchas, or constraints discovered this session that aren't yet in `.agents/memory/` or `CLAUDE.md`. (If it's durable, also consider `/remember` instead.)

## Artifacts (links, not copies)
- Plans: `.agents/plans/active/<file>.md`
- Specs: `.agents/specs/<file>.md`
- Commits: `<sha>` — one-line subject
- Reference docs / PRD sections by path or URL.

## Suggested skills for the next session
- Name the slash-commands the next agent should reach for, with why. E.g. "`/execute .agents/plans/active/foo.md` — resume the plan", "`/prime` first if starting cold", "`/check-implementation` before commit".
```

## Rules

- **Reference, don't duplicate.** Plans, specs, PRDs, ADRs, commits, diffs already exist — link them by path/SHA/URL. The handoff points to them; it doesn't re-paste them.
- **Redact secrets.** Never write API keys, tokens, passwords, connection strings, or PII into the handoff — even if they appeared in the conversation. Replace with `<redacted>`.
- **Tailor to `$ARGUMENTS`.** If the user described what the next session is for, slant "next step" and "suggested skills" toward that goal.
- **Transfer, not transcript.** Summarize decisions and state, not the back-and-forth. A fresh agent should be able to act from this doc + the linked artifacts alone.
- **Report the path** you wrote to, so the user can hand it off (e.g. paste it into the next session, or point the next agent at it).
