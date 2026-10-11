<!-- TUTORIAL — beginner-first guide for the AI Coding Starter.
     Developer-facing manual. Code/commands stay in English.
     Add new scenarios below the divider following the SAME step rhythm as Scenario 1. -->

# 🚀 Tutorial


This template is a **toolkit** that turns Claude Code into your partner for building applications — it remembers the project, plans, codes, checks quality, and commits.

---

## 🚦 Which case is yours?

Pick the row that fits you best and click the scenario.

| Your situation | Scenario |
|----------------|-----------|
| I'm starting a **new project**, it will be **backend only** | 👉 **[Scenario 1: New backend project](#scenario-1-new-backend-project)** |
| I'm starting a **new project** with **backend and frontend** (there's a user interface) | 👉 **[Scenario 2: New project with a frontend](#scenario-2-new-project-with-a-frontend)** |
| **I already have designs** (HTML / Figma files) and I want to implement them | 👉 **[Scenario 3: I already have designs](#scenario-3-i-already-have-designs-htmlfigma)** |
| I want to **bring this workflow into an EXISTING project** (code already exists) | 👉 **[Scenario 4: Existing project (brownfield)](#scenario-4-existing-project-brownfield)** |
| I'm a **business analyst (BA)** — I want to create tasks in Jira | 👉 **[Scenario 5: Analyst path (BA → Jira)](#scenario-5-analyst-path-ba--jira)** |

---

## 📖 How to read this tutorial

Every step always follows the same, repeatable rhythm. Look for these four icons:

- 📋 **Type** — copy this exactly into Claude Code
- 💬 **What happens** — what to expect from this command
- ✅ **How you know it's OK** — how to verify the step succeeded before moving on
- ⏭️ **Next** — what to do next



---

# Scenario 1: New backend project

**What we'll build:** a tiny to-do list (TODO) API — a backend that lets you add tasks and check them off as done. No screen, no design. Perfect for the first time.

**What you'll learn:** the full work rhythm of this template — from idea to committed code.



---

## Before you start (one-time)

> This tutorial assumes you already have **Claude Code** and **Git** installed. If not — see [README → Requirements](../README.md#requirements).

### Create your own repo from this template and download it

The easiest way — and right away with **your own repository on GitHub** (handy later when pushing code):

1. Go to **[github.com/mrozmk/AI_Coding_Starter](https://github.com/mrozmk/AI_Coding_Starter)** → click the green **"Use this template"** button → **"Create a new repository"**.
2. Give it a name (e.g. `my-todo-app`), choose private/public, **Create repository**.
3. Download your repo to disk — in the **terminal** paste (replace `your-login` with yours):
   ```bash
   git clone https://github.com/your-login/my-todo-app.git
   cd my-todo-app
   ```

💬 **What happens:** **your own repo** is created (a copy of the template with clean history), and `git clone` downloads it locally. Important: the remote repository is **wired up right away** (`origin`) — so in Step 11 a simple `/push` is enough, nothing to configure.

✅ **How you know it's OK:** in the `my-todo-app` folder you see the files `CLAUDE.md`, `README.md` and the folders `.claude/` and `.agents/`. The command `git remote get-url origin` shows your repo's URL.

⏭️ **Next:** Step 1 — let's start building.

<details>
<summary>💡 TIP — prefer no GitHub account? (plain git clone)</summary>

You can download the template without creating a repo on GitHub:
```bash
git clone https://github.com/mrozmk/AI_Coding_Starter my-todo-app
cd my-todo-app
rm -rf .git
git init
```
This gives you a fresh, local Git history — but **without** a remote repo. Then in Step 11, before your first `/push`, you'll need to manually create a repo and wire it up (`git remote add origin <url>`). All methods are described in [README → Quick start](../README.md#quick-start).
</details>

---

## The main part — building the TODO API

> Open a Claude Code session in this folder (run `claude` in the terminal).

> **First run `/setup:start`.** It asks seven short questions, prepares the config files, and prints the exact order of the steps below for your project — this tutorial explains each of them.

---

### Step 1: Describe what you want to build (discover)

**(optional) Drop your materials into `.agents/sources/`.** Already have notes, a brief, a conversation dump, a sketch, a PDF, a requirements list, etc.? Copy those files into the **`.agents/sources/`** folder. Claude will read them **automatically** during discovery — you don't need to do anything else, the mere fact that they're there is enough.

📋 **Type** into Claude Code — you can give just the command and answer the questions, OR describe the idea right away:
```
/prime
/discover
```
or with a description right away — Claude has something to start from:
```
/prime
/discover Build me a simple to-do list (TODO) API: add a task, list tasks, mark as done, delete. The user works through the API. No login and no UI.
```

💬 **What happens:** Claude first derives what it can from your description, everything in `.agents/sources/` and the repo, and shows a **coverage table** (what is clear, partial, missing). Then it asks **only about the gaps** — in short rounds of at most 5 questions, each with a **Recommended** answer first, so you can often just accept. For the TODO API the first round could look like this:

| Question | Recommended answer |
|---|---|
| What kind of project is this? | Greenfield product (derived from your description) |
| What number changes, from what to what, by when? | One person adds, lists, completes and deletes tasks through the API — working by the end of the week |
| How much time is it worth, and what is dropped first when it runs over? | A few evenings; polish goes first, the four operations stay |
| What will it deliberately **not** do? | No login, no UI, no sharing between users |
| Which one scenario must work end-to-end? | Add a task → see it in the list → mark it done |

Claude writes your answers back after every round, runs a short pre-mortem ("six months later this failed — why?"), and when the problem, the outcome, the appetite and the critical flow are clear it writes **two files**: `docs/discovery.md` (the questions and answers, flows, business rules, glossary, assumptions, open questions, risks) and `docs/PRD.md` (goals, requirements, non-functional requirements, scope). An independent critic then grades both, Claude fixes what it found, and — if `codex` is installed — a second model reviews them once.

✅ **How you know it's OK:** `docs/discovery.md` and `docs/PRD.md` exist; the PRD has goals (`G-1`, …), requirements (`R-1`, …) and a scope section whose "out" list contains login and UI; the discovery has a flow `FL-1` marked `**Critical:** yes`.

⏭️ **Next:** Step 2.

<details>
<summary>💡 TIP — what a PRD is and why the ids; what the sources folder is</summary>

A PRD (Product Requirements Document) describes **what** you're building and **why** — not how. It's the foundation everything else flows from: architecture, backlog, plan, code. Every statement carries a stable id (`G-1`, `R-3`, `NFR-1`, `FL-1`) that is never renumbered — the backlog tasks and the acceptance checks later point back to them, so you can always trace a task to the requirement it serves. We deliberately leave the architecture and the technology empty for now — `/architect` decides them in the next step.

Already have the requirements somewhere else (a spreadsheet, a list)? `/discover --import requirements.csv` turns every row into an id'd entry, quotes the original wording, and asks only about what the rows don't answer.

`.agents/sources/` is the project's **input layer** — you drop raw materials here (briefs, transcripts, sketches, PDFs), and commands like `/discover` treat them as input context. Claude **never** modifies them — they're your source material, read-only. Full description: [README → step 3](../README.md#3-define-the-product).
</details>

---

### Step 2: Decide the architecture and the technology (architect)

📋 **Type:**
```
/architect
```

💬 **What happens:** Claude reads `docs/PRD.md` + `docs/discovery.md`, sorts the parts of the product into **core / supporting / generic** (what makes it worth building, what it needs, what everyone has and you buy or reuse), decides each part on a fixed set of questions and records every decision as a row `AD-1`, `AD-2`, … Then it searches the web, proposes 2–3 technology sets that fit (with pros and cons) and asks you to approve the recommendation. It writes `docs/architecture.md` and `docs/map/system.yaml` (the same map in machine-readable form), and the PRD's architecture and stack sections become a short digest of it. The same independent critic (and Codex, if installed) checks the result.

> 💡 **You don't need to know any technology.** At this stage it's enough to read Claude's recommendation and accept it. For a simple TODO API expect one small part and something lightweight.

✅ **How you know it's OK:** `docs/architecture.md` exists with a `## Decisions` table (rows `AD-1`, …) and a chosen stack, `docs/map/system.yaml` exists, and Claude confirmed a pointer to each decision was appended to `.agents/memory/decisions.md`.

⏭️ **Next:** Step 3.

<details>
<summary>💡 TIP — why the architecture is a separate step</summary>

Choosing the structure and the technology is a decision worth making deliberately and **recording**, so future Claude sessions don't second-guess it. That's why `/architect` not only picks but also saves each decision with its rationale — the backlog tasks later point at the parts of `system.yaml` they touch. Need focused research on one area later? `/architect --stack realtime`. Stack-agnosticism is a feature of this template — the commands work the same regardless of whether you choose Node, Python, or anything else.

**Product with a lot of UI?** You can run `/design-ui` after `/architect` for the key screens of the critical flow — optional, never required.
</details>

---

### Step 3: Lay out the delivery plan (backlog)

📋 **Type:**
```
/maintain:refresh-brief
/prime
/setup:create-backlog
```

💬 **What happens:** `/maintain:refresh-brief` condenses the fresh PRD into the short brief that `/prime` loads, and `/prime` reloads the context. Then Claude reads the PRD, the discovery and the architecture and lays out a **delivery map** into `.agents/backlog.md` — "epics" and tasks (user stories or technical tasks), each with a size `M` / `H` / `XH` (4 / 8 / 16 points), in dependency order, with acceptance criteria that carry ids (`E1-2.AC1`). A small **Wave 0** foundation runs first, one task after another; after it the tasks are split into **parallel lanes for 2, 3 and 4 developers**, and a story map marks the **walking skeleton** — the thinnest set of tasks that makes the critical flow work end-to-end. **The first task is always `E0-1: project scaffold`** — the foundation everything else stands on. (The backlog only *describes* this task — it does not create files; the scaffold is built in Step 4, when you execute it.)

✅ **How you know it's OK:** a `.agents/backlog.md` file is created, and at the top of its table there's a task `E0-1` of type "project scaffold".

⏭️ **Next:** Step 4.

> 👥 **Working with a team on Jira?** The backlog is created first anyway — it's the **source of truth**. You mirror it into Jira **from it** (with `/jira sync`), not instead of it. How to do that — see **Scenario 5 (the analyst/BA path)** below. In Scenario 1 (solo) Jira isn't needed.

<details>
<summary>💡 TIP — why a backlog and why the scaffold is a task, not a manual step</summary>

The backlog is the **layer between the PRD and a single plan**: the PRD says *what and why* (prose), the backlog says *in what dependency structure to deliver it* (tasks with IDs, sizes, a DAG, ordering, parallel lanes). Thanks to this, the project scaffold isn't a "manual terminal hack" but the **first normal pipeline task** — it goes through the same quality gates as any other feature.

`.agents/backlog.md` is the **single source of truth** for "what to build, in what order".
</details>

---

### Step 4: Build the project scaffold (first pass through the pipeline)

> 🆕 **Here you go through the full work cycle for the first time:** `/prime` → `/brainstorm` → `/plan-feature` → `/execute`. You'll do it first on the **scaffold task** (`E0-1` from the backlog) — a light warm-up. Then (Step 6) you'll repeat the same cycle on a real feature. This rhythm is the heart of the whole workflow.

📋 **Type** (one after another, waiting for each command to finish):
```
/prime
/brainstorm
/plan-feature
/execute
```

💬 **What happens, in order:**
- `/prime` — Claude loads the project context (PRD, backlog, rules).
- `/brainstorm` — with no argument it **takes the first free task from the backlog itself** (i.e. `E0-1: project scaffold`), announces which one, and designs *how* it should look. It writes the spec into `.agents/specs/`.
- `/plan-feature` — lays out a step-by-step plan into `.agents/plans/active/`.
- `/execute` — **creates the actual scaffold files** (dependency manifest, server entry file, directory layout) and moves the plan to `.agents/plans/done/`.

✅ **How you know it's OK:** starter files appropriate for your stack appeared in the project (Claude will list them), and the plan moved from `active/` to `done/`. You have an "empty house" you'll furnish with the TODO feature in a moment.

⏭️ **Next:** Step 5.

> 💡 **Empty `/brainstorm` = "take the next task from the backlog".** When you don't provide a topic (and don't point to a Jira task), `/brainstorm` reaches into `backlog.md` itself, takes the first **free** task (status `TODO`, dependencies satisfied) and makes sure it really isn't already done. Thanks to this you don't have to retype task names — you just work "from the top of the backlog". Want a specific task? Provide a topic: `/brainstorm mark a task as done`.

> 💡 **Why is the scaffold a separate pass and not a manual command?** Because this way even the project's foundation goes through the normal, controlled pipeline — and you practice the whole rhythm on something simple before doing it on a real feature.

<details>
<summary>💡 TIP — what each of these four commands does</summary>

These are the four pillars of daily work:
- **`/prime`** — loads the project context at the start of a session (rules, map, PRD summary). Always the first command in a fresh chat.
- **`/brainstorm`** — a hard design gate: first *what and how*, only then code. Prevents writing something you'd have to throw away in a moment.
- **`/plan-feature`** — turns a spec into a concrete plan and "interrogates" it itself (self-critique) before writing anything.
- **`/execute`** — only now is code produced, strictly following the plan.

Each of them has a full description in the README: [Two daily flows](../README.md#two-daily-flows).
</details>

---

### Step 5: Create the project rules (CLAUDE.md)

> Now that the scaffold **already exists**, Claude has something to analyze. (If the repo were empty, this command would have nothing to read — that's why it's after Step 4, not before.)

📋 **Type** (one after another):
```
/setup:start --rerun
/setup:create-CLAUDE_MD
```

💬 **What happens:** `/setup:start --rerun` shows your earlier answers (keep them) and fills the two things it skipped at the start — the toolchain check in `.claude/hooks/check-project-deps.sh` and the LSP plugin declaration for your stack — now that a manifest (`package.json`, `pyproject.toml`, …) exists. It prints two install commands (the plugin and its language server) — run them, then `/reload-plugins`, so the next step can use symbol navigation. Then Claude analyzes your fresh scaffold and generates three things: a refined `CLAUDE.md` (project rules), `.agents/memory/architecture.md` (project map), and **a new `README.md` describing YOUR project** (the current framework guide moves to `.claude/README.md`).

✅ **How you know it's OK:** `CLAUDE.md` now has filled-in sections about your project (not `{...}` placeholders), and the root has a README about your TODO app.

⏭️ **Next:** Step 6 — the first real feature.

<details>
<summary>💡 TIP — what happened to the original README</summary>

On the first run of `/setup:create-CLAUDE_MD` the template performs a "swap": it moves its framework guide to `.claude/README.md` (it stays available), and creates your project's README at the root. This way your repo's page describes your app, not the template. This tutorial (`docs/TUTORIAL.md`) stays untouched. Details: [README → "The root README is yours"](../README.md#the-root-readme-is-yours--the-framework-guide-moves-aside).
</details>

---

### Step 6: Design the first feature (brainstorm)

> 🆕 **A second pass through the same cycle** — this time on the real TODO feature. Note: the steps are practically identical to Step 4. That's NOT a coincidence — `/brainstorm` → `/plan-feature` → `/execute` → `/check-implementation` → `/commit` is the rhythm you repeat for **every** feature for the rest of the project's life.

First refresh the context (a new chat window, then `/prime`):

📋 **Type:**
```
/prime
```
💬 **What happens:** Claude loads the project rules, the architecture map and the PRD summary. Now it "knows" what you're building — including the freshly created scaffold.

✅ **How you know it's OK:** Claude prints a short project summary without warnings about empty files.

Now design the feature:

📋 **Type:**
```
/brainstorm adding and displaying TODO tasks
```

💬 **What happens:** Claude analyzes the requirement, proposes 2–3 approaches, and writes a design document (spec) into `.agents/specs/`. **No code is produced yet at this stage** — it's a design gate before writing.

✅ **How you know it's OK:** a file appeared in `.agents/specs/` with a date and the topic name, and Claude described the chosen approach.

⏭️ **Next:** Step 7.

---

### Step 7: Make a detailed plan (plan-feature)

📋 **Type:**
```
/plan-feature
```

💬 **What happens:** Claude takes the latest spec, analyzes your code, and writes a **step-by-step plan** into `.agents/plans/active/`. Then it "interrogates" it itself (self-critique) to catch gaps before writing anything.

✅ **How you know it's OK:** there's a plan file in `.agents/plans/active/` (a list of concrete implementation steps), and Claude reported the plan is ready.

⏭️ **Next:** Step 8.

---

### Step 8: Write the code (execute)

📋 **Type:**
```
/execute
```

💬 **What happens:** Claude executes the plan top to bottom — it writes the real TODO API code. When it finishes, it moves the plan from `active/` to `done/`.

✅ **How you know it's OK:** code implementing the feature was produced, and the plan disappeared from `.agents/plans/active/` and appeared in `.agents/plans/done/`.

⏭️ **Next:** Step 9 — we check quality.

---

### Step 9: Check quality (check-implementation)

📋 **Type:**
```
/check-implementation
```

💬 **What happens:** Claude runs the full quality loop — it finds and **fixes** logic bugs, cleans up the code, and then runs everything through the gates (tests, lint, build). The loop repeats (up to 3 times) until everything passes. At the end it leaves a **clean, commit-ready** tree — but it **doesn't commit itself**.

✅ **How you know it's OK:** Claude reports that the gates accepted the changes ("DONE / APPROVE") and the code is ready to commit.

⏭️ **Next:** Step 10.

<details>
<summary>💡 TIP — how this differs from a plain check</summary>

There's also `/gates:verify-implementation` — but it only **reports** problems, it doesn't fix them. `/check-implementation` **fixes** (code-review --fix → deep-review → gate), in a loop. If you have `codex` installed, at the end a second, independent model reviews the code "fresh" — it often catches what the first model missed. It deliberately doesn't commit, so the last word is yours.
</details>

---

### Step 10: Save the changes (commit)

📋 **Type:**
```
/commit
```

💬 **What happens:** Claude creates a commit with a proper message (in conventional format, e.g. `feat: add TODO creation endpoint`) and, while at it, records any conclusions/decisions into the project's memory.

✅ **How you know it's OK:** `git log` shows your new commit; the working tree is clean.

⏭️ **Next:** Step 11 (optional) or the next feature.

---

### Step 11: Push to GitHub (optional)

If you downloaded the project via **"Use this template"** (the recommended method from the "Before you start" section), your remote repo is already wired up — just:

📋 **Type** (in Claude Code):
```
/push
```

💬 **What happens:** Claude pushes your commits to the remote repo (it first scans them for secrets — a built-in safeguard). You repeat this command after each `/commit` you want to publish.

✅ **How you know it's OK:** the push went through without errors; you refresh the repo page on GitHub and see your code.

> 🔌 **Did you download via plain `git clone` (the TIP variant)?** Then you don't have a remote repo yet. Once, before your first `/push`: create an empty repo on GitHub/GitLab, copy its URL and in the **terminal** paste `git remote add origin <url>`. (`git remote add` is deliberately blocked for Claude — you do it deliberately yourself.)

---

## 🎉 Congratulations — you've closed the full cycle!

You've just gone all the way: **idea → PRD → stack → design → plan → code → quality → commit**.

### What's next?

**Another feature?** Repeat **steps 6–10** for a new thing (e.g. "mark a task as done"). Fresh chat → `/prime` → `/brainstorm <feature>` → `/plan-feature` → `/execute` → `/check-implementation` → `/commit`. That's your daily rhythm — the same one you practiced twice (on the scaffold and on the first feature).

**Want it faster, without clicking through each step?** Once you're comfortable, you can replace steps 8–11 with **one** command:
```
/orchestrate
```
It does it all itself: write code → clean up → check → commit → push, looping fixes and asking you only on a real problem. That's the "hands-off" path. **I recommend it only once you understand what happens in steps 7–9 separately** — so you can react when something goes wrong.

> A full comparison of both paths (manual A and automatic B) and a description of exactly what each command does: [README → Two daily flows](../README.md#two-daily-flows).

---

# Scenario 2: New project with a frontend

**What we'll build:** the same TODO, but **with a screen** — backend (API) + frontend (the interface you click). The user adds tasks in the browser, not just through the API.

**What you'll learn:** the same rhythm as in Scenario 1 **plus** two new commands for the visual layer: **`/design-ui`** (UI design) and **`/test-e2e`** (browser tests).

> 📌 **This is an extension of Scenario 1, not a new scheme.** The rhythm `PRD → stack → backlog → prime → brainstorm → plan → execute → check → commit` is identical. Below I describe **only what's added or changes** — take the rest straight from Scenario 1. If you haven't done S1 — start there, this will be easier.

---

## Before you start (one-time)

Same as in Scenario 1 — [create your own repo from the template and download it](#create-your-own-repo-from-this-template-and-download-it). Open a Claude Code session in the project folder (`claude`) and run `/setup:start` first.

---

### Steps 1–3: PRD, stack, backlog — like in S1, with one difference

Go through [Step 1](#step-1-describe-what-you-want-to-build-discover), [Step 2](#step-2-decide-the-architecture-and-the-technology-architect) and [Step 3](#step-3-lay-out-the-delivery-plan-backlog) **exactly like in Scenario 1**. The only difference is in the `/discover` description — say explicitly that you want a **user interface**:

📋 **Type** (example):
```
/discover Build a to-do list (TODO) application with a browser interface: add a task, list tasks, check off as done, delete. Backend (API) + frontend (web UI). No login.
```

💬 **What changes from here on:** `/architect` will now propose **two** layers (backend + frontend), and `/setup:create-backlog` will lay out a backlog where, besides `E0-1: project scaffold`, frontend tasks appear. The rest (how to read, how to verify) — identical.

⏭️ **Next:** Step 4.

---

### Steps 4–5: Scaffold + project rules — like in S1

Do [Step 4](#step-4-build-the-project-scaffold-first-pass-through-the-pipeline) (`/prime` → `/brainstorm` → `/plan-feature` → `/execute` on task `E0-1`) and [Step 5](#step-5-create-the-project-rules-claudemd) (`/setup:create-CLAUDE_MD`) **unchanged**. The scaffold will now also contain the frontend part (Claude will list the created files).

⏭️ **Next:** Step 6 — the first feature, where the new part begins.

---

### Step 6: Design the first feature (brainstorm) — like in S1

Fresh chat → `/prime`, then design the feature — [just like in Step 6 of S1](#step-6-design-the-first-feature-brainstorm):

📋 **Type:**
```
/prime
/brainstorm adding and displaying TODO tasks (API + screen)
```

💬 **What happens:** a spec is created in `.agents/specs/` — a description of *what and how*, including that the feature has a visual layer. Still **no code**.

⏭️ **Next:** Step 6.5 — **NEW step: UI design.**

---

### 🆕 Step 6.5: Design the look (design)

> This is a step that **isn't** in Scenario 1. Before you write the frontend, you first design how it should look — so the code implements a concrete, thought-through layout, not "whatever".

📋 **Type:**
```
/design-ui TODO task list screen
```

💬 **What happens:** Claude loads the design knowledge and the project's design tokens, asks whether you want **1 variant** (refinement) or **3** (different approaches), generates the mockup(s), and **checks each one itself** against quality rules before showing it to you. It saves the approved design into `.agents/specs/design/Ready/`.

✅ **How you know it's OK:** there's a file with your screen's mockup in `.agents/specs/design/Ready/`, and Claude confirmed it passed the self-check gate.

⏭️ **Next:** Step 7 — plan and code.

<details>
<summary>💡 TIP — what "Ready/" is and why design is a separate step</summary>

`.agents/specs/design/Ready/` is the agreed place for **approved** mockups — the `/gates:design-quality-check` gate and the `/orchestrate` pipeline reach into it later to compare the finished UI against the design. Separating "how it should look" (design) from "how to write it" (plan) means `/execute` has a concrete reference to reproduce, rather than guessing the layout. If you **already have designs** (HTML/Figma) and don't want to generate them — that's Scenario 3.
</details>

---

### Steps 7–8: Plan and code (plan-feature → execute) — like in S1

Do [Step 7](#step-7-make-a-detailed-plan-plan-feature) and [Step 8](#step-8-write-the-code-execute) **unchanged**. The only difference is in the content: `/plan-feature` will account for the mockup in `Ready/`, and `/execute` will write **both backend and frontend** per the plan.

⏭️ **Next:** Step 9 — quality, where browser tests are added.

---

### Step 9: Check quality (check-implementation) — like in S1

Do [Step 9](#step-9-check-quality-check-implementation) **unchanged** — the same code-review → gates loop, leaves a clean tree, doesn't commit itself.

⏭️ **Next:** Step 9.5 — **NEW: browser tests.**

---

### 🆕 Step 9.5: Test by clicking (test-e2e)

> A second step that isn't in S1. Since you have a screen, it's worth verifying it **actually works in the browser** — clicking "add", the task appearing, checking it off.

📋 **Type:**
```
/test-e2e adding a task
```

💬 **What happens:** Claude **first clicks through** your screen in a real browser (via Playwright), shows the test plan, and **waits for your approval** — only then does it generate the E2E tests and run them.

✅ **How you know it's OK:** an E2E test file is created, and the run finishes green (Claude will show the result).

⏭️ **Next:** Step 10 — commit.

<details>
<summary>💡 TIP — what if I don't have Playwright configured yet</summary>

`/test-e2e` uses MCP Playwright (browser automation). If your frontend doesn't yet expose a dev server or you don't have Playwright, Claude will say so and suggest what to configure. On the first, simple screen you can skip this step and come back to it later — E2E tests aren't required to commit. The argument can also be empty (`/test-e2e`) — then it takes the flow list from the `Testing Strategy` in the active plan.
</details>

---

### Steps 10–11: Commit and push — like in S1

[Step 10 (`/commit`)](#step-10-save-the-changes-commit) and [Step 11 (`/push`)](#step-11-push-to-github-optional) — **unchanged**.

---

## 🎉 Congratulations — you have a working app with a screen!

The cycle is the same as in S1, enriched with two visual steps:
**idea → PRD → stack → backlog → scaffold → brainstorm → 🆕 design → plan → code → quality → 🆕 E2E tests → commit.**

**Another feature with a screen?** You repeat: fresh chat → `/prime` → `/brainstorm <feature>` → `/design-ui <screen>` → `/plan-feature` → `/execute` → `/check-implementation` → `/test-e2e <flow>` → `/commit`. Features *without* a visual layer (purely backend) you do via the shorter path from S1 — you skip `/design-ui` and `/test-e2e`.

> Already have mockups (HTML/Figma) instead of generating them with `/design-ui`? → **Scenario 3**.

---

# Scenario 3: I already have designs (HTML/Figma)

**What we'll build:** the same TODO with a screen as in Scenario 2 — but **we don't generate** the look with the `/design-ui` command. You already have the look: HTML mockups or a Figma file. Claude's job is to **implement them faithfully** and check that the code matches the design pixel for pixel.

**What you'll learn:** how to **bring an external design** into the template and how the **parity gate** `/gates:design-quality-check` (code vs. design) works.

> 📌 **This is a variant of Scenario 2.** There's one simple difference: instead of *generating* a mockup (`/design-ui`), you **supply your own** — and a consistency-check step is added. The whole rhythm `PRD → stack → backlog → scaffold → brainstorm → plan → execute → check → commit` is identical. If you haven't done S2 — review it first, this will be clearer.

---

## Before you start (one-time)

Same as before — [create your own repo from the template and download it](#create-your-own-repo-from-this-template-and-download-it), open a Claude Code session (`claude`) and run `/setup:start` first.

**Prepare your design** — pick ONE of the ways:

- **I have HTML/CSS mockups** → the simplest. Remember where those files are (in Step 6.5 we'll move them to the agreed place).
- **I have a design in Figma** → make sure you have **Figma MCP** wired into Claude Code (and a link to the node/screen). Then Claude will pull the design **live** from Figma.

⏭️ **Next:** Steps 1–6 as in S2.

---

### Steps 1–6: PRD, stack, backlog, scaffold, rules, brainstorm — like in S2

Go through [Steps 1–3](#steps-13-prd-stack-backlog--like-in-s1-with-one-difference), [Steps 4–5](#steps-45-scaffold--project-rules--like-in-s1) and [Step 6 (brainstorm)](#step-6-design-the-first-feature-brainstorm--like-in-s1) **exactly like in Scenario 2** — including the PRD description indicating there's a user interface. Nothing changes here.

⏭️ **Next:** Step 6.5 — this is where the difference between S3 and S2 begins.

---

### 🔀 Step 6.5: Bring in your design (instead of generating it)

> In Scenario 2 this step *generated* a mockup via `/design-ui`. **Here you skip it** — because you already have the design. Instead, you **make** your design available to Claude.

**Variant A — you have HTML/CSS mockups:**

Put each mockup in the agreed directory **`.agents/specs/design/Ready/{area}/{Name}.html`** (e.g. `.agents/specs/design/Ready/todo/TaskList.html`). You can do it manually or ask Claude:

📋 **Type** (example):
```
I have ready mockups in the ./my-designs folder. Move them into .agents/specs/design/Ready/ under the appropriate areas and add the required frontmatter (name, priority, status).
```

**Variant B — you have Figma:**

You don't copy anything. Keep the **link to the Figma node/screen** handy — you'll provide it in the parity-check step. The gate pulls the design live from Figma (Figma is the authoritative source).

💬 **What happens:** you set the **source of truth for the look**. From now on `/plan-feature`, `/execute` and the parity gate have a concrete reference to reproduce — instead of guessing the layout.

✅ **How you know it's OK:** (A) your `.html` files with frontmatter are in `.agents/specs/design/Ready/.../`; (B) you have a working Figma MCP and a link to the screen.

⏭️ **Next:** Step 7 — plan and code.

<details>
<summary>💡 TIP — why "Ready/" specifically and what that frontmatter is</summary>

`.agents/specs/design/Ready/` is the same place `/design-ui` saves *generated* mockups — so the rest of the tooling (the parity gate, `/orchestrate`) always looks for the design there, whether it was created automatically or you brought it in. The frontmatter (`name` + `priority` + `status`) at the top of the file lets the tools recognize and order the mockups. Figma doesn't require copying to `Ready/` — with MCP wired up, the gate reads the design directly and it wins over any static HTML on a conflict.
</details>

---

### Steps 7–9: Plan, code, quality — like in S2

Do [Steps 7–8 (`/plan-feature` → `/execute`)](#steps-78-plan-and-code-plan-feature--execute--like-in-s1) and [Step 9 (`/check-implementation`)](#step-9-check-quality-check-implementation--like-in-s1) **unchanged**. `/execute` will write code reproducing **your** mockup from `Ready/` (or from Figma).

⏭️ **Next:** Step 9.4 — **NEW in S3: checking consistency with the design.**

---

### 🆕 Step 9.4: Check consistency with the design (design-quality-check)

> A step specific to S3 (and useful any time you have a reference design). Since you have a **concrete** design, it's worth verifying that the code reproduced it **exactly** — colors, spacing, typography, behavior.

📋 **Type** (A — HTML; provide the section name):
```
/gates:design-quality-check task list
```
📋 or (B — Figma; add the node link):
```
/gates:design-quality-check task list <figma-node-link>
```

💬 **What happens:** Claude compares the finished screen with your reference and **lists every deviation** (visual, layout, accessibility, behavior). It **fixes nothing** — it only reports. You decide what to fix.

✅ **How you know it's OK:** you get a deviation report. No differences (or only "authorized" ones) = parity achieved.

⏭️ **Next:** if there are deviations → fix them (`/execute` or `/check-implementation`) and run the gate again. When clean → Step 9.5.

<details>
<summary>💡 TIP — it's a reporting gate, not a fixing one</summary>

`/gates:design-quality-check` is the inverse of `/gates:verify-implementation`: the latter checks code against the *plan*, this one — fidelity against the *design*. Philosophy: **in design there are no "minor" differences** — if the reference has a value and the code has a different one, that's a defect. The gate will list it; the decision to accept is yours. With Figma wired up, the audit takes values live from Figma; without it — from the static HTML in `Ready/`.
</details>

---

### Steps 9.5–11: E2E tests, commit, push — like in S2

[Step 9.5 (`/test-e2e`)](#-step-95-test-by-clicking-test-e2e), [Step 10 (`/commit`)](#step-10-save-the-changes-commit) and [Step 11 (`/push`)](#step-11-push-to-github-optional) — **unchanged**.

---

## 🎉 Congratulations — you've implemented your own design!

The cycle is like in S2, but the look comes from you, and the code is verified against it pixel for pixel:
**idea → PRD → stack → backlog → scaffold → brainstorm → 🔀 your design in `Ready/` → plan → code → quality → 🆕 design parity → E2E tests → commit.**

**Another screen with a ready design?** You repeat: fresh chat → `/prime` → `/brainstorm <feature>` → *(put the mockup in `Ready/`)* → `/plan-feature` → `/execute` → `/check-implementation` → `/gates:design-quality-check <section>` → `/test-e2e <flow>` → `/commit`.

> Want Claude to **design the look itself** instead of supplying your own? → **Scenario 2** (the `/design-ui` step).

---

# Scenario 4: Existing project (brownfield)

**What we'll do:** take **a project that already has code** (created without this template) and **bring this whole workflow into it** — project memory, an architecture map, rules, a backlog. The goal: from tomorrow, work on that code with the same rhythm as in S1–S3.

**What you'll learn:** how Claude **understands someone else's/legacy code** with the **`/setup:map-codebase`** command and how that understanding becomes project memory you hook further work into.

> 📌 **This is a different start than S1–S3.** There you started from an empty idea (PRD → stack → scaffold). Here **the code already exists** — so first the template has to be *brought* into the repo, and Claude has to *understand* what it found. Only then do you return to the familiar rhythm `brainstorm → plan → execute → check → commit`. 🔴 Harder, because it deals with real, existing code.

---

## Before you start — bring the template into your repo

> Here you do **not** use "Use this template". Your project already exists — we add the tools to **it**.

In the terminal, in **your** project folder (make a backup/branch first):

```bash
# in the existing project's directory
git checkout -b adopt-ai-workflow      # a safe branch for adoption
# copy only the tooling layer from the template (without its code/application):
#   .claude/  and  .agents/  plus  CLAUDE.md
```

📋 The easiest way: download the template alongside, copy `.claude/`, `.agents/` and `CLAUDE.md` from it into your repo:
```bash
git clone https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-starter
cp -R /tmp/ai-starter/.claude /tmp/ai-starter/.agents /tmp/ai-starter/CLAUDE.md .
[ -f .env.example ] || cp /tmp/ai-starter/.env.example .
[ -f .mcp.json ]    || cp /tmp/ai-starter/.mcp.json .
```

If your repo already has an `.env.example` or `.mcp.json`, do **not** overwrite them — merge by hand (add the starter's integration blocks / MCP servers, keep yours), as `.claude/starter-sync-playbook.md` → Category B describes. Then run `/setup:start` before anything else.

💬 **What happens:** your project gets the `.claude/` layer (commands, hooks, settings) and `.agents/` (memory, reference, specs, plans) plus `CLAUDE.md` with rules. **Your code stays untouched** — we only add the scaffolding.

✅ **How you know it's OK:** alongside your code you now have the folders `.claude/` and `.agents/` and the file `CLAUDE.md` (with `{...}` placeholders — we'll fill them in shortly).

⏭️ **Next:** open a Claude Code session (`claude`) and go to Step 1.

<details>
<summary>💡 TIP — why we copy only `.claude/`, `.agents/` and `CLAUDE.md`</summary>

These are the only parts of the template that are the "engine" of the workflow — the rest of the template repository (the example `README.md`, `docs/`, `LICENSE`) is about *the template itself*, not your project. By bringing only the tooling layer, you don't mix your code with someone else's. The `adopt-ai-workflow` branch gives you a clean rollback point if something goes wrong.
</details>

---

### Step 1: Let Claude understand your code (map-codebase)

> This is the **heart** of this scenario and at the same time its biggest difference from S1–S3. Instead of writing a PRD from scratch, Claude **reads the existing code** and reconstructs knowledge about the project from it.

📋 **Type:**
```
/prime
/setup:map-codebase
```

💬 **What happens:** `/setup:map-codebase` scans the repo, splits it into modules and understands the code **in parallel** (many agents), then produces: `.agents/memory/architecture.md` (the project map) **and a reconstructed `docs/PRD.md`** (what this application actually does). Along the way it **asks for your approval twice** — first what to analyze (scope, list of skipped files), then at the summary. At the end it carries on itself: refreshes the brief and generates `CLAUDE.md`.

✅ **How you know it's OK:** `.agents/memory/architecture.md` and `docs/PRD.md` were created, and `CLAUDE.md` has filled-in sections about your project (not `{...}` placeholders).

⏭️ **Next:** Step 2.

> ⚠️ **Small project (< ~50 files)?** `/setup:map-codebase` will tell you itself that fan-out is unnecessary and ask you to just run **`/setup:create-CLAUDE_MD`** instead (it analyzes the code directly). Then you skip map-codebase and do that one command.

<details>
<summary>💡 TIP — why this is a separate, "heavy" command</summary>

A large, existing codebase won't fit in a single context. `/setup:map-codebase` distributes the work across many agents, each of which **returns only a concise summary (~1–2k)** — so the repo's size affects the *number* of agents, not context bloat. It's a one-time bootstrap: code understood once lands in the project memory (`architecture.md`, PRD, brief), which all subsequent commands use. Full description: [.claude/commands/setup/map-codebase.md](../.claude/commands/setup/map-codebase.md).
</details>

---

### Step 2: Lay out a backlog based on the existing code (optional)

> Just like in S1, the backlog is the source of truth for work order — but here it's created **based on the mapped code and the reconstructed PRD**, not an empty idea.

📋 **Type:**
```
/setup:create-backlog
```

💬 **What happens:** Claude reads the reconstructed PRD + `architecture.md` and lays out a delivery map for the project's **further development**. Note the difference: the `E0-1` task is **not** "create the scaffold" (you already have a scaffold) — it will be "adopt/normalize the existing scaffold" or it gets omitted.

✅ **How you know it's OK:** a `.agents/backlog.md` was created with tasks describing what you want to build/change next in the existing code.

⏭️ **Next:** Step 3 — and from here on you're already in the familiar rhythm.

> 💡 The backlog is optional. If you have a concrete change to make right away, you can skip it and go to Step 3, giving the topic directly to `/brainstorm`.

---

### Step 3: Work like in S1 — the next change in existing code

> From here on, **brownfield looks identical to greenfield.** You already have the project memory, the map and the rules — so every change is the same cycle as in Scenario 1, except Claude works on real, existing code.

📋 **Type** (fresh chat for each change):
```
/prime
/brainstorm <change description, e.g. add CSV export of tasks>
/plan-feature
/execute
/check-implementation
/commit
```

💬 **What happens:** exactly the same as in [Steps 6–10 of Scenario 1](#step-6-design-the-first-feature-brainstorm) — except that `/brainstorm` and `/plan-feature` account for the **existing architecture** (from `architecture.md`), so new code fits into what's already there instead of creating duplicates.

✅ **How you know it's OK:** the change is implemented in line with the project's existing patterns, the quality gates passed, the commit was created.

⏭️ **Next:** you repeat Step 3 for each subsequent change; `/push` when you want to push (like [Step 11 of S1](#step-11-push-to-github-optional)).

> 🖥️ **Does the project have a frontend / ready designs?** Add the steps from S2/S3 to this cycle — `/design-ui` (or your own mockup in `Ready/`), `/gates:design-quality-check`, `/test-e2e`. Brownfield combines with each of them.

---

## 🎉 Congratulations — your existing project now speaks the same language!

Instead of starting from an idea, we started from **code that was already there**:
**bring in the template → 🆕 understand the code (`map-codebase`) → memory + map + rules → backlog → and from now on the usual rhythm `brainstorm → plan → execute → check → commit`.**

The hardest part (understanding the existing code) you do **once**. After that brownfield is no different from greenfield — the same loop, the same commands, the same quality gates.

> Is the project new, not existing? → go back to **Scenario 1** (backend) or **2/3** (with a frontend).

---

# Scenario 5: Analyst path (BA → Jira)

**What we'll do:** turn an **idea** into organized work — a PRD, a **backlog** (delivery map), and finally **tasks in Jira** for the team. **Without writing code.** This is the path of a business analyst / Product Owner.

**What you'll learn:** how to turn raw materials into a discovery, a PRD and a backlog, and how to **mirror the backlog into Jira** (epics + tasks) with `/jira sync` — remembering that **the backlog is the source of truth, and Jira is its mirror**.

> 📌 **This is the "no code" path.** You finish where a developer starts coding: with a ready backlog and tasks in Jira. The first steps (discovery + PRD, backlog) are shared with S1 — the difference is in the priority (product context, not implementation) and in the finale (mirror into Jira).

---

## Before you start (one-time)

[Create your own repo from the template and download it](#create-your-own-repo-from-this-template-and-download-it) (or join the team's existing repo). Open a Claude Code session (`claude`).

Run `/setup:start` first and answer **Jira: yes** — it activates the Jira block in `.env.example` and keeps the `/jira` commands.

**Want to mirror into Jira (Step 4)?** You need a configured **MCP Atlassian** — the variables `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` in `.env`. How to set them: [.agents/reference/jira-mcp-atlassian.md](../.agents/reference/jira-mcp-atlassian.md). Without it you'll do Steps 1–3 (discovery + PRD + backlog) and add the mirror later.

⏭️ **Next:** Step 1.

---

### Step 1: Gather materials and describe the product (sources + discover)

> As an analyst you most often already have **input materials** — meeting notes, a brief, transcripts, requirement dumps. That's your starting point.

**Drop the materials into `.agents/sources/`.** Copy all the files there (briefs, transcripts, PDFs, sketches). Claude will read them **automatically** during discovery.

📋 **Type:**
```
/prime
/discover Based on the materials in .agents/sources/: <one sentence about what it is>.
```
or, when the requirements already exist as a list or a spreadsheet (exported to CSV):
```
/prime
/discover --import requirements.csv
```

💬 **What happens:** Claude reads `.agents/sources/` (and the imported file — every row becomes an entry with an id, its original wording quoted), shows what is already clear, and asks **only about the gaps** (users, measurable goals, scope, what we skip, the one flow that must work) — in short rounds, each question with a **Recommended** answer. It writes `docs/discovery.md` and `docs/PRD.md` — a formal description of *what and why*, every statement with a stable id.

✅ **How you know it's OK:** `docs/discovery.md` and `docs/PRD.md` were created; the PRD has goals (`G-n`), requirements (`R-n`) and a scope section; contradictions between your materials show up as open questions (`Q-n`) with an owner, not silently resolved.

⏭️ **Next:** Step 2.

<details>
<summary>💡 TIP — it's the same discovery as in S1; here you just "polish" it more</summary>

The discovery and the PRD are the common foundation of all scenarios. The difference on the BA path: you usually spend more time here (it's your main work product), you rely heavily on `.agents/sources/`, and you don't move on to code afterward. You can leave the architecture to the team or run `/architect` as a recommendation for them — that's optional.
</details>

---

### Step 2: Load the product context (prime-ba)

> For analyst work there's a **dedicated** priming command — it loads the **product** context (PRD, specs, decisions, backlog), not the implementation context like the regular `/prime`.

📋 **Type:**
```
/prime-ba
```

💬 **What happens:** Claude loads `PRD.md`, the materials from `sources/`, the approved specs from `.agents/specs/`, the decisions and the live backlog — i.e. everything an analyst needs to lay out and organize work.

✅ **How you know it's OK:** Claude prints a product summary (for whom, MVP, state of work) without reaching for implementation details.

⏭️ **Next:** Step 3.

---

### Step 3: Lay out the backlog (source of truth)

📋 **Type:**
```
/setup:create-backlog
```

💬 **What happens:** Claude turns the PRD into a **delivery map** in `.agents/backlog.md` — epics, tasks with IDs (`E0-1`, `E1-2`, …) as user stories or technical tasks, sizes (`M` / `H` / `XH`, summed to the epic), dependencies (DAG), parallel lanes for 2–4 developers and a story map with the walking skeleton. This is the **canonical** list of "what to build, in what order".

✅ **How you know it's OK:** a `.agents/backlog.md` was created with a table of epics and tasks.

⏭️ **Next:** Step 4 — mirror into Jira.

> 🔑 **The backlog is the source of truth, Jira is its mirror.** The Jira issues are created **from** the backlog (one-way: backlog → Jira). You don't maintain two parallel lists — the backlog is first and authoritative, Jira is its mirror for the team.

<details>
<summary>💡 TIP — why a backlog and not Jira right away</summary>

The backlog (`.agents/backlog.md`) lives **in the repo, next to the code** — it's versioned, read by the rest of the pipeline (`/brainstorm`, `/plan-feature`) and doesn't require a connection to Jira. Jira is great for the team, but as a *consumer* of the structure, not its author. If you laid out the structure directly in Jira, the rest of the template's tooling would have nothing to work from. That's why the order is always: PRD → backlog → (optionally) Jira.
</details>

---

### Step 4: Mirror the backlog into Jira (optional)

> A step for teams on Jira. One command mirrors the backlog's epics and tasks into Jira — **you confirm, Claude executes**, and nothing is written before you see it.

📋 **Type:**
```
/jira sync
```

💬 **What happens:** Claude first validates the backlog (`node .claude/lib/backlog-check.mjs`) — an invalid backlog is never mirrored. It takes the Jira project from `JIRA_DEFAULT_PROJECT` or asks you for it, then shows **a table of what will be created, with every description, and waits for your `y`** (Jira has no undo — that's a deliberate safeguard). After confirmation it creates the epics and tasks one by one (with parent, labels and estimate), writes each Jira key back into the task's `Jira` column in `.agents/backlog.md`, and links the dependencies as `Blocks`.

✅ **How you know it's OK:** epics and tasks corresponding to the backlog appeared in Jira, the `Jira` column of the backlog holds their keys, and Claude shows a report of created and skipped rows.

⏭️ **Next:** done — the team has tasks, you have the backlog as the source of truth.

> ⚠️ **Create-only and one-way.** `/jira sync` never updates, transitions or deletes an issue. After you add tasks to the backlog, run it again — rows that already have a key are skipped, only the new ones are created. The one thing Jira owns afterwards is the **workflow status** of synced tasks: an empty `/brainstorm` reads it back into the backlog.

<details>
<summary>💡 TIP — why a second run never creates duplicates</summary>

Every issue `/jira sync` creates carries a label `<namespace>:<task id>` (the namespace is in the backlog header), and every run starts by reconciling: it re-checks keys written as `KEY (unverified)` and adopts issues that were created but never written back (e.g. after a crash). For a single issue outside the backlog, `/jira create` and `/jira bulk` still work as before, with the same table-first confirmation. Full description: [.claude/skills/jira/SKILL.md](../.claude/skills/jira/SKILL.md).
</details>

---

## 🎉 Congratulations — you have a ready backlog and tasks for the team!

You went through the analyst path without writing code:
**materials (`sources/`) → discovery + PRD (`/discover`) → product context (`prime-ba`) → backlog (source of truth) → 🔁 `/jira sync` (mirror).**

**What's next?** Developers take your backlog and enter the S1–S4 paths: fresh chat → `/prime` → empty `/brainstorm` (which takes the **next free task from the backlog** itself) → `/plan-feature` → `/execute` → … Your structure drives their work without retyping.

> Want to also **design screens** for the team (not just tasks)? Check **Scenario 2/3** — the `/design-ui` step.
