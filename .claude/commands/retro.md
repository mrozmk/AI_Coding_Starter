---
description: Generate evidence-based session retrospective from transcript. Refuses to write opinion-only or self-flattering reports. Output feeds /cleanup-workflow.
---

# /retro — Session Retrospective (Evidence-Based)

`/retro` runs at the end of a long or frictional Claude Code session and produces a structured markdown report grounded in **hard evidence**: paths, counts, tool call references, transcript timestamps. It does not produce opinions, vibes, or self-assessments.

**This command is project-agnostic.** It works in any codebase regardless of stack (Python, JS, monorepo, single script, etc.).

**This command refuses noise.** If the session was trivial, friction-free, or if the model can't produce evidence-backed claims, /retro REFUSES to write a retro. The cheap retro is the dangerous one — it pollutes the historical record with false reassurance.

---

## Hard rules (never violate)

1. **The transcript is the source of truth, not conversation memory.** Always extract metrics programmatically from the session's `.jsonl` transcript file. Never write "I think I read that file three times" — grep the transcript.

2. **Every claim needs evidence.** Numbers, paths, tool names, or transcript references. Sentences without evidence are deleted, not softened.

3. **Empty sections require explicit justification.** Every section ends with either evidence items OR a literal `N/A — <reason>` line. Never both empty. Never "TBD" or "TODO".

4. **Refusal is a feature.** If quality gates fail, REFUSE to save the retro. Tell the user which gate failed. The user can pass `--force` to override, but the override is loud (prepends a warning to the file).

5. **Never edit code, never run tests, never modify the repo state.** The retro lives in exactly one new `.md` file. Nothing else changes.

6. **Output language is English** regardless of conversation language. This is for portability across projects and stable aggregation by `/cleanup-workflow`.

---

## Arguments

Parse `$ARGUMENTS` for these flags (anything after the command):

- `--dry-run` — print the retro to stdout, do not save a file
- `--force` — bypass quality gates A–D (defeats the purpose; use sparingly)
- `--transcript <path>` — override transcript path (for analyzing past sessions)
- `--slug <kebab-slug>` — explicit slug for the output filename

Anything left over after parsing flags is treated as the slug. If no slug, derive one in Step 5.

---

## Process — execute every step in order

### Step 1: Locate the transcript

Run this Bash one-liner. If anything fails, STOP and tell the user.

```bash
SID="${CLAUDE_CODE_SESSION_ID:-}"
CWD="$(pwd)"
# Claude Code sluggifies the project path by replacing both '/' and ' ' with '-'.
# A naive `tr '/' '-'` alone breaks for any cwd that contains spaces (e.g. "My Project").
SLUG_PATH="$(echo "$CWD" | tr '/ ' '--')"
TRANSCRIPT_DEFAULT="${HOME}/.claude/projects/${SLUG_PATH}/${SID}.jsonl"

# Use --transcript override if provided, else default
TRANSCRIPT="${RETRO_TRANSCRIPT_OVERRIDE:-$TRANSCRIPT_DEFAULT}"

echo "SID=$SID"
echo "TRANSCRIPT=$TRANSCRIPT"
[ -f "$TRANSCRIPT" ] && echo "Transcript exists: $(wc -l < "$TRANSCRIPT") lines, $(du -h "$TRANSCRIPT" | cut -f1)" || echo "MISSING"
```

Failure cases — REFUSE with a clear message:

- `SID` is empty → `CLAUDE_CODE_SESSION_ID env var not set. Cannot identify current session. Run /retro from inside Claude Code.`
- Transcript file missing → `Transcript not found at <path>. If you're running /retro from a different cwd than the original session, pass --transcript <path>.`

### Step 2: Run the extraction script

Use the `Write` tool to write the following script verbatim to `/tmp/retro-extract.py`. Do not paraphrase, do not "improve" the script — it has been calibrated for the gates below.

