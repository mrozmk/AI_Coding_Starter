<!-- STARTER-KIT-README: this is the starter's landing page. On bootstrap, /setup:create-CLAUDE_MD
     replaces it with a README for your project. The framework guide lives in .claude/docs/. -->

# AI Coding Starter

A complete, battle-tested workflow for building real software with Claude Code: from the first
requirement to reviewed, tested code. For one developer, or for several AI teams working for you.
Built for three kinds of users:

- **One-person army:** build any application from A to Z on your own, with the discipline of a full team.
- **Software houses:** deliver client projects end to end, from requirements and architecture to a
  Jira backlog and reviewed code.
- **Product companies:** maintain and extend the systems you already run, even on a very large
  existing codebase.

Works with GitHub, GitLab, Bitbucket and Azure DevOps, syncs with Jira and Confluence, and includes
a cross-model security audit of your code.

---

## This is not a vibe coding tool

Vibe coding means you open a chat, describe what you want, and the AI writes it. You ask for a fix, it writes more.
For a script or a weekend prototype, that is perfect.

For a real application it falls apart. Nobody wrote down what the product should do. There is no
architecture, so every feature invents its own. The AI forgets last week's decisions, grades its
own work, and commits whatever compiles. Three months in, nobody, human or AI, understands the
codebase.

## This starter builds software the way it should be built

Requirements first, then architecture, then a backlog of tasks, then each task through the same
proven path: design, plan, code, independent review, tests, commit. Every role on the project gets
its own commands:

| Role | What they do with it |
|---|---|
| Business analyst | Turn an idea or existing documents into a PRD, an architecture, and a backlog of tasks synced to Jira |
| Developer | Take one task and run it through the core flow, with a second model reviewing every step |
| QA | Verify each acceptance criterion with evidence, write end-to-end tests, run a security audit |
| Lead / operator | Scale up: run several AI teams on tickets in parallel and supervise them |

It works for any stack (backend, frontend, mobile, or all of them in one repo) and for any starting
point: an empty folder or an existing codebase of any size. It ships no application code, only
the `.claude/` and `.agents/` folders that shape how the AI works.

---

## Step 1 · Before any code: product, architecture, backlog

```text
/discover              interview or import your sources
/architect             bounded contexts, stack choice, decision records
/setup:create-backlog  epics and tasks with sizes, dependencies and acceptance criteria
/check-backlog         an independent critic grades the backlog before anyone builds from it
/jira sync             mirror the backlog into Jira epics and tasks
```

Each document is judged by an independent critic, not by the agent that wrote it. When scope
changes later, `/meeting-notes` and `/update-backlog` bring the PRD and the backlog up to date
without breaking work in progress.

Existing codebase? `/setup:map-codebase` reads it in parallel and writes an architecture map and
a reconstructed PRD, so the agent understands a large project before it changes a line.

## Step 2 · One developer, one task: the core flow

This is the heart of the starter, battle-tested on real projects. Pick a task from the backlog:

| Step | What it does for you |
|---|---|
| `/start-task PROJ-142` | **START** from the ticket: a fresh branch, the project context loaded, straight into `/brainstorm` |
| `/brainstorm` | **WHAT** to build. It takes the task from Jira, or from the in-repo backlog when there is no Jira, asks until the requirement is unambiguous, proposes approaches, and writes a spec that Codex then challenges |
| `/plan-feature` | **HOW** to build it. The approved spec becomes small steps, each with the files to touch, a test and a check, and then the plan is grilled for gaps |
| `/execute` | **BUILD** the plan step by step, checking each step against its expected result. No improvising |
| `/check-implementation` | **CHECK** it, and never by its own author: a bug hunt, a structural cleanup, your tests and linters, then an independent verifier compares the code with the plan. It loops until clean |
| `/commit` | **COMMIT** exactly the files that changed, with a clean conventional message |
| `/qa-verify PROJ-142` | **VERIFY** every acceptance criterion of the task with evidence, and get a signed verdict table |

