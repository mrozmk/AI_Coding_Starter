# Reference: remote build check (opt-in kit)

The contract for `.claude/lib/remote-build/` — run the project's build/test command on a remote node
over ssh, never locally. Off by default: nothing runs until a project sets
`workflow.remote_build: true` **and** the Operator completes §4. Engine: `remote_build.py`.

## 1. Threat model first

**The node must be a machine for untrusted code. The host alias can be changed only through
Trunk.**

- What runs on the node is the configured command in a fresh worktree of the commit under test —
  so arbitrary code from that commit, written by an agent. Use a dedicated account with no secrets,
  no production credentials and no write access that matters; ideally a disposable machine.
- The team merge check runs `build_check` without asking anyone, in a team clone, at a commit from
  an agent's branch. If the node were read from that clone, the branch could point it at any alias
  in the Operator's `~/.ssh/config` — a production host included — and the check would ship and run
  its code there. A clone is agent ground in every respect (its working tree, its `origin`, its refs,
  its git config), so **nothing is read from it but HEAD and the objects to bundle**.
- The kit runs **from the main checkout**, and that checkout is its trust root: the team harness sets
  `HARNESS_MAIN` (the main checkout's root, where the profile is loaded from — always that value,
  never an inherited one) for the merge check and the role sessions; `build_check` names
  `$HARNESS_MAIN/.claude/lib/remote-build/…`. The switch, `.claude/remote-build.json` and the node
  script are read in the repository the kit lies in, and the config and node script count only when
  **tracked and byte-identical to its `origin/<Trunk>`** (the shared rule in
  `.claude/lib/trunk-trust/trunk_trust.py`; the Trunk name comes from `CLAUDE.md` on origin's default
  branch — `guarded-writes.md` §1). A branch's own config is simply ignored.
- The kit refuses (78, no ssh call) when its own file lies inside the repository it checks
  (compared by inode, so a symlink or another letter case does not slip past). A build check run by
  hand — the pipeline's manual merge step, a worker smoke — needs `HARNESS_MAIN=<main checkout root>`
  set first; unset, the path reads `/.claude/…` and the check fails (127) without running anything.
- Unattended runs meet a main checkout nobody fetched since the last merge into trunk; so before
  verifying, the kit fetches a stale `origin/<default>` and `origin/<Trunk>` there once — those
  remote-tracking refs only, fast-forward only, bounded (`TRUNK_TRUST_LS_REMOTE_TIMEOUT`), no
  prompts. A failed fetch is not an error: the usual online/offline rule then decides.

## 2. What it does

Called as `teams.build_check: "bash \"$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh\""`
(no arguments — the command lives in the config), with cwd = the clone checked out at the commit
under test:

1. the kit's own location outside that repository; then, in the main checkout, the switch, a
   bounded fetch of stale trunk refs and the trust rule (exit 78); arguments → 64;
2. `ssh <alias> exit` preflight — unreachable → 75, no command ran, **never a local fallback**;
3. asks the node which commits its repo already has (refs and worktree HEADs) and builds an
   incremental `git bundle` of a temporary `refs/mc/<tag>` without them (empty when the node has the
   commit); sends it with `ssh <alias> 'mkdir -p <runs> && cat > <runs>/<tag>.bundle'`;
4. sends the node script **on ssh stdin** (`ssh <alias> bash -s -- <args>`; it is never stored on the
   node): fetch the bundle into `<repo>` (and point `refs/remote-build/last` at the sha, so the next
   bundle can leave it out), add a throwaway detached worktree of the sha under
   `<runs>`, run the argv in `<cwd>` with `env` (and `nice -n 19` when `nice`), stdin `/dev/null`,
   in its own process group, stopped after `timeout_s` (TERM, then KILL after 5 s → exit 124);
5. streams the output, prints `node exit <rc>` and exits with it; the worktree, the bundle and the
   local temp ref are removed on every exit.

