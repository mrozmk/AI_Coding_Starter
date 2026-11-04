# 08 — Operator kit

> **Stub.** This page waits for the operator kit (installer, notifier, health check, `/mail-role`).
> Its names are not frozen yet, so it holds no prose. It is written when the kit merges.

TODO:

- what lives outside the repo and why; `install.sh --dry-run|--apply|--verify|--rollback`
- the lifetimes: hook registration, hook script, running loop, installed copy
- the notifier backends and the **declared loss** of `none`
- the optional health check, with the launchd and cron snippets the installer prints
- the Operator-action convention (`!`-scripts, the fixed block from [02](02-decision-model.md))
- the morning routine and the rollback of the whole model

Until then: [README](README.md) · [Follow-ups](follow-ups.md).
