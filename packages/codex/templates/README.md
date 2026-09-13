# {project-name}

{description}

## Getting started

The project's rules live in `CLAUDE.md` (or `.agents/project-rules.md` when the project is greenfield) —
read them before touching anything. In an AI session, start with the `prime` skill of the installed
`harness` plugin: it loads the memory routing, the project brief and the architecture map, and reports
exactly what was read.

## Working with the harness

Design before building: `brainstorm` writes a spec and gets one independent cross-model review;
`plan-feature` turns the approved spec into an implementation plan with EXPECT/VALIDATE tasks.
`execute` implements that plan and runs the project's validation gates; `check-implementation`,
`commit` and `push` close the loop. Small changes go through `quick-change` instead.

---

<sub>The framework guide that shipped with the starter now lives at `.claude/README.md`; the starter's
license notice is at `.claude/STARTER-LICENSE`.</sub>
