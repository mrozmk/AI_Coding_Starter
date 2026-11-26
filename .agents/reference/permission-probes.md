# Reference: permission carrier probes

Whether a `PermissionRequest` hook fires — and what it sees — outside a lead-run team stage is not
documented for every host and mode. These probes answer it with evidence, one throwaway session per
host type, using the logging-only probe `.claude/lib/permission_probe.py`. The probe **never
decides**: it logs and exits 0 with no output, so the host's own dialog or denial still happens.

**Never** register the probe in `.claude/settings*.json`, a role profile under
`.claude/team/sessions/`, `$CODEX_HOME/hooks.json` or any other real configuration: probe settings
live only in a scratch directory that is deleted after the run.

---

## The probe

| Command | What it does |
|---|---|
| `python3 -I .claude/lib/permission_probe.py hook --log <file> [--sleep N]` | reads the hook payload on stdin, appends one JSON line to `<file>` — `at`, `hook_event_name`, `tool_name`, `tool_input` (masked by `touches.py`; without it the literal `<unmasked: touches.py missing>` instead), `session_id`, `agent_id`, `agent_type`, `permission_mode`, `cwd`, `keys` (every payload key) — or `{at, unreadable: true}`; written and flushed **before** the sleep; prints nothing; exit 0 always |
| `… claude-settings --log <file> [--sleep N] [--timeout S]` | prints a Claude Code settings fixture registering the probe on `PermissionRequest` (with the sleep) and on `PreToolUse` (without) |
| `… codex-config --log <file> [--timeout S]` | prints the same two hooks as a Codex `hooks.json` body |

The `PreToolUse` line is the control: it proves the fixture loaded and that the target call
happened. **A trial with no `PreToolUse` line for its target call is `inconclusive`, never "does
not fire".** A log line from a hook the fixture did not register (a user or managed hook) also
makes the trial `inconclusive`.

## What each report records

Per trial:

- host and version (`claude --version`, `codex --version`), mode (`-p`, interactive, permission
  mode), the exact command used;
- **fixture loaded** — a `PreToolUse` line exists;
- **target observed** — the `PreToolUse` line for the target call, plus the host's own prompt or
  denial text;
- **PermissionRequest fired** — yes (its line, quoted) / no;
- **fields seen** — the `keys` list; for a sub-agent call, `agent_id` / `agent_type`;
- **timeout result** — with `--sleep` beyond the hook `timeout`: what the host did (the probe line
  is already written; the host's behaviour is the finding);
- **sandbox network prompt** — whether a sandboxed command's network request reached the hook;
- verdict per trial: `fires` · `does not fire` · `inconclusive` (and why).

Quote the probe log lines verbatim — they are already masked; mask nothing by hand. Reports live in
a project that keeps evidence (e.g. `.agents/evidence/prompt-replay/probes/<host>.md`), never in
the template itself.

Documented expectations to compare against (Claude Code hooks reference, `PermissionRequest`):
the hook runs when Claude Code is about to ask for permission **or would auto-deny a call that
cannot prompt** — so in `claude -p` a call that would prompt reaches the hook and is then denied
(the expected `-p` result, not a failure); Claude Code does **not** run `PermissionRequest` for a
sandboxed command's network request; a timed-out hook's output is discarded. Codex runs
`PermissionRequest` only when it is about to ask for approval. Whether an empty output, a timeout
or auto mode changes the dialog is not documented — the probes observe it.

## Clean launch

Every Claude probe session starts clean of the parent session and of any team identity, or the
egress guard arms and touch-log writers point at the real main checkout:

```
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    -u CLAUDE_CONFIG_DIR -u TEAM_RUN_TEAM -u TEAM_RUN_ROLE -u TEAM_RUN_ID -u TEAM_RUN_ATTEMPT \
    -u TEAM_SESSION_ROLE -u CLAUDE_PROJECT_DIR -u HARNESS_MAIN claude …
```

(the first five are the session host's clean-launch contract, `session-host-lib.sh`). Run it with
the shell's cwd inside the scratch repo. Count the lines of `<main>/.agents/touches/` before and
after: a probe must add none.

## Procedure per host type

### Claude solo, print mode (a stage can run it)

1. `S=<scratch>/probe-solo; mkdir -p "$S/.claude"; git -C "$S" init -q; : > "$S/victim.txt"`.
2. `python3 -I .claude/lib/permission_probe.py claude-settings --log "$S/probe.log" --timeout 5 > "$S/.claude/settings.json"`.
3. From `$S`, with the clean launch above: `claude -p --model haiku --setting-sources project
   --permission-mode default "<prompt>"` — `--setting-sources project` keeps the user's own hooks
   and rules out (managed policy still applies; record whether the flag was accepted). Trials:
   1. a call that would prompt — "Run the Bash command `rm victim.txt`";
   2. the same from a sub-agent — "Use the Task tool to have a sub-agent run `rm victim.txt`";
   3. timeout — a settings variant with `--sleep 20` and `--timeout 5`, trial 1 again;
   4. sandbox network — a settings variant with `"sandbox": {"enabled": true}` added, "Run
      `curl -sI https://example.com`".
4. Record per trial (above); delete `$S`.

### Claude solo, interactive (the Supervisor)

The same fixture and trials from a session-host pane, interactively (`claude --setting-sources
project --permission-mode default`), so the dialog itself is observed: does it still show while the
probe ran, and what does trial 3 do to it.

### Claude Advisor in auto mode (the Supervisor)

A throwaway Advisor-shaped session — never a real Advisor profile: the clean launch plus
`TEAM_SESSION_ROLE=Advisor`, `--permission-mode auto`, the fixture layered with `--settings
<scratch>/.claude/settings.json` in a scratch git repo. Trials 1, 2 and 4; record whether the auto
mode classifier approved or denied before any `PermissionRequest` line, and whether one appears.

### Codex (the Supervisor, or a stage when it can isolate the host)

1. A scratch project `P` (`git init`), trusted through Codex's own trust prompt on first launch —
   untrusted projects skip their `.codex/` layer. Never the Operator's `$CODEX_HOME/hooks.json`: a
   user-level hook would see concurrent sessions and survive an interrupted trial.
2. `python3 -I .claude/lib/permission_probe.py codex-config --log "$P/probe.log" --timeout 5 > "$P/.codex/hooks.json"`;
   enable hooks in the project layer if the version requires `[features] hooks`.
3. `codex exec -C "$P" -c approval_policy='"on-request"' "<a prompt that needs an escalation, e.g. a
   network command>"`; record `codex --version`, the probe lines, and Codex's own approval output.
4. A host that cannot be isolated this way → `inconclusive`, handed to the Supervisor with the
   steps.

## Cleanup

Delete the scratch directory. Never touch `.claude/settings*.json`, `.claude/team/sessions/` or
`$CODEX_HOME`.
