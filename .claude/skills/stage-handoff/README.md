# stage-handoff

Compact-and-resume between pipeline stages. A pipeline command (the starter's `/orchestrate`)
ends a stage by writing `.claude/stage-handoff.json` and ending its turn. When that turn ends,
this mod renames the marker to `.claude/stage-handoff.last.json`, compacts the session with
state-keeping instructions (pipeline state, decisions, artifact paths, next step, plus the
marker's `keep` lines verbatim) and submits the marker's `resume` command as the next prompt.
The pipeline continues in a fresh context instead of one million-token session losing the thread.

Marker: `{ "stage": "<name>", "resume": "<prompt>", "keep": ["<line>", ...], "focus": "<text>" }`.
`/stage-handoff <prompt>` runs the same compact-then-submit by hand. Options: `markerPath`,
`resumeDelayMs`. Compaction cannot run under a running turn, so the mod retries for ~30 s and
otherwise asks you to type the resume command yourself. The resume does not hang on the mod's
own `compact()` promise: a `session.compact` hook also observes the compaction finishing (a
large context can take minutes), and the submit itself is retried. A resume that starts with
`/` runs through `$.command.run` (`prompt.submit` refuses a slash text); plain text is submitted
as a prompt. Every step is appended to
`.claude/stage-handoff.log` (git-ignored) — read it when a resume did not arrive.
