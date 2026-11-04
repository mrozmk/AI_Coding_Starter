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
otherwise asks you to type the resume command yourself.