Exit: the command's code · 124 timed out · 75 node unreachable, transfer or node-side setup failed
(no command ran; ssh's own failure, 255, also reads 75 — so does a command exiting 255) · 78 switch
off, config invalid or not approved on trunk, node script not on trunk · 64 called with arguments.

## 3. Config (`.claude/remote-build.json`)

Template: `.claude/remote-build.json.example`.

```json
{"v": 1, "host": "<ssh-alias>", "repo": "build/<project>", "runs": "build/runs", "cwd": ".",
 "command": ["make", "test"], "env": {"NAME": "value"}, "nice": true, "timeout_s": 3600}
```

- `host`: **one ssh alias** (`[A-Za-z0-9._-]`, never starting with `-`); user, port, key and jump
  hosts belong in the Operator's `~/.ssh/config`.
- `repo`, `runs`, `cwd`: relative paths (`repo`/`runs` under the node account's home, `cwd` inside
  the repo), no `..`; `runs` differs from `repo`.
- `command`: an **argv list**; each element is quoted for the remote shell and arrives as one
  argument — no shell line anywhere. `env`: `[A-Z_][A-Z0-9_]*` → string.
- `nice` (default true), `timeout_s` (1–86400, default 3600). Keys starting with `_` are ignored;
  anything else unknown is refused.

## 4. Operator setup (once — never an agent)

1. A node account for untrusted code (§1), reachable with an alias in your `~/.ssh/config` that uses
   a key dedicated to it. Accept its host key once by hand; the kit never does.
2. On the node: `git init <repo>` (the first run sends a full bundle). A POSIX shell with `bash` and
   `git`. A Windows node: run sshd inside a WSL distro, or set OpenSSH's `DefaultShell` to WSL bash.
3. Fill `.claude/remote-build.json` from the example, commit it, get it onto `origin/<Trunk>` through
   the project's normal review.
4. `workflow.remote_build: true` in `.claude/project-profile.json`; `teams.build_check` as in §2 —
   with the literal `$HARNESS_MAIN`, never an absolute path (the profile is shared and committed).
5. Optional, pasted by the Operator (no command writes it) so the kit stays the only route:

```json
{"permissions": {"deny": [
  "Bash(ssh <alias> *)", "Bash(scp * <alias>:*)",
  "Edit(.claude/remote-build.json)", "Write(.claude/remote-build.json)",
  "Edit(.claude/lib/remote-build/**)", "Write(.claude/lib/remote-build/**)",
  "Edit(.claude/lib/trunk-trust/**)", "Write(.claude/lib/trunk-trust/**)"
]}}
```

## 5. Guarantees and limits (honest)

- ssh always runs with fixed options only — `BatchMode=yes`, `ConnectTimeout`, `ServerAliveInterval`
  — and `--` before the alias. **Host-key checking is never disabled, and no ssh option is taken from
  the config.** Neither a key nor a user name is in any argv; the kit writes no log — it prints one
  header line (sha, alias, bundle size) and streams the node's output, whose content is the
  project's concern.
- The trust rule is a hurdle, not isolation (`guarded-writes.md` §5, first point): offline, local
  refs are trusted, `origin/HEAD` included; the caller's `PATH` and ssh configuration are trusted.
- **The main checkout must stand on reviewed code**: the kit, `trunk_trust.py` and the profile are
  taken from it; the optional deny lines guard its working tree, nothing more.
- The main checkout's working copies of the config and the node script must equal trunk: after a
  change to either reaches trunk, the main checkout pulls it, or the check refuses (78) — the kit
  fetches remote-tracking refs, never the working tree.
- Solo use from the same checkout is refused (the kit lies inside the repository it would check); a
  solo mode is a separate decision.
- A killed wrapper or a dropped connection leaves the node's run to the node script's trap; the
  local side gives up after `timeout_s` + 300 s (exit 75).
- The incremental bundle trusts the node's answer about what it has: a node that lies gets a bundle
  it cannot use, and the run fails (75) — it cannot change what runs.