Why a spec *and* a plan? The spec is the decision: what and why. It is reviewed while changing
it still costs a paragraph, not a rewrite. The plan is the execution: how, in what order, and how we
prove each step works. Merged into one document, the plan quietly rewrites the requirement.

What makes it different from "just ask the AI":

- A defined flow, not a conversation. You do not write prompts and hope. Every task runs through
  the same steps, with quality and security gates between them: your tests and linters before
  every commit, a secret scan before every push. A step that fails does not move on.
- Small tasks follow a flow too. A bug fix or a change in a few files is never "hey, fix this".
  `/quick-change` writes a short plan, has Codex review it before any code is written, then
  implements, reviews and runs your tests. If the change turns out bigger than it looked
  (sensitive code, a schema change, more than about five files), it sends you to the full flow.
- A second opinion from a different model. With the [Codex CLI](https://github.com/openai/codex)
  installed, OpenAI's model reviews the spec, the plan and the code. The one who fixes is never the
  one who judges.
- Memory that lives in the repo. Decisions, lessons and the project map are plain Markdown in
  `.agents/`. Every new session starts informed, not from zero.
- Safe by default. Guardrails are enforced by hooks and permission rules, not by asking the
  model nicely. Rewriting history and destructive git commands are blocked. Deleting files and
  branches, and every write to Jira or Confluence, waits for your approval. Secret files and keys
  cannot be edited, and tokens cannot appear in a command. Data cannot be uploaded anywhere with
  `curl` or `wget`. Every push is scanned for secrets, and every tool call lands in an audit log.
- A loop that keeps learning. After each task the agent records what it learned, and `/retro`
  turns a session into an evidence-based retrospective. The workflow is meant to be tailored:
  adjust the rules, the gates and the commands to your project, and it gets better with every
  task.

## Step 3 · QA: proof, not "looks good"

```text
/qa-verify PROJ-142    checks every acceptance criterion one by one, returns a signed verdict table
/test-e2e              writes end-to-end tests by driving a real browser
/audit-security        scanners plus two models hunting for attack paths, merged into one report
```

## Step 4 · Scale up: from developer to operator

Once the flow works for you, stop coding one task at a time. Each AI team is its own clone of
the repository, running the same proven pipeline on a ticket: planner → coder → QA → wrap-up. Run
two, three or more teams at once.

You no longer write the code. Supervision roles watch the teams for you: they answer routine
questions, merge work that passes the gates, and bring you only the decisions a human must make.
The rules are enforced by scripts, not by prompts.

```text
/setup:teams           install the team layer into your project
/start-team alfa PROJ-142   start team "alfa" on a ticket
/monitor               watch all teams: progress, questions, work ready to merge
```

Optional, and only when you need it. Details: [Parallel AI teams](docs/teams/README.md).

---

## What you need

- [Claude Code](https://claude.com/claude-code) (tested on 2.1.257), Git and [`jq`](https://jqlang.github.io/jq/).
- *Recommended:* the [Codex CLI](https://github.com/openai/codex) for cross-model review. Without it,
  everything works, just without the second opinion.
- *Optional:* Jira (through the Atlassian MCP server), Node.js for a few helper scripts.
- *For AI teams:* the Codex CLI, Python 3.9+ and tmux.

## Get started in 5 minutes

New project. Click Use this template on GitHub, or:

```bash
gh repo create my-app --template mrozmk/AI_Coding_Starter --private --clone
cd my-app && claude
```

Then, inside Claude Code:

```text
/setup:start
```

> New to this? The [tutorial](docs/TUTORIAL.md) walks through a whole project, from an empty
> folder to the first commit.

---

## Documentation

| Read | When |
|---|---|
| [Tutorial](docs/TUTORIAL.md) | First time: a full project walkthrough |
| [Framework guide](.claude/docs/guide.md) | How to use every command, the daily flows, configuration, permissions |
| [Parallel AI teams](docs/teams/README.md) | Scaling up: several AI teams working on tickets at once |
| [`CLAUDE.md`](CLAUDE.md) · [`AGENTS.md`](AGENTS.md) | The rules Claude and Codex follow in this repo |

## License

[MIT](LICENSE)