```python
#!/usr/bin/env python3
"""Extract evidence-based metrics from a Claude Code session transcript (.jsonl).

Usage:
    python3 retro-extract.py <transcript.jsonl>

Outputs a single JSON object to stdout with all metrics needed by /retro.
Stream-parses line by line — safe for multi-MB transcripts.
"""
import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path


# Detect `<command-name>...</command-name>` markers injected by slash commands.
# These appear inside user message content when the user invokes /commit, /prime,
# /brainstorm, etc. Skill tool entries do NOT capture these (slash commands run as
# content injection, not via the Skill tool), so this regex is the only way to
# reconstruct which slash commands ran during the session.
SLASH_CMD_RE = re.compile(r"<command-name>([^<]+)</command-name>")


CORRECTION_PREFIXES = (
    "no ", "no,", "no.", "nie ", "nie,", "nie.",
    "wait", "actually", "hold on", "stop", "nope",
    "poczekaj", "stój", "źle", "to nie",
    "that's wrong", "that's not", "you misunderstood",
    "i didn't say", "nie o to",
)


def is_correction(text: str) -> bool:
    if not isinstance(text, str):
        return False
    t = text.strip().lower()
    if not t:
        return False
    return any(t.startswith(p) for p in CORRECTION_PREFIXES)


def parse_iso(ts: str):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None


def main():
    if len(sys.argv) < 2:
        print("usage: retro-extract.py <transcript.jsonl>", file=sys.stderr)
        sys.exit(2)

    transcript_path = Path(sys.argv[1])

    tool_calls = Counter()
    read_paths = Counter()
    bash_commands = []
    ask_questions = []
    edit_paths = Counter()
    write_paths = Counter()
    skill_invocations = []
    slash_commands = []  # /prime, /commit, /brainstorm, etc. — content-injected
    todo_writes = 0
    compaction_markers = []
    user_corrections = []
    timestamps = []
    user_prompts = []

    with transcript_path.open() as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue

            ts = entry.get("timestamp")
            if ts:
                timestamps.append(ts)

            etype = entry.get("type")

            # Compaction markers
            if etype in ("compact", "summary") or entry.get("isCompacted"):
                compaction_markers.append(ts)

            msg = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            content = msg.get("content") if msg else None

            # User text (corrections + prompts)
            if etype == "user":
                def _scan_user_text(text: str):
                    """Look for slash command markers + correction prefixes + record prompt."""
                    if not isinstance(text, str) or not text:
                        return
                    for m in SLASH_CMD_RE.finditer(text):
                        cmd_name = m.group(1).strip()
                        if cmd_name:
                            slash_commands.append({"ts": ts, "cmd": cmd_name})
                    if is_correction(text):
                        user_corrections.append({"ts": ts, "snippet": text[:160]})
                    user_prompts.append(text[:300])

                if isinstance(content, str):
                    _scan_user_text(content)
                elif isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            _scan_user_text(c.get("text", ""))

            # Tool uses live inside assistant messages
            if isinstance(content, list):
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") != "tool_use":
                        continue
                    name = c.get("name", "?")
                    tool_calls[name] += 1
                    inp = c.get("input") or {}

                    if name == "Read":
                        p = inp.get("file_path") or inp.get("path") or "?"
                        read_paths[p] += 1
                    elif name == "Bash":
                        cmd = inp.get("command", "")
                        bash_commands.append({"ts": ts, "cmd": cmd[:300]})
                    elif name == "AskUserQuestion":
                        for q in inp.get("questions", []) or []:
                            if isinstance(q, dict):
                                ask_questions.append({
                                    "ts": ts,
                                    "q": q.get("question", "")[:240],
                                    "header": q.get("header", "")[:60],
                                })
                    elif name == "Edit":
                        p = inp.get("file_path") or "?"
                        edit_paths[p] += 1
                    elif name == "Write":
                        p = inp.get("file_path") or "?"
                        write_paths[p] += 1
                    elif name == "Skill":
                        skill_invocations.append({
                            "ts": ts,
                            "skill": inp.get("skill", "?"),
                        })
                    elif name == "TodoWrite":
                        todo_writes += 1

    duration_min = None
    if timestamps:
        timestamps.sort()
        d0 = parse_iso(timestamps[0])
        d1 = parse_iso(timestamps[-1])
        if d0 and d1:
            duration_min = round((d1 - d0).total_seconds() / 60.0, 1)

    redundant_reads = {p: c for p, c in read_paths.items() if c > 1}
    edit_churn = {p: c for p, c in edit_paths.items() if c > 5}

    # Detect search-style bash commands. Use prefix-match where possible to avoid
    # false positives from substrings (e.g. paths containing "ls" inside "/Files").
    SEARCH_PREFIXES = ("rg ", "grep ", "find ", "ls ", "ls -", "fd ", "ack ")
    def is_search(cmd: str) -> bool:
        stripped = cmd.lstrip()
        if any(stripped.startswith(p) for p in SEARCH_PREFIXES):
            return True
        # Also catch search invocations chained with `&& rg` / `; grep` etc.
        return any((" && " + p) in cmd or ("; " + p) in cmd for p in SEARCH_PREFIXES)

    search_cmds = [b for b in bash_commands if is_search(b["cmd"])]

    # Cluster search commands by first 50 chars to surface repeated patterns.
    search_clusters = Counter(b["cmd"][:50] for b in search_cmds)

    # Aggregate slash commands by name for quick reporting.
    slash_cmd_counts = Counter(s["cmd"] for s in slash_commands)

    out = {
        "transcript_path": str(transcript_path),
        "session_id": transcript_path.stem,
        "session_start": timestamps[0] if timestamps else None,
        "session_end": timestamps[-1] if timestamps else None,
        "duration_min": duration_min,
        "tool_calls": dict(tool_calls),
        "total_tool_calls": sum(tool_calls.values()),
        "read_paths_top": dict(read_paths.most_common(15)),
        "redundant_reads": redundant_reads,
        "redundant_reads_count": len(redundant_reads),
        "bash_command_count": len(bash_commands),
        "search_command_count": len(search_cmds),
        "search_command_ratio": round(len(search_cmds) / len(bash_commands), 2) if bash_commands else 0,
        "search_command_samples": [{"ts": b["ts"], "cmd": b["cmd"]} for b in search_cmds[:10]],
        "search_command_clusters": dict(search_clusters.most_common(8)),
        "ask_questions": ask_questions,
        "ask_questions_count": len(ask_questions),
        "edit_paths_top": dict(edit_paths.most_common(15)),
        "edit_churn": edit_churn,
        "edit_churn_count": len(edit_churn),
        "write_paths": dict(write_paths),
        "skill_invocations": skill_invocations,
        "skill_invocation_count": len(skill_invocations),
        "slash_commands": slash_commands,
        "slash_command_counts": dict(slash_cmd_counts),
        "slash_command_invocation_count": len(slash_commands),
        "todo_writes": todo_writes,
        "compaction_markers": compaction_markers,
        "compaction_detected": bool(compaction_markers),
        "user_corrections": user_corrections,
        "user_correction_count": len(user_corrections),
        "user_prompt_count": len(user_prompts),
        "user_prompt_samples": user_prompts[-3:],
    }

    print(json.dumps(out, indent=2, default=str))


if __name__ == "__main__":
    main()
```

