---
description: Turn one meeting transcript (DOCX, Markdown or text) into one dated, structured, immutable note in .agents/meeting-notes/ — after a mandatory clarification loop and a review gate
argument-hint: "[<transcript path> | --correct <note path>]"
---

# Meeting Notes: Transcript → Structured Note

## Input: $ARGUMENTS

<HARD-GATE>
Do NOT write any file until (a) the clarification loop (Phase 4) has resolved every field it
flagged — or explicitly reported "no ambiguities" — and (b) the user approved the draft preview
(Phase 7). Even when the transcript looks unambiguous, Phase 4 runs and says so. Cancel at any
gate writes nothing. A note, once written, is never edited: mistakes are fixed by a correction note.
</HARD-GATE>

**One transcript → one note.** The note is the unit the rest of the workflow consumes:
`/discover` reads it as a source, `/update-backlog` scans its decisions for scope changes, the wiki
ingests it. This command never writes the backlog, the PRD, the register or the wiki.

**Languages.** Questions and chat in the project's communication language (CLAUDE.md → Language
Rules); the note itself in the artifact language (English per the starter's Language Rules).
**Proper names are never translated** — brands, people, places, products stay verbatim.
**No estimates anywhere** in the note (no hours, days or points).

---

## Phase 0 — Settings

Read `.claude/project-profile.json` if it exists (Read tool): `ba.meetings_dir` (default
`.agents/sources/meetings/`), `ba.vendor` (default `Vendor`), `ba.client` (default `Client`).
Missing file or keys → the defaults. `--correct <note>` → **Correction mode** (end of this file).

## Phase 1 — Input

- **Argument given** → treat it as a path. Quote it in every shell use — real file names contain
  spaces and `&`. `test -f "<path>"` fails → one line "file not found — check the path or run
  without an argument to pick from `<meetings_dir>`", stop. Extension must be `.docx`, `.md` or
  `.txt` (case-insensitive); anything else (PDF, image, audio) → one line "unsupported input —
  `.docx`, `.md`, `.txt` only", stop.
- **No argument** → `test -d "<meetings_dir>"` first (absent → "no transcripts in <dir> — drop files
  there or pass a path", stop), then
  `find "<meetings_dir>" -maxdepth 1 -type f \( -iname '*.docx' -o -iname '*.md' -o -iname '*.txt' \)`;
  none → the same line, stop. Otherwise a numbered list and "Which file? [1-N]"; an out-of-range
  answer is asked once more, a second one exits cleanly; "cancel" / "stop" exits with no side effect.

## Phase 2 — Extraction

- `.md` / `.txt` → `Read` directly.
- `.docx` → `Read` first; binary or empty → `unzip -p "<path>" word/document.xml` and clean the XML
  in your head (strip namespaces and tags, collapse whitespace, drop empty paragraphs) — **no temp
  file, no `pandoc`, no `python-docx`, nothing installed**. Corrupted or password-protected ZIP →
  show stderr verbatim and stop. Zero text after extraction (image-only DOCX) → "the file holds
  only images — not supported", stop.
- **Tables** (`<w:tbl>` rows) → one bullet per row, cells joined with ` — `.
- **Speaker attribution** (`Name:` prefixes, or a speaker table) → keep it for Participants and for
  attributing decisions; never invent a speaker.
- Text longer than ~150 000 characters → read in chunks (`Read` offset / limit) and build the
  structure incrementally; never ingest it in one go.

## Phase 3 — Silent analysis (nothing shown yet)

Build an internal map for each template section (below) with a confidence `high | medium | low`.

- **Drop silently:** filler words and speech-to-text repetitions, broken fragments with no
  meaning, jokes, banter, small talk, anecdotes — but keep the **fact** inside an anecdote (a real
  incident retold as a story → its fact goes to Decisions or Related info).
- **Scope signals:** a statement that changes what will be built is kept for `## Decisions` (marked
  `→ scope` when it is one) or, when undecided, for `## Parked items`.
- **Language:** translate to the artifact language inline; a mixed-language passage gets a Phase 4
  question only when its meaning depends on the language.

## Phase 4 — Clarification loop (mandatory)

For every section below `high`, ask **one** multiple-choice question (`AskUserQuestion`, one
question per call), wait, update the map, set the field `high`.

- **No ambiguity at all** → say "No ambiguities in the transcript — proceeding to the draft." The
  gate ran; it just had nothing to ask.
- **"You choose" / "doesn't matter"** → pick a default and say "Assumed X (because Y) — correct it in
  review if wrong."; continue.
- **Question bounced back** ("what do you suggest?") → propose with a reason from the transcript and
  wait for OK / an alternative.
- **"Don't know"** → mark the field `[Assumption — to verify]`; continue.
- **More than 8 questions** → offer to finish in review: "The loop is growing (8+ questions) — easier
  to correct the full draft in review?"; on yes, mark the remaining low fields `[Assumption — to
  verify]` and go on.
- **A field nobody can source** → `[No source — based on assumption]`.

## Phase 5 — Assemble the note (fixed template — do not reorder, add or drop sections)

```markdown
# <Title>
**Source:** <transcript path>
**Coverage:** full | partial — <topics covered>

## Date
DD.MM.YYYY

## Participants
**<ba.vendor or "Vendor">:**
- Name (role)

**<ba.client or "Client">:**
- Name (role)

## Goals
<what the meeting was for and what it covered — the summary lives here, not under Date>

## Parked items
- <undecided / parked point>

## Discussion topics
### 1. <Topic>
- <bullet>

### 2. <Topic>
- <bullet>

## Action items
- <thing to clarify — no owner, no status>

## Decisions
- <decision made> [→ scope]

## Related info
- <link / other note / design / asset>
```

| Section | Holds | Rules |
|---|---|---|
| `**Source:**` | the transcript path | always |
| `**Coverage:**` | `full` (default) or `partial — <topics>` | `partial` when the note deliberately covers only some topics of the transcript (a transcript split into two notes = two `partial` notes); readers skip a transcript only behind a `full` note |
| `## Date` | `DD.MM.YYYY` only | no narrative |
| `## Participants` | grouped by vendor / client, roles optional | names verbatim |
| `## Parked items` | undecided points | not icebreakers / retros |
| `## Discussion topics` | narrative `### N. Topic` + bullets | never a time / presenter table |
| `## Action items` | things to clarify | no owner, no status |
| `## Decisions` | decisions made | `→ scope` = a review hint for `/update-backlog` (never an approval); unmarked decisions are still scanned |
| `## Related info` | links, other notes, assets | free-form |

Any bullet may start with `[internal]` — the span must not leave the repo; outbound steps (Jira
send, wiki publish) strip it. Keep it in the note.

## Phase 6 — Draft preview (no write yet)

Show the whole note in a fenced block, then:

- **Proposed path:** `.agents/meeting-notes/<YYYY-MM-DD>-<slug>.md` — date from `## Date`; slug =
  ASCII-kebab of the title (transliterate, lowercase, non-`[a-z0-9]` runs → `-`, ≤6 words, noise
  words trimmed).
- **Collision check:** `find .agents -maxdepth 2 -path '.agents/meeting-notes/<YYYY-MM-DD>-*.md'`.
  A same-date note with an overlapping slug → ask: **A)** add a distinguishing suffix
  (`-followup`, `-2`, …) · **B)** this is a correction of that note → Correction mode · **C)** cancel.
  **Never overwrite** — a note may already be recorded as a processed source by its hash.

