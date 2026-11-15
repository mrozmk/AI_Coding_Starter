# Session host — the driver contract

`.claude/lib/session-host.sh` (CLI) and `.claude/lib/session-host-lib.sh` (sourced form) are the one
seam between the team layer and a terminal multiplexer. Every start, liveness probe, screen read,
key, typed text, doorbell, stop and attach hint goes through them. `/roles` (`roles.sh`) and the
team runner are their main callers. `session-host-layout.sh` places running terminals in the
Herdr window.

Verified on `hc 0.1.20` and `herdr-app 0.1.15`. Herdr rewrites its docs with every update; re-read
`hc --skill` and `herdr-app commands` before you change the Herdr backend.

This reference supersedes the launch parts of [supervisor-sessions.md](supervisor-sessions.md) (`up`,
`here`) and [team-watch.md](team-watch.md) as the delivery mechanism. The rest of those two files
still describes live code until the release that retires it.

## 1. Purpose

- **One seam.** Callers hold addresses; session names, backends and handles exist only inside the
  driver. A direct `tmux` call anywhere else in `.claude/lib` or `.claude/hooks` fails part host
  (35). The two permanent exceptions are the prompt-time hooks `session-registry.sh` and
  `inbox-count.sh`: a hook must not pay for sourcing the driver, so each reads its own terminal's
  handle through `$TMUX`'s socket.
- **Two backends**, tmux and Herdr (herdr-core through `hc`), plus `none`: a plain terminal taken by
  `roles.sh here`. That terminal has a registry record, but no screen the driver can read or type
  into.
- **The Operator decides.** The driver reports dialogs and never answers them (§11). It never
  forces a send, never stops or restarts herdr-core, and never keeps a lost program alive as a
  shell.

## 2. Addresses and names

| Address | Kind | Session name |
|---|---|---|
| `<Role>` (leading capital: `Supervisor`, `Fable`, `Astra`, any `teams.sessions` key) | role | `<prefix>-<role lowercase>` |
| `<team>-<role>` (`alfa-coder`, `alfa-lead`) | team | `<prefix>-<team>-<role>` |
| `helper:<name>` | helper | `<prefix>-<name>` (a name already starting `<prefix>-` is taken as is) |
| `adhoc-<handle>` | adhoc | none: registry only, never started or rung |

- **Prefix** (`sh_prefix`):
  - `teams.session_prefix` when it is set; it must match `^[a-z0-9][a-z0-9_-]{0,11}$` or the
    driver refuses it;
  - else `teams.channel.tmux_prefix`;
  - else the repo directory's slug.

  A derived prefix is lowercased and cut to 12 characters, with one warning per process. Two
  checkouts on one machine therefore never share a name. A name that collides with another
  checkout's live session is refused with "set a different teams.session_prefix".
- **Names** are `[a-z0-9_-]`, at most 32 characters.
- **Old names, for one release:** `sh_target` resolves a live session through, in order:
  - its record's `name`;
  - else the prefixed name;
  - else the name it had before session prefixes, while that session is alive and
    `TEAM_HOST_LEGACY_NAMES` is not `0`.

  So a run started before the upgrade is not orphaned.
- **Herdr labels** on every terminal the driver starts: `harness=<prefix>`, `kind=<kind>`,
  `address=<address>`, plus `team=<team>` for a team address. `hc run --name <name>` names the
  terminal. After start, a Herdr session is addressed by its record's `handle` (`t7`): names are
  unique only among live terminals.
- **Pane title (Herdr):** Herdr's pane header shows the terminal title the program set. A shell
  launch line first sets that title to the address (OSC 2), so the header does not read `sh` while
  the CLI starts. A CLI may set its own title once it runs.

## 3. Backend selection

| Setting | Effect on a fresh start |
|---|---|
| `teams.session_host: "tmux"` | tmux; rc 6 "no session host: install tmux or Herdr" without it |
| `teams.session_host: "herdr"` | Herdr; rc 6 "herdr core not answering" when `hc server status` does not answer within 3 s |
| `teams.session_host: "auto"` (default) | **tmux today.** `auto` probes Herdr first only once the switch `SH_AUTO_HERDR` in `session-host-lib.sh` is `1`; it stays `0` until the Herdr backend has passed a live check |
| `TEAM_SESSION_HOST=auto\|herdr\|tmux` | overrides the profile key for this process |

- **Each session keeps the backend recorded at its start** for its whole life. A verb on an address
  with no record uses tmux: a session from before the driver. A fresh start after the previous
  instance is gone uses the configured backend, not the old record's.