After writing the script, execute it:

```bash
python3 /tmp/retro-extract.py "$TRANSCRIPT" > /tmp/retro-summary.json
cat /tmp/retro-summary.json
```

Read the JSON output carefully. **This JSON is the only source of truth for the retro.** Do not add metrics that aren't in this output. Do not paraphrase counts.

### Step 3: Apply minimum threshold (skip trivial sessions)

If `--force` was NOT passed, check these stop conditions:

- `total_tool_calls < 15` → STOP
- `duration_min < 5` (if not null) → STOP
- ALL of the following are zero: `redundant_reads_count`, `ask_questions_count`, `user_correction_count`, `edit_churn_count` → STOP (no friction signals to retro on)

If stopping, print this exact message and exit:

```
Session too small or friction-free for meaningful retro.

  Total tool calls: <N>
  Duration: <X> min
  Friction signals (re-reads + questions + corrections + churn): <N>

No retro generated. Pass --force to override (typically not worth it).
```

### Step 4: Determine storage location

Run these checks in order:

```bash
if [ -d ".agents/specs" ] || [ -d ".agents/plans" ]; then
  STORAGE=".agents/retros"
elif [ -d ".claude" ]; then
  STORAGE=".claude/retros"
else
  STORAGE=""  # refuse
fi
```

If `STORAGE` is empty → REFUSE with:

```
No suitable storage directory found.
  Checked: .agents/specs, .agents/plans, .claude/
  None exist in current directory.

Options:
  1. Run /retro from inside a project with .agents/ or .claude/ structure.
  2. Pass --dry-run to print the retro to stdout instead.
  3. Manually create .claude/retros/ first, then rerun.
```

