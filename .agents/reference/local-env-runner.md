# Reference: local env runner (opt-in kit)

The contract for `.claude/lib/local-env/` — run a registered local test runner with one local dev
secret the agent never holds. Off by default: nothing runs until a project sets
`workflow.local_env: true` **and** the Operator completes §4. Engine: `local_env.py`.

## 1. What and why

Integration tests against a local database need its password; an agent must never hold it, and the
Operator should not type it per run. The Operator stores it once in an untracked file; the runner
hands it to one **registered** repo script, only in that child's environment, as one raw variable,
and masks it in the child's output.

## 2. The file

- `~/.config/<dir>/local.env`, mode **600**, in a dir with mode **700**, owned by you, no symlinks
  (file or dir). `<dir>` and the key name come from the config.
- One line `<key>=<value>`; comments (`#`) and blank lines allowed. Any other key, a duplicate,
  `export`, CR, NUL, non-ASCII or > 64 KiB → exit 65.
- Value: 8–256 printable ASCII characters, **no space and no braces** (braces are the mask's own
  bytes, so a mask can never complete a value from its neighbours).
- **Local/dev values only — never prod/stage.**
- Setup: the Operator runs `bash .claude/lib/local-env/local-env-init.sh` in their own terminal
  (needs a TTY; no echo; validates through the runner's `--validate-stdin`; atomic write). Rotation =
  re-run it (it asks before overwriting).

## 3. The registry (`.claude/local-env.json`)

Accepted only when **tracked and byte-identical to `origin/<Trunk>`** (the shared trust rule in
`.claude/lib/trunk-trust/trunk_trust.py`, the same as `guarded-writes.json`); each runner's
`script` must match trunk too. Template: `.claude/local-env.json.example`.

```json
{"v": 1, "dir": "<project>", "key": "LOCAL_DB_PASSWORD",
 "docker": {"compose_file": "docker/compose.yml", "service": "<db>", "port": 5432},
 "pass_env": ["<TOOLCHAIN_ROOT>"],
 "runners": {"<id>": {"script": "scripts/<x>.sh", "secret_env": "DB_PASSWORD",
                      "env": {"DB_HOST": "localhost"}, "args": {"--no-build": null, "--filter": "<regex>"},
                      "pass_line": "<x>-test: PASS", "results_line": "<x>: results in (/[^\\r\\n]+)"}}}
```

- `secret_env`: the child gets the secret as this one raw variable — no templating; the runner
  builds its own connection string with its own library.
- **The runner checks its own connection target.** The docker preflight proves where the
  infrastructure runs, not where the runner connects: a registered runner must refuse a non-local
  target itself (e.g. fail unless the host is `localhost`/`127.0.0.1`). Registration review checks it.
- `env`: plain non-secret values; `pass_env`: extra caller variables (toolchain roots), never a
  secret. Neither may name a variable that changes how a shell or interpreter starts (`BASH_ENV`,
  `SHELLOPTS`, `PYTHONPATH`, `LD_*`, `DYLD_*` …) or one of the fixed names below.
- `args`: the only flags accepted, each at most once; `null` = no value, a string = the value's
  regex (full match). Nothing else reaches the script.
- `pass_line` (optional): rc 0 counts only when raw stdout carried this exact line; otherwise exit
  75 — a skipped run is never a pass.
- `results_line` (optional): a regex whose one group names a results dir; after the run, files in
  it are scrubbed in place (→ `{hidden}`) when it is a real dir you own under `$TMPDIR`; otherwise
  a `results dir not scrubbed` note.
- `docker` (optional): see §5 step 3. Without it, no docker call is made.
- Keys starting with `_` are ignored; anything else unknown is refused.

## 4. Operator setup (once per machine and project — never an agent)

1. Fill `.claude/local-env.json` from the example, commit it, get it onto `origin/<Trunk>` through
   the project's normal review.
2. `workflow.local_env: true` in `.claude/project-profile.json`.
3. `bash .claude/lib/local-env/local-env-init.sh` in your own terminal.
4. The settings block — the Operator pastes it into `.claude/settings.json` (or
   `.claude/settings.local.json`); no command writes it. One `allow` line per runner id, exact ids
   only, never a wildcard over ids:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash .claude/lib/local-env/with-local-env.sh <id>)",
      "Bash(bash .claude/lib/local-env/with-local-env.sh <id> *)"
    ],
    "deny": [
      "Read(~/.config/<dir>/**)",
      "Edit(~/.config/<dir>/**)",
      "Bash(*.config/<dir>*)",
      "Edit(.claude/local-env.json)",
      "Write(.claude/local-env.json)",
      "Edit(.claude/lib/local-env/**)",
      "Write(.claude/lib/local-env/**)",
      "Edit(.claude/lib/trunk-trust/**)",
      "Write(.claude/lib/trunk-trust/**)"
    ]
  }
}
```

`allow` runs a registered runner with no click; put the same lines under `ask` instead to approve
every run — that trades convenience for a check on the code under test (§6, first point).
Merge into the existing arrays; do not replace them. The `<id> *` line exists only for runners with
`args`. Note the side effect: any Bash command naming `.config/<dir>` is denied.

## 5. Guarantees and checks (execution order)

1. Bash entry: `set +x`; refuses `BASH_ENV`/`ENV` (exit 64 — bash has sourced it by then, so this
   only makes the misuse visible; the child never inherits either); `exec python3 -I -B`. The secret
   is never in argv. Trust-rule `git` calls drop the caller's repo-redirecting `GIT_*` variables and
   ignore replace refs.
2. The switch and the trust rule (exit 78), then the runner id and its arguments (exit 64), then the
   script's trunk check (78), then `TMPDIR` (or `/tmp`) must be an existing absolute dir (64) — its
   realpath is the only scrub root and the child's `TMPDIR`.
3. Docker, **before the file is opened** (when `docker` is set): the context name from
   `docker context show`, pinned with `--context` on every call; its endpoint must be `unix://`
   (68); `compose ps <service>` must be `running` (69); `docker port <container> <port>/tcp` must
   list only that port on `0.0.0.0`, `127.0.0.1`, `[::]` or `[::1]` (68) — the container is on this
   machine; an any-interface bind (`0.0.0.0`, `[::]`) also exposes it on the network, so prefer
   `127.0.0.1:<port>:<port>` in the compose file. Docker runs with the clean
   env, so an inherited `DOCKER_HOST` is ignored.
