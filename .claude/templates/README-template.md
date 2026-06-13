# README Template (project)

A skeleton for a **project** README — the one that lives at the repository root and describes
*your application*, not the AI workflow framework.

> **How this is used.** On bootstrap, `/setup:create-CLAUDE_MD` swaps the starter-kit's framework
> README out of the root (it is preserved at `.claude/README.md`) and generates a fresh root
> `README.md` from this template, filled with project facts pulled from `docs/PRD.md`,
> `.agents/memory/project-brief.md`, and the detected tech stack.
>
> Sections marked with `{placeholder}` or `<!-- comment -->` are the ones to fill in. Delete
> any section that does not apply to your project — keep it short and scannable.

---

# {Project Name}

{One-sentence description — what this project does and who it is for.}

{Optional second paragraph — the problem it solves, or its value proposition. Source this from
`docs/PRD.md` / `.agents/memory/project-brief.md` when generating.}

---

## Tech Stack

<!-- Pulled from the detected manifests during /setup:create-CLAUDE_MD. Add/remove rows as needed. -->

| Technology | Purpose |
|------------|---------|
| {tech} | {why it's used} |

---

## Prerequisites

<!-- Runtimes, tools, accounts a developer needs before installing. -->

- {e.g. Node.js ≥ 20 / Python ≥ 3.12 / Go ≥ 1.22}
- {e.g. Docker, a database, an API key}

---

## Getting Started

```bash
# Clone
git clone {repo-url} {project-dir}
cd {project-dir}

# Install dependencies
{install-command}

# Configure environment
cp .env.example .env   # then fill in the values

# Run in development
{dev-command}
```

---

## Common Commands

<!-- Mirror the Commands section of CLAUDE.md so humans and Claude share one source of truth. -->

```bash
{dev-command}      # start the dev server / app
{build-command}    # production build
{test-command}     # run the test suite
{lint-command}     # lint / format
```

---

## Project Structure

<!-- One or two levels deep — the high-level map. Full detail lives in
     .agents/memory/architecture.md. -->

```
{tree of top-level source directories}
```

> Detailed module roles and naming rules: [.agents/memory/architecture.md](.agents/memory/architecture.md)

---

## Configuration

<!-- Environment variables / config files the app reads. Never commit real secrets. -->

| Variable | Required | Description |
|----------|----------|-------------|
| `{VAR}` | yes/no | {what it controls} |

---

## Development Workflow

This repository uses an AI-assisted development workflow driven by [Claude Code](https://claude.com/claude-code).
The framework (slash commands, knowledge layers, conventions) is documented in
[.claude/README.md](.claude/README.md). Project rules for Claude live in [CLAUDE.md](CLAUDE.md).

<!-- Remove this section if the project does not use the AI workflow framework. -->

---

## License

{License name} — see [LICENSE](LICENSE).