Otherwise, `mkdir -p "$STORAGE"` (only within the chosen existing base — never create a new top-level layer like `.agents/` if it didn't exist).

### Step 5: Derive the slug

Order of resolution:

1. If user passed `--slug <name>` or a positional argument → use that (validate kebab-case: `^[a-z0-9-]+$`, max 60 chars)
2. Else derive from JSON:
   - Look at the dominant path in `edit_paths_top` or `write_paths`
   - Look at the last 3 user prompts (`user_prompt_samples`)
   - Generate 3-5 kebab tokens describing the session topic
3. Fallback: `session-<first-6-of-session-id>`

Filename: `$(date +%Y-%m-%d)-<slug>.md`

### Step 6: Detect compaction blind spots

If `compaction_detected: true` in the JSON, the retro MUST include this section near the top (between metadata and Volume):

```markdown
## ⚠ Blind spot — session was compacted

This session was compacted at <list of timestamps from compaction_markers>.
Tool calls before compaction are summarized in the transcript and may be
undercounted in all metrics below. The numbers here primarily reflect the
post-compaction window. Treat volume and redundancy counts as lower bounds.
```

If `compaction_detected: false`, do not include this section at all.

### Step 7: Generate the retro from this template

Render every section. Fill from the JSON. Where a section has zero matching evidence, use `N/A — <reason citing the count from JSON>`. Do not leave any heading empty or with placeholder text.

```markdown
# Session Retro: <slug>

**Date:** YYYY-MM-DD
**Session ID:** <session_id>
**Duration:** <duration_min> min  (<session_start> → <session_end>)
**Total tool calls:** <total_tool_calls>
**Source:** transcript scan (`<transcript_path>`)

<!-- Include ## ⚠ Blind spot section from Step 6 here ONLY if compaction_detected -->

## Volume

| Tool             | Calls |
|------------------|-------|
| Read             | <N>   |
| Bash             | <N>   |
| Edit             | <N>   |
| Write            | <N>   |
| AskUserQuestion  | <N>   |
| Skill            | <N>   |
| TodoWrite        | <N>   |
| (other tools)    | <N>   |

User prompts: <user_prompt_count>. Skill invocations: <skill_invocation_count>.

## Redundant work

### Re-reads (same file read more than once)

<If redundant_reads_count > 0, list each path with its count, sorted desc:>
- `<path>` — read <N> times
<If redundant_reads_count == 0:>
N/A — 0 redundant reads detected (transcript scan covered <total Read calls> Read calls across <distinct paths> distinct paths).

### Edit churn (same file edited more than 5 times)

<If edit_churn is non-empty, list paths with counts:>
- `<path>` — edited <N> times
<If empty:>
N/A — 0 files edited more than 5 times (max was <max edit count from edit_paths_top>).

### Search redundancy

Total Bash commands: <bash_command_count>. Of those, <search_command_count> were searches (rg/grep/find/ls/fd/ack — prefix match, with chained-command fallback). Search ratio: <search_command_ratio>.

<If search_command_ratio > 0.30 AND search_command_count >= 5:>
⚠ Elevated search ratio. Top clusters from `search_command_clusters` (JSON):
- <count>×: `<cluster prefix>`
- ...

Concrete samples from `search_command_samples` (first up to 5):
- @ <ts>: `<full cmd, truncated 200>`
- ...

<Else:>
N/A — search ratio below 30% threshold or under 5 searches total (JSON: search_command_count=<N>, ratio=<R>).

## Missing context

### Clarification questions asked by the model

<For each entry in ask_questions, format as:>
- @ <ts> [<header>]: "<q>"
<If ask_questions_count == 0:>
N/A — 0 AskUserQuestion calls in this session.

### User corrections

<For each entry in user_corrections:>
- @ <ts>: "<snippet>"
<If user_correction_count == 0:>
N/A — 0 user correction signals detected. Prefix scan: no/nie/wait/actually/poczekaj/stop/źle/that's wrong/etc.

## Over-loaded context

This section requires cross-referencing files loaded by `/prime` (or another always-run command) with files actually re-read or cited during the session. Apply the rule:

  loaded_files - referenced_files = candidates for prune

**Source of truth for invocation:** `slash_commands` field in the JSON summary. Look for entry with `cmd == "prime"` (or whichever command auto-loads context in this project).

<If `slash_command_counts` includes "prime" (or equivalent context-loading command):>
- /prime invoked at: <ts from slash_commands entry>
- Files /prime instructs to read (parsed from `.claude/commands/prime.md`): <list>
- Of those, re-read during session (cross-check with `read_paths_top` from JSON): <list>
- Loaded but NOT re-read: <candidate prune list — each path with 0 Read hits>

<If /prime (or equivalent) NOT in slash_commands:>
N/A — no context-loading slash command detected this session (slash_commands list: <list from JSON>).

## Friction patterns

Each item below MUST cite a specific transcript range (e.g. "Edit×8 on path X over 4 minutes around <ts>") or a tool call sequence. No prose without anchor.

<List 1-5 patterns. Example shape:>
- **Pattern: design iteration churn.** Edits on `<path>` clustered around <ts-start>–<ts-end> (Edit×<N>), with <N> Read calls back to the same path. Suggests design decision was under-specified before implementation started.
- **Pattern: clarification storm.** AskUserQuestion×<N> within <X> minutes around <ts>. Topics: <briefly enumerate headers>. Suggests upfront spec missed a critical axis.

<If no patterns rise above noise:>
N/A — no friction clusters detected over noise threshold (<N> redundant reads, <N> questions, <N> corrections all isolated).

## Causal hypotheses

This is the only section where speculation is permitted. Each hypothesis MUST point to a transcript anchor (timestamp range or tool call cluster) that triggered the speculation. Hypotheses without anchors get deleted.

<Up to 3 hypotheses. Example:>
- **Hypothesis:** <claim>. **Evidence anchor:** <ts-range or tool-call cluster from the JSON>. **What could disprove this:** <a measurable observation that would falsify the hypothesis>.

<If no defensible hypothesis:>
N/A — no causal pattern clear enough to hypothesize without speculation.

## What I did NOT measure

Transcripts capture tool calls. They do NOT capture:
- Whether generated code compiles, runs, or passes tests (no execution feedback in transcript)
- Whether the user agreed with silent decisions (silence ≠ agreement)
- Subjective quality of final output beyond surface counts
- Time spent thinking between tool calls (gaps could be model deliberation OR user reading)
- Outcomes after the session ended (whether code shipped, whether plan got executed)

These are blind spots of evidence-based retro. They are out of scope for this report — do not paper over them with guesses.

## Signals for /cleanup-workflow

List 1–3 specific, actionable signals. Each must reference a count or path from the JSON. If no signal is concrete enough, write `N/A`.

<Examples:>
- `<file>` re-read <N> times this session — candidate for inclusion in /prime auto-load list if pattern repeats.
- Memory file `<path>` referenced 0 times despite presence in /prime — candidate for prune audit (verify across more retros before acting).
- Skill `<name>` invoked but only <N> follow-up tool calls — possible skill cost-vs-value gap.

<If no signals:>
N/A — no actionable cleanup-workflow signals this session.
```

### Step 8: Quality gates — run ALL FOUR

⚠ **HARD ORDERING REQUIREMENT.** You MUST evaluate all four gates BEFORE invoking the `Write` tool (or any tool that creates the retro file). The draft must live in memory as a string until every gate passes. If you write the file first and run gates after, you have just bypassed the gating mechanism even if you "would have noticed" — the file already exists on disk. This is a process bug, not a stylistic preference.

Workflow:
1. Render the markdown into a string variable (do NOT call `Write` yet).
2. Run gate A → if fail, mark failed.
3. Run gate B → if fail, mark failed.
4. Run gate C → if fail, mark failed.
5. Run gate D → if fail, mark failed.
6. ONLY now proceed to Step 9.

If ANY gate fails AND `--force` was not passed, REFUSE — do not call `Write` at all.

#### Gate A — Evidence-or-NA

Every `##` and `###` section must end with either:
- ≥1 evidence item (bullet/row/sentence containing a number, path, or transcript ref), OR
- A literal line starting with `N/A — ` followed by a count-citing reason

Forbidden in any section:
- "TBD", "TODO", "(fill in)", "..." as content (NOT inside code blocks)
- Empty section (heading followed immediately by another heading)
- Placeholder text like `<your evidence here>` from the template

**Detection:** parse the markdown headings, for each section grab the body, check for evidence patterns vs forbidden patterns.

**On fail:** report which sections failed and why.

#### Gate B — Forbidden phrase blocklist

Grep the rendered retro for these phrases (case-insensitive). ANY match → FAIL.

English:
- "things went well"
- "no friction"
- "performed efficiently"
- "performed well"
- "smoothly"
- "all green"
- "as expected"
- "no issues"
- "i correctly"
- "i was able to"
- "ran perfectly"
- "without any problems"

Polish:
- "poszło gładko"
- "bez problemów"
- "bez problemow"
- "wszystko ok"
- "wszystko działa"
- "wszystko dziala"
- "zrobiłem dobrze"
- "zrobilem dobrze"
- "bez friction"
- "bez tarcia"

Also flag (but warn, do not fail) the unqualified versions of:
- "successfully" — allowed ONLY if followed by a number/quantity in the same sentence
- "udało się" / "udalo sie" — allowed ONLY if followed by a number/quantity

**On fail:** list matched phrases with their location in the draft.

#### Gate C — Minimum evidence count vs JSON counts

Cross-reference the rendered markdown against the JSON summary:

- If JSON `redundant_reads_count > 0`, the "Re-reads" section must list at least `redundant_reads_count` items (or `min(redundant_reads_count, 10)` if heavily redacted). Listing fewer = FAIL.
- If JSON `ask_questions_count > 0`, the "Clarification questions" section must list at least `ask_questions_count` items.
- If JSON `user_correction_count > 0`, the "User corrections" section must list at least `user_correction_count` items.
- If JSON `edit_churn_count > 0`, the "Edit churn" section must list at least `edit_churn_count` items.

**On fail:** report `JSON said N <category>, retro lists M`.

#### Gate D — Self-review pass

Re-read the rendered retro. For each sentence outside code blocks, `N/A — ` lines, and the template's section descriptions:

- Does it contain a number, a path (with `/` or `.`), a tool name, a timestamp, or a transcript reference?

Count `sentences_without_evidence / total_content_sentences`. If > 0.20 → FAIL.

Heuristic: most legitimate observations naturally include a count or path. Wide-eyed prose without anchors is the smell of self-flattery creeping back in.

**On fail:** list 3–5 example sentences from the retro that lack evidence anchors, so the user sees concretely what failed.

### Step 9: Save or refuse — final action

**Precondition:** Step 8 completed and all four gates either passed OR `--force` was passed. If you reached Step 9 without explicitly running and reporting on all four gates, STOP and return to Step 8.

**All gates passed, not --dry-run:**

Now (and only now) call the `Write` tool with the draft markdown:

```bash
echo "$RETRO_MARKDOWN" > "$STORAGE/$DATE-$SLUG.md"
```

Then print:

```
Retro saved: <storage>/<date>-<slug>.md

Top signals:
  - <strongest evidence item 1>
  - <strongest evidence item 2>
  - <strongest evidence item 3>

Cleanup hint: <one concrete next step if a clear pattern emerged, else "None this session.">
```

**--dry-run:**
Print the full retro to stdout (no file write). Tell user it was a dry run.

**Any gate failed, --force NOT passed:**
Do NOT write any file. Print:

```
Retro REFUSED — quality gates failed.

Failed gates:
  - Gate <X>: <reason>
  - Gate <Y>: <reason>

What's needed:
  - <specific fix item>
  - <specific fix item>

Override: rerun with --force (prepends a warning to the file and saves anyway).
```

**Any gate failed, --force PASSED:**
Save the retro, but prepend at the very top (before the H1):

```
> ⚠ FORCE-SAVED despite failing quality gates: <list of failed gates>.
> Treat all claims in this retro with extra skepticism.
> Gate failure reasons:
> - <reason 1>
> - <reason 2>
```

Then print the same "saved" message as the happy path, plus the warning list.

---

## What `/retro` is NOT

| This is not…                          | Use instead              |
|---------------------------------------|--------------------------|
| A summary of what was accomplished    | Git log / commit messages |
| An implementation plan                | `/plan-feature`          |
| A spec or PRD                         | `/brainstorm`            |
| A code review                         | `/review`                |
| A casual "how did it go" post         | A normal chat message    |
| A workflow change proposal            | `/cleanup-workflow`      |

`/retro` produces *raw signal*. `/cleanup-workflow` acts on aggregated signal across multiple retros.

---

## Final reminders (top priority)

- **Evidence or N/A.** Never both empty. Never "TBD".
- **Refusal is a feature.** Quality gates exist because cheap retros poison the historical record.
- **Output in English.** Even if the session was in Polish/German/etc. Aggregation needs stable parsing.
- **Do not commit the retro.** Save it; let the user decide whether to `git add` it. `/commit` handles staging separately.
- **The transcript is truth.** Conversation memory is biased. Always extract from JSON, never from "I think I remember…".
