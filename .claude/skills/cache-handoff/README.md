# cache-handoff

Keeps a long session cheap and its state alive across compactions. Two pieces, one folder:

- **Status line** — `statusline.cjs`, wired by `.claude/settings.json → statusLine` (the command
  locates the repo through `CLAUDE_PROJECT_DIR`, else `git rev-parse --show-toplevel`, else `pwd` —
  the status-line contract documents no environment of its own): the context
  size fed into the last turn (gold → orange at 300k → red at 500k), the prompt-cache warmth
  (`▰▰▰ 58 min` warm, `▰▱▱` cooling in the last sixth of the TTL, `▱▱▱ cold`), and the model.
- **`/hc [focus]`** — `/compact` with state-keeping instructions (running and scheduled work,
  owner decisions, tickets, production state, files that are not auto-loaded, the exact next
  step). Compaction runs from a timer after the command returns — it cannot run under a running
  turn. Above the prompt a band with a **Compact (/hc)** button appears once the context passes
  `bandAtTokens` (default 500k); it turns primary when the cache is about to lapse.
- **Auto `/hc`** — fires by itself when the session is idle and the prompt cache is about to
  expire: `autoHcMinutes` (default 5) before expiry when the context is at least `bandAtTokens`,
  and `autoHcForceMinutes` (default 2) before expiry whatever the size (1h TTL only). Compacting on
  a warm cache is the cheapest moment; one lapse fires it once. `0` turns either off.

Options (`userConfig`): `cacheTtl` (`1h` on a subscription, `5m` in overage), `bandAtTokens`,
`autoHcMinutes`, `autoHcForceMinutes`. The cache clock is the last main-thread response; after a
reload it is seeded from the session transcript under `~/.claude/projects/`.

Loaded automatically in a trusted project, like `stage-handoff`. Tests: `claude plugin test
.claude/skills/cache-handoff` (the `.claude-plugin/types/` folder the engine writes is git-ignored).
