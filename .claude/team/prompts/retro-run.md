You are running a report-only retrospective over a whole team run: run {{RUN}}, ticket {{TICKET}}.
The deterministic audit of this run is {{AUDIT}}; read it first.

Role transcripts, each with the JSON output of `/retro` Step 2's extractor (already run for you):
{{TRANSCRIPTS}}

Instructions:

1. Read `.claude/commands/retro.md`.
2. For **each** transcript above, apply its Steps 3 and 6–8 as `--dry-run`, with that path as the
   transcript:
   - Step 2 is done: read the listed metrics JSON with the Read tool and use it as the Step 2
     JSON. Do not write or run the extractor; `/tmp/retro-extract.py` and
     `/tmp/retro-summary.json` are not used.
   - `metrics: none (<reason>)` → that section is the refusal message with the reason.
3. Print one `## <role> attempt <n>` section per transcript. A refusal message (missing transcript
   or metrics, below the Step 3 threshold, a failed gate) is a valid section.
4. Then add `## Run-level` (at most 10 lines) that relates the sections to the flags in the audit,
   with evidence anchors only.

You have only Read, Grep and Glob. Write no file, no git, no Jira. Output in English.
