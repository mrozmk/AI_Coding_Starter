---
description: Explain how a piece of code works
argument-hint: [file, function, concept, or area to explain]
---

# /explain - Code Explanation

Provide a clear, accurate explanation of how something works in this codebase.
Adapt depth to the complexity of what's being explained.

---

## Input

`$ARGUMENTS` — what to explain. Can be:
- A file path: `/explain src/{module}/file.{ext}`
- A function or class name: `/explain SomeService`
- A concept or flow: `/explain how authentication works`
- A directory: `/explain src/{module}/`
- Empty: explain the overall architecture based on current context

---

## Phase 1: LOCATE

Find the relevant code:
- If a specific file is given — read it directly
- If a function/class name is given — search for it across the codebase
- If a concept is given — identify the key files involved in that flow
- If empty — use already-loaded context from `/prime` or read `CLAUDE.md` + entry points

---

## Phase 2: TRACE

Understand the code deeply before explaining:
- Follow the execution path from entry to exit
- Identify dependencies, inputs, outputs, and side effects
- Note any non-obvious decisions or patterns
- Check `.agents/memory/` for any recorded context about this area

---

## Phase 3: EXPLAIN

Structure the explanation based on complexity:

**For a single function or small file:**
- What it does (one sentence)
- How it works (step by step)
- Key edge cases or gotchas
- Example input/output if helpful

**For a module or feature:**
- Purpose and responsibility
- How it fits into the overall architecture
- Key files and their roles
- Data flow (what comes in, what goes out, what changes)
- Dependencies on other modules

**For a concept or flow (e.g. "how auth works"):**
- High-level overview first
- Step-by-step walkthrough with file references
- Where state lives and how it changes
- Error paths and edge cases

---

## Guidelines

- Use plain language — avoid jargon unless it's established in the codebase
- Reference actual file paths and function names, not abstractions
- If something is non-obvious or surprising — call it out explicitly
- If the code has a known issue or gotcha recorded in memory — mention it
- Keep it scannable: use headers, bullet points, and short paragraphs
- Do not explain what is already obvious from reading the code
