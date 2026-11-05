# Setup walkthrough evidence — 2026-11-05

A documentation dry-run, **not** the acceptance run: a new developer's path from a fresh clone
of the starter to the point where role sessions would start, following only `docs/teams/*` and
the README section. No session was started, no tmux session was created, and nothing ran
against a real `~/.agent-mail`. It changes no cell of [capabilities.md](../capabilities.md):
those wait for the acceptance run with the Operator. Format: [TEMPLATE.md](TEMPLATE.md).

- Starter sha: `980fba5` (branch `feat/team-supervision-p9-docs`, before its doc fixes)
- Environment: `HOME=<scratch>/home`, `CLAUDE_CONFIG_DIR=<scratch>/claude`, `TMPDIR=<scratch>/tmp`;
  the target projects are throwaway `git init` repos (`<scratch>/proj`, `<scratch>/proj2`) with
  a fake `github.com` origin and no network use
- Host tools present: tmux, jq, git, python3, sqlite3, perl, claude, codex

## Lines

```
E01 host-tools | live-a | command -v tmux jq claude codex git python3 sqlite3 perl | all present | 2026-11-05T08:30Z | 980fba5
E02 channel-fresh | live-a | team-setup.sh <starter> <proj> (created=147 conflict=0, exit 3) → profile → team-mail-setup.sh --dry-run, apply | mode fresh key DM: registry, tool copy, box + decisions/, 3 recipients, channel.local.json, watch.local.json; escalation skipped (no kit); first dry-run refused until the install was committed (F21) | 2026-11-05T08:30Z | 980fba5
E03 channel-loads | live-a | team-mail.sh --here check; team-channel.sh show | OK DM; show exit 0; codex_home stored as <scratch>/home/~/.codex-demo (F20) | 2026-11-05T08:30Z | 980fba5
E04 kit | live-a | operator-kit/install.sh --dry-run, --apply, --verify | 6 files installed, 6 ok; escalation.local.json written by --apply with send/wait/peek/opinion; dry-run printed skip for it (F25) | 2026-11-05T08:30Z | 980fba5
E02 channel-reuse | live-b | team-mail-setup.sh --dry-run on the bound checkout | mode reuse key DM, every line keep | 2026-11-05T08:30Z | 980fba5
E02 channel-extend | live-b | second project (D2) on the same registry: --dry-run, apply, check | mode extend key D2, own box and recipients, check OK; a second identical tool copy was created (F22) | 2026-11-05T08:30Z | 980fba5
E02 channel-keyed | live-b | second project --dry-run --key DM | mode reuse key DM with the DM recipients although the profile says D2, no warning (F24) | 2026-11-05T08:30Z | 980fba5
E23 reuse-external-tool | live-b | planted registry entry LV whose tool is an external directory; --dry-run | mode reuse, keep tool (external), note vendored tool unused, offer roles; registry sha256 02df647c3836a0fa before and after | 2026-11-05T08:30Z | 980fba5
```

## Gaps found (doc-only, fixed on this branch)

1. `docs/teams/09-setup.md` and `08-operator-kit.md` were stubs although the channel and the kit are merged: a new developer had no setup page. Written from this walkthrough.
2. The README section did not say where to run `/setup:teams` or that it takes the starter's path. Added, with the link to 09.
3. Nothing pointed at `.claude/project-profile.json.example`; the interview listed keys without shapes, and `test_gate`/`build_check` failed on the first try. The shapes and the example are now in `/setup:teams` Step 5 and in 09.
4. The fresh-install ordering (commit before the channel step) was undocumented. Now in Step 5c and 09.
5. `team-pipeline.md` §1 told every project to `az login` and spoke of `bin/obj`; two links pointed at a missing anchor. Made provider-neutral; the anchors fixed.
6. `.claude/codex-profile` (a seed file every project receives) carried a source ticket key. Removed.

## Gaps that need code

F20–F26 in [follow-ups.md](../follow-ups.md).
