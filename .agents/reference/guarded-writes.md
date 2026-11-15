# Reference: guarded cloud and database writes (opt-in kit)

The contract for `.claude/lib/guarded-writes/` — three wrappers through which an agent may change
cloud or database state, each call an Operator click. Off by default: nothing runs until a project
sets `workflow.guarded_writes: true` **and** the Operator completes §3. Engine: `guarded_write.py`.

## 1. Policy

- **Reads are free; writes go only through the wrappers; DROP/TRUNCATE of a table, database or
  schema never by an agent** — such a statement is handed to the Operator.
- The real barrier is a **read-only default identity**: the plain `az` login and the default SQL
  user can read but not write, so any path that slips past a rule (another spelling, a subshell, an
  SDK) gets a 403. The wrappers switch to a separate **write profile** (`$HOME/.azure-write`), and
  the settings `ask` rule makes every wrapper call an Operator click.
- The allow-lists live in `.claude/guarded-writes.json`, and a wrapper accepts it only when it is
  **tracked and byte-identical to its version on `origin/<Trunk>`** (Trunk from the `CLAUDE.md`
  Branch model): widening what an agent may write needs a change that reached trunk.

## 2. The wrappers

| Wrapper | Runs | Refuses |
|---|---|---|
| `az-write.sh <az args>` | an `az` operation listed in `az.ops`, or `az rest` within `az.rest` | an unlisted operation or option, an abbreviation, a duplicate, a missing `required` option, a value outside its `pin`, `--ids`, `@file` values, profile overrides; for `rest`: `--headers`, `--output-file`, dot segments, a URL outside every `url_prefix` or a method not listed |
| `ops-write.sh [--confirm WORD] <script> [args]` | a deployment script listed in `ops.scripts`, with `WORD` (one of `ops.confirm_words`) fed to its typed confirmation on stdin | an unlisted script, a script whose working copy differs from trunk, `@file` values, `ops.deny_args` (e.g. a flag that reads a secret — the Operator runs those) |
| `sqlcmd-write.sh -S <server> -d <db> (-i <file> \| -Q "<sql>")` | plain SQL on a server in `sql.servers` (and a database in `sql.databases` when set), via `sqlcmd --authentication-method ActiveDirectoryAzCli -b` | sqlcmd directives (`:r`, `:setvar`, `:connect`, `!!`, `ED`, also behind a BOM) and `$(variables)`; `USE`, and a name of four parts or of three whose database is not `-d`; any option beyond `-S -d -i -Q -h -s -w -W` (so no `-U`/`-P`/`-G`, no output file, no `-V`); whatever the destructive-SQL classifier (`.claude/hooks/lib/guard_destructive_sql.py`) denies; a classifier failure (fail closed) |

Every wrapper:
- runs the tool with a **clean environment** — `PATH HOME USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR
  TERM`, plus `AZURE_CONFIG_DIR=$HOME/.azure-write` and `AZURE_EXTENSION_DIR=$HOME/.azure/cliextensions`;
- logs to `$HOME/.agent-ops/<wrapper>.log` (owner-only): time, cwd, the call with secrets masked
  (password/secret/token/key-like options, `NAME=VALUE` settings, request bodies, JSON values,
  bearer tokens, SQL string literals), then the exit code;
- exits 2 on a refusal, otherwise with the tool's own code.

`sqlcmd-write` classifies and runs **the same bytes**: the statement is copied to a private file,
classified, and that copy is what sqlcmd executes. `-b` makes a SQL error a non-zero exit.

## 3. Operator setup (once per machine and project — never an agent)

1. **Read-only default identity:** the account behind the plain `az login` holds a Reader role on
   the subscriptions the project touches; the default SQL login is a read-only database user.
2. **Write profile:** `AZURE_CONFIG_DIR=$HOME/.azure-write az login` with the identity that holds
   the write roles the allow-list needs — nothing broader. For SQL, that identity is the Entra user
   with write rights; **it must lack DDL rights such as DROP/ALTER** — the classifier is a regex and
   cannot see dynamic SQL, so the ban on DROP/TRUNCATE is only as strong as these permissions.
3. **`sqlcmd`:** the Go `sqlcmd` (it supports `ActiveDirectoryAzCli`); the ODBC one refuses that
   method, so the wrapper fails instead of picking another identity.