## Phase 7 — Review gate

Approve → Phase 8. "Change X" / "add Y" → patch the draft and return to Phase 6. "Rename the file to
…" → patch the path and return to Phase 6. Cancel → exit; **no file is written**.

## Phase 8 — Write

1. `mkdir -p .agents/meeting-notes/`
2. `Write` the approved note to the resolved path.
3. Only after the write returned: confirm the path, then **offer (never run)**:
   - `/update-backlog <note>` — when `.claude/commands/update-backlog.md` exists;
   - `/wiki-ingest <note>` — when `.agents/wiki/` exists;
   - `/discover` (update mode) — when the decisions change requirements and no backlog exists yet.

---

## Correction mode — `/meeting-notes --correct <note>`

Notes are immutable; a correction is a new file.

1. Read the target note (an original, or an earlier correction). Ask which bullets are wrong
   (multiple choice over its bullets, one question per call, same loop rules as Phase 4).
2. Assemble `<same date>-<same slug>-correction.md` (`-correction-2.md`, … when one exists):

   ```markdown
   # Correction — <original title>
   **Corrects:** .agents/meeting-notes/<target file>
   **Source:** <who or what established the correction — e.g. "client email 12.11.2026", "BA review">

   ## Decisions
   - <new text> ⟵ was: "<exact original bullet>"
   - <new text> ⟵ added
   - ⟵ removed: "<exact original bullet>"
   ```

   Only the headings that change appear; every line is a replacement, an addition or a removal
   against the **exact** original bullet text.
3. Phases 6–8 as above (preview, review gate, write).

**How readers apply corrections:** start from the original, follow `**Corrects:**` links forward
(never by date — corrections share the meeting's date); apply each file's lines in that order. Two
corrections targeting the same file are both applied in file-name order; when both touch the same
bullet, report it to the user as a conflict instead of choosing.

---

## Notes

- One transcript, one note per run; a split is two runs, each `**Coverage:** partial`.
- Never transcribe audio, OCR images or read design files here — out of scope.
- The command reads `.agents/sources/` transcripts but never edits or moves them (raw input is
  human-only).