- `bash .claude/lib/session-host.sh --check-host` prints the backend a fresh start would use, or the
  reason it cannot start (rc 6).
- **Fixture rule:** under `TEAM_SMOKE=1` only binaries inside `TEAM_SMOKE_BIN_DIR` run (`tmux`, `hc`,
  `herdr-app`; `TMUX_BIN`, `HC_BIN` and `HERDR_APP_BIN` name them). A test never reaches the
  machine's real server. Part host turns the `auto` probe on for itself with
  `TEAM_SMOKE_AUTO_HERDR=1`, and only under `TEAM_SMOKE=1`.

## 4. Verbs

`bash .claude/lib/session-host.sh <verb> <address> [options]`. Common options:
- `--main <dir>`: the main checkout; else `HARNESS_MAIN`, else the parent of `HARNESS_REGISTRY`,
  else the git toplevel, which is refused inside a team clone;
- `--team-dir <dir>`: for a team address without a record;
- `--lock-held <owner>`: see §6;
- `--owner <text>`: the owner text written into the lock.

Exit codes: `0` ok · `2` usage · `3` gone · `6` no host · `9` blocked · `10` skipped (lock held,
input not safe) · `1` other.

| Verb | Contract | tmux | Herdr |
|---|---|---|---|
| `start --kind role\|team\|helper --cwd <dir> --cli claude\|codex\|script [--env K=V]… [--claude-home auto] [--program <exe>] [--session-id <id>] [--wait-ready] [--no-probe] -- <argv…>` | Start the address if it is not running; write the registry record; print the name. `1` when it is already running (with its hint) or the name belongs to another checkout | `new-session -d -s <name> -c <cwd>` with `-e` words. The caller's `CLAUDECODE*` and messaging variables are dropped. `CLAUDE_CONFIG_DIR` is unset unless `--claude-home auto` passes one | `hc run --bg --no-parent --json --name <name> --cwd <cwd>` with the labels. Every variable is a word for `/usr/bin/env`, because an hc terminal gets the login session's environment, not the caller's. The record keeps `handle` and `created_ms` |
| `alive` | `0` alive · `3` gone · `1` the probe failed. With a recorded `program`, alive also means that program runs in the foreground: a role's `; read` shell left after an exit is gone | `has-session`; `pane_current_command` | `hc get`: state `live`, and the program is `foreground.argv[0]`/`.name` or in the foreground process group |
| `status` | One JSON line `{state, kind, msg, source}`. `state`: `starting · idle · working · done · blocked · error · unknown · gone` | Claude: the hook's state file (§8). A permission prompt's `msg` is `<tool>: <detail>` from the transcript's open tool call. Codex and script: `unknown` while alive | The program's own status (`status.state/kind/msg`), Codex included; `null` → `starting`. The screen is never read for this |
| `read [--lines N \| --history N]` | The last non-empty lines, or screen plus scrollback | `capture-pane` | `hc read`. While working, blocked or in error, `--history` returns the screen only |
| `keys [--target <pane>] <key…>` | Keys from a fixed list (`enter esc up down tab ctrl-c ctrl-e ctrl-u` and tmux's own names); anything else is refused, never typed. Under the target lock | `send-keys` | `hc keys` |
| `type [--target <pane\|handle>] <text> [--enter]` | Literal text. Under the target lock | `send-keys -l`, then Enter when asked | `hc send`: pasted and submitted in one step (prints `typed+submitted`). Refused with `9` on an open prompt, and for an agent with no status yet (a startup dialog may be open) |
| `send <one line> [--reg <file>]` | The doorbell (§12). `0` delivered · `3` gone · `9` blocked or starting · `10` skipped. Refused for `adhoc-*` (`3`) and script sessions (`2`) | Socket, else typed on an idle empty input | Socket, else `hc send` under the target lock, never forced |
| `kill [--graceful <secs>]` | `0` ended (or never ran) · `1` still alive. Graceful: `/exit` only on an idle input and under the target lock, then a kill | `send-keys /exit Enter`, then `kill-session` | `/exit` through `hc send` with `HC_TERMINAL_ID` unset, only on an `idle` or `done` status; then always `hc kill` and `hc rm` |
| `hint` | One line for a person: how to look at the session | `tmux attach -t <name>`, prefixed `TMUX_TMPDIR=<dir>` when the hinting process has one | `hc attach <handle> · herdr: <name> (in the agent list once placed)`; a replaced terminal: "nothing to attach" |

- **Backend `none`** (a plain terminal from `roles.sh here`):
  - `read`, `keys` and `type` refuse with `1` ("no screen to read or type into");
  - `send` works through the socket only, else it skips and logs;
  - `kill` sends SIGTERM to the recorded CLI;
  - `hint` reads "a plain terminal (tty …)".
- A Herdr record whose terminal was replaced under the same handle (another `created_ms`) reads as
  gone. Nothing acts on the new terminal.

## 5. Lib-only helpers

Sourced callers use these; they are not CLI verbs.

| Helper | Use |
|---|---|
| `sh_gen <name>` · `sh_gen_addr <main> <address>` | The session's generation: `<pane_id>@<session_created>` (tmux) or `<handle>@<created_ms>` (Herdr). A replaced session is a new value |
| `sh_read_target <target> [--history N] [--escapes] [--squeeze]` | A capture by a resolved tmux target (a pane id such as `%1`). `team-answer.sh` reads the colours with `--escapes` |
| `sh_pane_pid <main> <address>` | The foreground pane's pid (Herdr: the terminal's root program), for the TeamLead ownership probe |
| `sh_inbox_session <main> <inbox address>` | The session an inbox write rings: a role → itself; a team → `<team>-lead` |
| `sh_alive_addr`, `sh_read_addr` | `alive` / `read` with the record's backend, for the `team-lib.sh` wrappers |
| `--host tmux` on `start` | Pins tmux (team-watch's helpers, until that daemon is retired) |

## 6. Locks

- **One target lock per address**, taken by `keys`, `type`, `send`'s typed fallback and a graceful
  `kill`:
  - team address: the team's send lock (`team_send_lock <team dir> <role>`);
  - role or helper: `<registry>/<address>.lock`, the same `mkdir` primitive.
- **Never reclaimed automatically:** two contenders could both end up inside. The holder is named
  instead: "skipped — target lock held by <owner>", exit `10`.
- **`--lock-held <owner>`:** the caller already holds the lock for a multi-step transaction (for
  example the runner answering a prompt). The verb checks that the holder file names exactly that
  owner and does not take the lock again. If someone else holds it, the verb skips with `10`.
- **Wait:** `TEAM_SEND_LOCK_WAIT` (30 s).
- **Log:** a stop while the lock is held kills the session without `/exit`, logs
  `stop-during-send`, and warns.
- **Per-target log:** `send-<role>.log` in the team dir, or `send-<address>.log` in the registry.
- **Other locks:** `roles.sh` holds `registry/roles.lock` while it starts roles, and placement holds
  `registry/layout.lock` while it looks up or creates the space and tabs.

## 7. "Blocked" per backend

| | tmux | Herdr |
|---|---|---|
| Source | Claude's hooks: `permission_prompt`, `elicitation_dialog` and `agent_needs_input` → `blocked` with kind `permission`, `question` or `input` | The program's status `blocked` (OSC 7501), Claude and Codex alike |
| Prompt detail | The transcript's open tool call (`team_prompt.py pending-tool`), never the screen | `status.msg` |
| `send` on blocked | No doorbell, `9`, logged `doorbell-blocked`. The message stays in the inbox and the prompt hook shows it | The same |
| `type` on blocked | Typed only on a recognised idle empty input; an open prompt is never typed into | Refused with `9`: `hc send` would answer the prompt |
| Startup dialogs | Read from the screen (§11) | No status while a dialog is open: `type` and `send` refuse with `9` ("starting"); the screen tells which dialog |
| "Other" answer into an open prompt | Typed as before | `team-answer.sh other` falls back to `deny` plus a message to the stage |

## 8. The status state file (tmux)

- **Written by `team-status.sh`** (hooks Notification, UserPromptSubmit, PostToolUse, Stop and
  SessionEnd) for a session the driver started (`HARNESS_ADDRESS` in its launch environment):
  `<registry>/state/<address>.json` `{state, kind, at, session_id, transcript_path}`, tmp + mv.
- **States:** `working` (prompt, tool), `done` (Stop), `idle` (`idle_prompt`), `blocked` (with its
  kind). SessionEnd removes the file.
- **Stale writes are dropped:** a write from a session id other than the record's `session_id` is a
  leftover of a replaced session.
- **Under Herdr nothing is written:** the program reports its own status there.

## 9. Environment

| Variable | Set by | Meaning |
|---|---|---|
| `HARNESS_ADDRESS`, `HARNESS_MAIN`, `HARNESS_REGISTRY`, `HARNESS_BACKEND` | `start`, in the launch environment | The hooks find the session's record and state file through them |
| `CLAUDE_CONFIG_DIR` | `start --claude-home auto` (`team_claude_home`) | Never inherited: unset when none is passed, because a tmux server may carry another project's value |
| `TEAM_SESSION_HOST` | the caller | Overrides `teams.session_host` |
| `TMUX_TMPDIR` | the project (`env` in `.claude/settings.local.json`) | A per-project tmux server. The `hint` names it, so a plain Terminal reaches that server |
| `HC_TERMINAL_ID` | Herdr, in every hc terminal | An `hc send` from inside an hc terminal arrives wrapped as `<hc from=…>`, so a slash command reads as text. The driver sends `/exit` with it unset (`sh_hc_bare`). A person or script typing a slash command into another Herdr terminal from inside one must unset it too, or use `session-host.sh type` |
| `TEAM_HOST_READY_SECS` (20) | the caller | How long `--wait-ready` looks for a first sign of life |
| `TEAM_ROLES_TRUST_SECS` (8) | the caller | How long `/roles` looks for a startup dialog |
| `TEAM_HOST_LEGACY_NAMES=0` | the caller | Turns the pre-prefix name fallback off |

## 10. Registry record and hooks

- **One file per address:** `<main>/.agents/team/registry/<address>.json`, 0600 in a 0700 directory,
  tmp + mv.
- **Fields written by `start`:**
  - `address`, `kind`, `backend`, `handle`, `name`, `cwd`, `cli`, `started_at`;
  - when given: `program`, `session_id`, `team_dir`, `created_ms` (Herdr).
- **Fields written by others:**
  - `roles.sh stop` adds `stopped_at`;
  - `roles.sh here` writes the terminal's own handle, or for a plain terminal `pid`, `pid_start` and
    `tty`.
- **`session-registry.sh`** (SessionStart; also SessionEnd):
  - a driver-started session: its record gets the live `session_id` (`/clear` and resume issue a
    new one) and `last_seen`. With Claude's messaging socket in the environment it also writes
    `<address>.reg.json` (socket, token, pid, session_id, the doorbell's registration) and names
    it in the record's `reg`;
  - a TeamLead in its clone: the identity guard, `teamlead.json`, the `<team>-lead` record, and
    `<team>-lead.reg.json` in the main registry;
  - a role session (`TEAM_SESSION_ROLE`): the contract line on every source, so the role is back in
    context after `/clear` and compaction;
  - any other Claude session in the main checkout, inside tmux or Herdr: an ad-hoc record
    `adhoc-<handle>` (handle, name, tab, cwd, session_id, claude pid). SessionEnd adds `ended_at`
    and `end_reason`. Records not seen for 14 days whose terminal is gone are pruned. A plain
    terminal gets no record.
- **`inbox-count.sh`** (UserPromptSubmit): one line `inbox: N waiting — …` when the session's inbox
  holds messages, and `last_seen` at most once a minute.
- **`team-status.sh`:** §8.

## 11. Startup prompts

| Screen | Recognised by | What happens |
|---|---|---|
| Claude's folder trust dialog | "Do you trust the files in this folder?" or "Yes, I trust this folder" | **Reported, never answered.** `--wait-ready` warns `waiting at the folder trust dialog — accept it once in <hint>`; `/roles` prints `started (needs trust — pick Yes; Enter alone exits)`. Under Herdr the dialog's first option is `No, exit`, so Enter alone ends the role: pick `Yes, I trust this folder` explicitly. Under tmux the dialog's default has not been checked; the same line is printed there |
| Codex trust prompt | "trust" and "folder" on one line, or "Trust and continue" | As Claude's trust dialog |
| Claude's MCP servers dialog | "new MCP servers found in this project" | **Reported, never answered.** `--wait-ready` warns `waiting at the MCP servers dialog — answer it in <hint>`; `/roles` prints `started (startup dialog open)`. Under Herdr `type` and `send` refuse with `9` while it is open |
| Codex update prompt | "Update available", or "Update now" with "Skip" | The only dialog that gets a key: `esc` once (non-destructive, skips the update) |
| Herdr: no status and no recognised screen | after `TEAM_ROLES_TRUST_SECS` | `/roles` prints `started (no status yet)`; no dialog is claimed |

The trust dialog is the Operator's decision and is never auto-accepted, whatever the folder.

## 12. The doorbell

`send <address> <one line>` rings a session that a message waits in its inbox. The message itself is
the inbox file; the line only wakes the session.

1. **Blocked → no ring.** A session in `blocked` gets no doorbell (`9`, logged `doorbell-blocked`).
   The prompt hook shows the inbox count when the person answers.
2. **The messaging socket.** The session's registration (`reg` in its record, else
   `<address>.reg.json`) is passed to `team-watch-send.py`. The wire format is an auth line, then
   one user line; there is no ack. The socket must be a socket file of mode 0600 owned by this uid.
   That mode is the only trust boundary, so a wider one is refused, never used. This path is safe
   against a person's draft and against dialogs.
3. **The typed fallback, no registration:**
   - **tmux:** the line is typed only on a recognised idle, empty input, under the target lock.
     Otherwise skip (`10`).
   - **Herdr:** `hc send` under the target lock, never forced. A terminal with no status yet is not
     rung (a startup dialog may be open; `9`). Herdr cannot see a person's unfinished draft:
     `hc send` waits for it and then submits it merged with the line. The owner accepted this
     (2026-11-15). The first such send per session logs `doorbell-draft-unsafe <address>`.
   - **Plain terminal:** skip and log.
4. Every skip logs `doorbell-skipped <utc> <why> — <line>` in the per-target log (§6). The per-run
   TeamLead's own doorbell (`team_session_doorbell`) follows the same three steps and log line.

## 13. `/roles`, restore, and what is not restored

- **`bash .claude/lib/roles.sh [up [<Role>]] | status | stop [<Role>|all] | here <Role> | resume
  <Role> | runs [--json] | place <address>`.** Roles are `teams.sessions` in
  `.claude/project-profile.json`. Exit codes: `0` · `1` a role failed or another `/roles` runs · `2`
  usage · `6` no session host.
- **`up`** (idempotent, one role at a time) does three things:
  - starts every standing, enabled role that is not running (a Claude role as
    `claude --name … --session-id <new> … -- <bootstrap line>; read`);
  - lists the interrupted team runs (`/start-team <team>` resumes one, and resuming is optional);
  - prints a resume line for each gone ad-hoc conversation
    (`<tab or tmux name> — cd <cwd> && claude --resume <session_id>`).
- **`resume <Role>`** starts a gone Claude role on its previous conversation (`--resume <id>`), with
  no bootstrap line; when `inbox/<Role>/new` holds messages it rings the role once
  (`inbox: N waiting — reconcile …`) and prints `inbox N rung`, `inbox N waiting — ring <rc>`, or
  `ring deferred (still starting)` under Herdr. The ring never changes the exit code. A
  Codex role restores fresh only; to continue its last conversation, run `codex resume --last` by
  hand in the main checkout.
- **`place <address>`** (Herdr) puts a running terminal into its tab:
  - a role into its `place.tab` (`Lead` for the shipped roles: the `main` slot left, `side` roles
    stacked right);
  - a team session into the space's single **`Teams`** tab, by label adoption, as a new column on
    the right. The runner places each team's TeamLead and the stage that runs now; a stage's pane
    closes when its program exits.

  Placement never ends a terminal, never moves the focus from a runner, and never creates a space
  from a runner. A failure warns and prints the hint. Under tmux it only prints the hint.
- **Not restored:**
  - the conversation context of a role by default (`roles.sh resume <Role>` on request);
  - Codex conversations;
  - open dialogs and half-delivered answers (the runner and the TeamLead re-derive them from the
    records);
  - tmux scrollback;
  - sessions of other checkouts;
  - Herdr placement of ad-hoc tabs, and the ad-hoc conversations themselves (resume lines only).

## 14. Assumptions pending the owner

The spec's open questions have since been answered by the owner (2026-11-15). The behaviour above
follows those answers:

| Question | Decision |
|---|---|
| Doorbell under Herdr without a socket | A person's window is rung through `hc send` even when a draft may merge; logged once per session (§12) |
| Folder trust dialog | Never auto-accepted (§11) |
| "Other" answers into an open prompt under Herdr | `deny` plus a message to the stage (§7) |
| Ad-hoc sessions after a crash | Resume lines only, nothing reopened (§13) |
| What the `Teams` tab shows | Per team, its TeamLead and the stage working now, in one `Teams` tab (§13) |

Still open, so these may change:

- **`auto` → Herdr:** `SH_AUTO_HERDR` stays `0` (so `auto` = tmux) until the Herdr backend passes a
  live re-check. Flipping it is a separate change.
- **A tab per team** instead of the single `Teams` tab is under the owner's decision. That decision
  also has to settle a team named `Lead`, which would collide with the `Lead` tab.
- **Pane title:** whether Claude Code and Codex keep the OSC 2 title the launch line sets, or
  replace it with their own, is still to be checked live (§2).
