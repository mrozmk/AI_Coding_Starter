---
status: empty
populated_by: /maintain:refresh-brief
description: Distilled TL;DR of the PRD — loaded by /prime instead of full PRD
---

# Project Brief

> Distilled overview for fast context loading. Regenerate with `/maintain:refresh-brief` whenever PRD changes substantially. For full details, see `docs/PRD.md`.
>
> While `status: empty`, `/prime` falls back to reading `docs/PRD.md` directly.

---

## What

{One paragraph — product purpose and value proposition.}

## Who

{Primary user persona(s), one or two lines each.}

## Stack

{One-line summary of the tech stack. Detail belongs in `architecture.md`.}

## Architecture

- {bullet — top-level architectural pattern}
- {bullet — data flow}
- {bullet — async / job processing}
- {bullet — auth model}
- {bullet — deployment shape}

## Status

{Current phase: bootstrapping / MVP build / post-MVP / mature. One line.}

## Key Conventions

- {convention 1}
- {convention 2}
- {convention 3}

## Key Files

| File | Purpose |
|------|---------|
| `docs/PRD.md` | Full product requirements |
| `CLAUDE.md` | Rules, conventions, workflow |
| `README.md` | Project overview & stack |
| `.agents/memory/index.md` | Memory routing table |
| `.agents/memory/architecture.md` | Directory structure & file map |
| `.agents/plans/active/` | Implementation plans by phase |