4. File: dir `lstat` (real dir, yours, not group/other writable); `open(O_NOFOLLOW|O_NONBLOCK)`
   then `fstat` (regular, yours, exactly 600) — a FIFO or symlink is refused without hanging (77);
   missing → 66.
5. Parser and charset (§2, 65). No message quotes a line of the file.
6. Clean child env: only `PATH HOME USER LOGNAME TMPDIR LANG LC_ALL LC_CTYPE TERM`, the
   `pass_env` names, the runner's `env` and its `secret_env`. Anything else the caller had —
   another copy of the secret's variable, `SHELLOPTS`, `DOCKER_*` — never reaches the child.
7. Masking: stdout/stderr pumped through a boundary-safe literal replacer — the raw value and its
   XML-escaped forms → `{hidden}`; then the `results_line` scrub and the `pass_line` rule (§3).
8. INT/TERM are forwarded to the child's process group; after 30 s whatever is left of the group
   gets SIGKILL, even when the leader already exited. Exit 130. A consumer that closes early
   (`| head`) does not stop the drain, so the child never blocks on a full pipe.

Exit: the child's code · 130 INT/TERM · 64 usage / id / argument / `BASH_ENV` / `TMPDIR` · 65 file
format or charset · 66 file missing · 68 docker target not local · 69 compose service not running
or docker missing · 75 pass-line runner without its line · 77 file/dir owner, mode, type or symlink
· 78 switch off, config or script not approved on trunk.

## 6. Trust model / residual risks (honest)

- **The secret is handed to code under test.** The trunk check covers the registered script, not
  the tests, application or build files it runs from the working tree; a changed test can read its
  environment. `allow` means trusting that code; `ask` puts the Operator's eye on each run; only
  throwaway credentials for an isolated test database remove the exposure.
- The child can print the value in a split or encoded form; only the literal forms are masked.
- Files written outside the announced results dir are not scrubbed (e.g. a crash dump).
- The child's env is visible to same-uid processes (`ps eww`); same-uid code can read the file.
- SIGKILL of the wrapper itself (uncatchable) orphans the child group, and a descendant the runner
  leaves behind after a normal exit (a background server) keeps the secret in its env — a runner
  must stop what it starts.
- The script is checked against trunk before the docker preflight; a same-user process swapping it
  in between runs the swapped content (the same class as the first point).
- Offline, the local `origin/<Trunk>` ref is trusted; `git ls-remote` is bounded
  (`TRUNK_TRUST_LS_REMOTE_TIMEOUT`, default 20 s, no prompts) and falls back to that rule — the
  same limits as guarded writes (`guarded-writes.md` §5, first point).
- Claude deny rules are declarative, not isolation; registered scripts stay under code review.
- Codex is not configured by `.claude/settings.json`: its sandbox reads the whole disk unless the
  Operator denies `~/.config/<dir>` in their own Codex permissions.

## 7. Registering a runner

1. An entry under `runners` (§3) — the script checks its own connection target is local, and a
   runner whose skip path exits 0 gets a `pass_line`.
2. The `allow` (or `ask`) lines for its id (§4).
3. The change reaches trunk through review; until then the runner refuses.
