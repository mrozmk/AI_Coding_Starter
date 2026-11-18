# subagent-model

Lowers the model of a built-in subagent spawned without one. A `general-purpose`, `claude` or
`Explore` helper that names no model inherits the session's model; on a session dearer than Opus
that is a top-tier model doing search and summary work. With the opt-in on, this mod hooks
`agent.spawn` and dispatches such a spawn with the alias from a rule table in
`.claude/project-profile.json`. It never raises a model, never blocks a spawn, and is off by
default.

```json
"workflow": {
  "subagent_model": {
    "enabled": false,
    "table": { "general-purpose": "opus", "claude": "opus", "Explore": "opus" }
  }
}
```

No `table` → the default above; a `table` replaces it whole. A row's value must be `haiku`,
`sonnet` or `opus`; a full model id, a typo or a non-string drops that row.
The profile is read from the session's project root when that directory has
`.claude/project-profile.json`, else from the git top level.

## Decision order

First match wins; every rule but the last passes the spawn through unchanged.

1. Profile missing or unreadable, `workflow.subagent_model` absent, or `enabled` not `true`.
2. `CLAUDE_CODE_SUBAGENT_MODEL` set to anything but empty / `inherit` / `default`, or
   `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` set.
3. A fork (`fork`, or type `fork`), a resume, a teammate or a workflow agent.
4. The call names a model (anything but `inherit`).
5. Not an engine built-in, or a built-in that pins its own model (only `general-purpose`,
   `claude`, `Explore` and `Plan` inherit).
6. The type has no row in the table.
7. `ANTHROPIC_DEFAULT_<ALIAS>_MODEL` is set for the row's alias.
8. The row's family is not strictly cheaper than the session model's, or that family cannot be
   read.
9. Otherwise the spawn runs on the row's alias.

## Environment

- `CLAUDE_CODE_SUBAGENT_MODEL` / `_FORCE` win: the mod steps aside. The variable alone is not
  the same lever — it also lowers agents that name no `model:` line of their own and raises
  subagents on a cheaper session.
- `ANTHROPIC_DEFAULT_*_MODEL` redirects an alias; a row using that alias passes through, since
  the alias no longer names the model the row meant.

## Why `Explore → opus`

The engine already runs `Explore` on Opus when the session is above it. The row adds nothing to
the bill; it makes those spawns traceable, and their count decides whether a later
`"Explore": "sonnet"` is worth it.
With `CLAUDE_CODE_DISABLE_EXPLORE_INHERIT_CAP` set the engine runs `Explore` on the session's
model, so on a session above Opus the row does lower it — a real price change, not only a trace.

## Trace

Each spawn whose model the mod lowered writes one `subagent` line to the cost layer's runtime log
through `.claude/lib/costs/runtime-mark.sh` (opt-in: the directory must exist; `cost.py` does not
report these lines yet):

```bash
jq -c 'select(.type=="subagent")' "${AGENT_COSTS_HOME:-$HOME/.agent-costs}/runtime.jsonl"
```

`model` is the model core started, so a managed `availableModels` allowlist that maps an alias to
an older, dearer model is not detected by the mod but shows here.

## Limits

- Verified on engine 2.1.322; re-verify the built-in allowlist (`INHERIT_BUILTINS`) on an engine
  update — a built-in that later pins a model would be overridden.
- No effort control: `agent.spawn` carries no effort key.

## Tests

`claude plugin test .claude/skills/subagent-model`. Typecheck: point a scratch tsconfig at an
installed mod's `.claude-plugin/types/` (compiler options from its `tsconfig.json`, `include` this
mod's `hooks` and `tests`) and run `tsc -p` on it.