4. **The allow-list:** copy `.claude/guarded-writes.json.example` to `.claude/guarded-writes.json`,
   fill it, commit it, and get it onto `origin/<Trunk>` through the project's normal review.
5. **The switch:** `workflow.guarded_writes: true` in `.claude/project-profile.json`.
6. **The settings block** — the Operator pastes it into `.claude/settings.json` (or
   `.claude/settings.local.json`); no command writes it:

```json
{
  "permissions": {
    "ask": [
      "Bash(bash .claude/lib/guarded-writes/az-write.sh *)",
      "Bash(bash .claude/lib/guarded-writes/ops-write.sh *)",
      "Bash(bash .claude/lib/guarded-writes/sqlcmd-write.sh *)"
    ],
    "deny": [
      "Bash(*AZURE_CONFIG_DIR=*)",
      "Bash(*.azure-write*)",
      "Edit(.claude/guarded-writes.json)",
      "Write(.claude/guarded-writes.json)",
      "Edit(.claude/lib/guarded-writes/**)",
      "Write(.claude/lib/guarded-writes/**)"
    ]
  }
}
```

Merge the entries into the existing arrays; do not replace them. A project may add deny rules for
the direct write verbs it cares about (e.g. `Bash(az webapp deploy *)`), so the wrapper stays the
only route even where the identity would allow more.

## 4. Config (`.claude/guarded-writes.json`)

```json
{
  "v": 1,
  "az": {
    "ops": {"<command words>": {"options": [], "multi": [], "required": [], "pin": {}, "aliases": {}}},
    "rest": [{"url_prefix": "https://<host>/<path>/", "methods": ["patch"]}]
  },
  "ops": {"scripts": ["scripts/<deploy>.sh"], "confirm_words": ["APPLY"], "deny_args": ["--set-secret"]},
  "sql": {"servers": ["<server>"], "databases": ["<db>"]}
}
```

- `options`: the only options accepted (besides `--subscription --query --output --only-show-errors`);
  `multi`: options that take several values; `required`: must be given (pin a target **and** require
  it — an omitted `--slot` would hit production); `pin`: allowed values; `aliases`: per-operation
  short aliases (e.g. `{"-s": "--server"}`).
- Keys starting with `_` (doc lines) are ignored; anything else unknown is refused.

## 5. Limits (honest)

- **Same OS user, not isolation.** Offline, the local `origin/<Trunk>` ref is trusted (online it is
  checked against `git ls-remote`); an agent can rewrite local refs, edit `CLAUDE.md`, or push trunk
  where the project lets it — then the trunk rule is a hurdle, not a wall. The write profile itself
  is readable by any process of that user, and the wrappers run `az`, `sqlcmd` and `bash` from the
  caller's `PATH` — a planted binary would hold the write profile, but so could anything that reads
  `$HOME/.azure-write` directly. The read-only identity and the Operator's click are the barriers.
- **ops-write:** the listed script is checked against trunk, but what it sources or calls is not.
- **Masking is heuristic** (names, `NAME=VALUE`, JSON, bearer tokens, SQL literals); the log is
  owner-only under the user's HOME.
- **Proxy variables are stripped** (`HTTPS_PROXY`, `NO_PROXY`, `REQUESTS_CA_BUNDLE`): behind a
  corporate proxy writes fail while reads work. Passing them would let the proxy see the write token.
  A field in the trunk-approved config is a possible future extension.
- **`AZURE_EXTENSION_DIR` is forced** to `$HOME/.azure/cliextensions` (extension code runs with the
  write profile); a custom extension dir is not honoured.
- **The SQL classifier is a regex:** dynamic SQL (`EXEC('DR'+'OP …')`) passes it — §3.2's
  permissions carry the DROP/TRUNCATE ban. The classifier itself is checked against trunk like the
  config.
- **The database pin is partial:** `sqlcmd-write` refuses a literal `USE` and a three- or four-part
  name that leaves `-d`, but dynamic SQL (`EXEC('USE other …')`), `OPENROWSET`/`OPENQUERY`, a
  synonym or a cross-database view still reach another database — scope the write identity's grants
  to the pinned databases. The name check also refuses a harmless dotted chain such as
  `t.col.method()`; the Operator runs that one.
- **Project-specific rules** (a release pipeline's stage limits, a pull-request patch, an
  application list) are not part of the kit; a project keeps them in its own config or wrapper.
