# agent_mail — SQLite mailbox between agent sessions

Four Python ≥ 3.9 stdlib modules: `agent_mail.py` (CLI), `agent_mail_store.py` (schema, store,
leases), `agent_mail_deliver.py` (push-side delivery loop), `mail_md.py` (legacy markdown-board
import/export). Protocol, registry schema, CLI and bring-up:
[`.agents/reference/agent-mail.md`](../../.agents/reference/agent-mail.md).

Do not call the tool bare from a session — use `bash .claude/lib/team-mail.sh <KEY> …`, which
resolves the box from `~/.agent-mail/projects.json` and always passes `--box`. The mailbox lives
outside the repository (`~/.agent-mail/<slug>/`); the tool's own fallback
(`<repo>/.agents/agent-mail/mail.sqlite`) is gitignored and unused by the client.

## Tests

```bash
python3 -I -m unittest discover -s tools/agent_mail/tests -t .   # stdlib, no pytest needed
python3 -I -m pytest tools/agent_mail/tests                       # same suite, when pytest exists
```

Offline: every test builds its own box under `tempfile.mkdtemp()`; the `codex`/`claude` adapters
are stubbed and never reach a live session.

## Vendored copy

- **Upstream:** `mrozmk/jarvis` at `c9c407c`, directory `tools/agent_mail/`, MIT — the same
  licence and copyright holder as this repository's `LICENSE`. Upstream stays the source of the
  tool; this copy is not developed here.
- **Local delta** (everything else is byte-identical to `c9c407c`):
  1. a two-line provenance header at the top of every `.py` file (after the shebang);
  2. example names in docstrings and tests: `Astra` → `Reviewer`, `Fable` → `Advisor`, and in
     `tests/test_mailbox.py` `Kimi` → `Tester` (keeps the `ORDER BY recipient` expectation);
  3. two test docstrings no longer name the upstream's local board path;
  4. this README replaces the upstream one (project-specific, not distributed);
  5. the default project label is `default` instead of the upstream's own project name: the
     CLI's `DEFAULT_PROJECT`, the `messages.project` schema `DEFAULT`, the `project=` defaults of
     `agent_mail_store.py` and the state test in `tests/test_mailbox.py`. A box created by an
     older copy keeps the default it was created with (the schema is `CREATE … IF NOT EXISTS`, and
     one tool serves one box); the team client never relies on it, see below.
  Decision ids in comments (`D2`, `D4`, `D9`, …) are the upstream's design decisions, kept as is.
  The CLI's `--project` default follows
  `AGENT_MAIL_PROJECT`, which `team-mail.sh` sets to the registry entry's `project_label` (the
  profile's `project_code`), so every call the team client forwards files under the project's code.
- **Legacy `mail.md` boards:** a post whose sender starts with the source board's executor name
  (`Wykonawca`, the default) is imported as a `report`; another board passes
  `--report-sender-prefix <name>` to `import-md` / `export-md`.
- **Re-sync** is a manual delta with the tests as the oracle: copy the upstream modules and tests
  at the new SHA over these files, re-apply the delta above (item 2 is
  `sed -i '' -e 's/Astra/Reviewer/g' -e 's/Fable/Advisor/g'` on every `.py`, plus `Kimi` →
  `Tester` in `tests/test_mailbox.py`; item 5 is the upstream project name → `default` in
  `agent_mail.py`, `agent_mail_store.py` and `tests/test_mailbox.py`), update the SHA here, in the headers and in
  `.claude/team/manifest.txt`, then run the tests above and `.claude/lib/tests/team-smoke.sh`
  (`TEAM_SMOKE_PART=mail`). A box keeps the tool that created it — one tool per box.
