# `/create-task` — the GitHub route

Every write goes through the tracker adapter `.claude/lib/team-tracker.sh`; the skill never runs
`gh` itself. Each step names the exact command and how each output line is handled. `<scratch>` is
the session's scratchpad directory (fall back to `${TMPDIR:-/tmp}`).

## 1. Marker

`<!-- create-task:<YYYY-MM-DD>:<slug>:<nonce> -->` — slug: the title lowercased, runs of
non-`[a-z0-9]` → `-`, trimmed of `-`, cut to 40 characters; nonce: 6 lowercase hex characters picked
once, when the draft is written. Two drafts with the same title get two nonces, so two issues.

**The one retry rule (same as SKILL.md):** a draft is a retry only when its first line is a valid
`<!-- create-task-intent: … -->` line **and** its last line is a `<!-- create-task:` marker — then
the marker is kept verbatim. Any other input (a published issue body copied back, a file without the
intent line) is a new draft: every `<!-- create-task:` line in it is removed, every
`<!-- create-task-intent:` line too, and a new marker is assigned, so an old issue is never matched
and changed.

## 2. Body file

`<draft>.body.md` = the draft without its first line (the `<!-- create-task-intent: … -->` line) and
without its `# <title>` line; the marker stays the last line. The intent line never reaches the
tracker.

## 3. Argument encoding

Every argument (title, marker, labels, paths) is written single-quoted, an embedded `'` as `'\''`;
the printed preview is the exact command string that runs. The title carries no backtick and no
`$(` (`references/task-shape.md`): the egress guard rescans any argv word holding them as a command
(`.claude/hooks/lib/guard_team_egress.py`), so a title naming a CLI command in backticks would
prompt — commands go in the body.

## 4. Create

```bash
bash .claude/lib/team-tracker.sh create-issue --marker '<m>' --title '<t>' --body-file '<draft>.body.md'
```

- `created <n>` — a new issue; `exists <n>` — the retry of this draft found its issue by the marker.
- Then `project: added|exists|skipped (no project)`, or a `warning: project add failed …` line
  (partial — keep going, report the rerun line it prints).
- Exit 4 → stop, report stderr: an ambiguous marker says how many issues carry it (find them by the
  marker text and clean up); a client error
  after the issue may exist says: retry `/create-task '<draft file>'`, which finds it by the marker.
  Nothing else runs.

## 5. Status

Skip when `which` said `project=none`. Right after the create, before the labels:

- on `created` → `bash .claude/lib/team-tracker.sh set-status <n> --name Todo` (default), or
  `bash .claude/lib/team-tracker.sh set-status <n> started` for `status=started`;
- on `exists` no status is written — a retry never moves the board (another machine may have claimed
  the issue meanwhile): the final read reports the current status and, when it is empty, the report
  prints the `set-status` command for the caller to run.
- Exit 4 (no `Todo` option, the issue off the board) → a warning naming the board's options from the
  final read.

## 6. Labels

```bash
bash .claude/lib/team-tracker.sh add-labels <n> '<type label>' ['<label>'…]
```

The type label (`bug` | `enhancement`) is omitted when the intent says `type=none`; with no label at
all the call is skipped. Prints `labeled …`; exit 4 → a warning carrying the adapter's stderr: when
it names a missing label, GitHub applied none of the labels of that call, so the report names them
all; any other cause leaves the labels unconfirmed — the retry `/create-task '<draft file>'` adds
them again (idempotent); continue.

## 7. Parent

`parent=<p>` in the intent → `bash .claude/lib/team-tracker.sh add-sub-issue <p> <n>` → `added` |
`exists` (runs on `exists` too — idempotent); exit 4 → a warning.

## 8. Final read

Skip with `project=none`:

```bash
bash .claude/lib/team-tracker.sh item-status <n> --out '<scratch>/item-<n>.json'
```

The reported board status is `.status` (or `none`), so a board automation that reset the status is
visible.

## Partial failure

Never retry blindly: report the issue and every failed step, and the retry
`/create-task '<draft file>'` — it replays the intent line (labels, parent) and refuses when `which`
now names another tracker or repo than the intent.

`started` is a board edit only, no claim — for work started now: create at Todo, then
`/start-task <n>`.

URL: `https://github.com/<repo>/issues/<n>`, with `<repo>` from `which`'s `repo=` line.
