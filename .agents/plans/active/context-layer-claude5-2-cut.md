# Step 2 — Cut the context layer (seed + template + generator)

**Parent:** [context-layer-claude5.md](./context-layer-claude5.md)
**Status:** pending
**Complexity:** complex — low per-edit difficulty, but several exact-text invariants that fail
**silently** when broken
**Blocker:** Step 1 done (`CLAUDE.md` will point at `index.md → Memory scope`)
**Pre-read:** the parent umbrella (anchor contract + seed/template divergence);
`.agents/specs/2026-07-26-context-layer-claude5.md` → *Solution*, *Cut plan*, *Targets*

## Goal

Cut `CLAUDE.md` from 239 lines / 18 700 chars to **≤165 lines and ≤9 500 chars** (both hard), mirror
the cut onto the template **body** so it propagates, and give the generator an **executable** cap
gate so the number stops being a comment.

> **Why 165 and not 150.** 150 was the target before merge `d869d42` added ~8 lines to the seed. The
> arithmetic was re-run against the current file: the planned deletions (−32) and compressions
> (PKL 38→12, Git Workflow 23→13, Search Commands 11→5, starter note −4) land at **161 lines**. Hitting
> 150 would require the five light-trim sections — 52 lines of pure rules — to give up 11 more, which
> collides with this step's own promise that every rule in them survives. 165 is the honest number
> for this cut; it is still a 31% reduction and still below the 200 the file currently violates.
> **The char target did not move** — it lands ~9 200 against the 9 500 cap.

### Where the characters actually are

Measured 2026-07-29, post-merge. Ten physical lines carry ~7 100 chars, ~38% of the file:

| Line | Chars | Section | Fate |
|---|---|---|---|
| 128 | 1 227 | Git Workflow — `/orchestrate` push-model paragraph | deleted (→ `parallel-orchestration.md`) |
| 186 | 874 | Automatic Behaviors — `guard-memory` mechanics | shrunk to ~150 |
| 204 | 814 | Proactive Agent Usage — orchestrator agents | section deleted |
| 158 | 803 | Project Knowledge Layers — backlog/Jira blockquote | deleted (→ Step 1 homes) |
| 124 | 615 | Git Workflow — `allow` tier enumeration | deleted **except** the force-remove guard sentence |
| 156 | 504 | Project Knowledge Layers — backlog opt-in blockquote | deleted |
| 133 | 500 | Git Workflow — `Orchestrate publish` blockquote | 🔒 **KEPT** — content contract, see umbrella |
| 193 | 462 | Automatic Behaviors — Output-Discipline Convention | 🔒 **KEPT** — a live trigger |
| 203 | 460 | Proactive Agent Usage — `qa-contract` | section deleted |
| 201 | 445 | Proactive Agent Usage — `documentation-manager` | section deleted |

Eight of the ten sit inside sections this step deletes or compresses, so the char target is reachable
**without** touching anything contractual. Two are marked 🔒 and must survive at full length — gate
check 11 therefore expects **no line over 400 chars except those two**, not "no line over 400 chars".

---

## Tasks

### UPDATE `CLAUDE.md` — delete the three zero-referent sections

- **IMPLEMENT**: Delete in full, including trailing `---` separators:
  - `## Proactive Agent Usage` (197–207) — restates `.claude/agents/*.md` frontmatter, which the
    harness injects into the system prompt. Re-verified post-merge: still **0 referents**, even
    though `d869d42` added a `qa-contract` bullet to it.
  - `## Plan Mode` (208–213) — content lives in `.claude/commands/analysis.md`.
  - `## On-Demand Context` (225–239) — a second pointer table beside `index.md`. Its newest row
    (`qa-evidence-families.md`) is safe to lose: `qa-verify.md:8` and `:39` reference that path
    directly, and `README.md` carries it too.
- **GOTCHA**: Delete bottom-up (On-Demand Context first) so earlier line numbers stay valid, or match
  on heading text rather than line number.
- **GOTCHA**: `## Search Commands` sits *between* Plan Mode and On-Demand Context. Do not take it
  with them — it is contractual (`release.md` anchor link `#search-commands`).
- **VALIDATE**: `rg -n '^## (Proactive Agent Usage|Plan Mode|On-Demand Context)' CLAUDE.md` → no output

### UPDATE `CLAUDE.md` — compress five sections

- **IMPLEMENT**, per the spec's cut table:
  - **Starter-kit note** (1–8 → ~4): keep the "run `/setup:create-CLAUDE_MD` after cloning"
    instruction and the `{placeholder}` convention; drop the restatement of what the sections are.
  - **`## Project Knowledge Layers`** (141–178 → ~12): keep the six-row layer table and the one-line
    `Flow:` chain. Delete the three blockquotes (backlog opt-in, backlog-vs-Jira, wiki pointer) and
    the entire `### Memory — routing discoveries` subsection (164–178) — it duplicates
    `index.md → Quick Reference` row for row. Add a one-line pointer to `index.md → Memory scope`.
  - **`## Git Workflow`** (118–140 → ~13): keep the `/commit` `/push` `/pull` `/release` pointers, the
    `deny > ask > allow` precedence sentence (non-obvious, load-bearing), the "never include AI
    attribution" rule, and the `### Default branch` subheading. Delete the per-tier command
    enumerations and the `/orchestrate` push-model paragraph (line 128) — `settings.json` and
    `.agents/reference/parallel-orchestration.md` are their sources of truth and both stay linked.
    **Three things must survive this compression — see the two GOTCHAs below.**
  - **`## Automatic Behaviors`** (179–195): **all 11 trigger bullets survive; the section keeps its
    17 lines.** The win here is characters, not lines — the `guard-memory` bullet is a single
    **874-char** physical line (line 186). Shrink it to ~150 chars: one line plus a pointer to
    `.claude/hooks/guard-memory.sh` and `.claude/memory-domains.json`. Do **not** shrink the
    `Output-Discipline Convention` bullet (line 193, 462 chars) — it is a live convention, not
    mechanics, and it has no other home.
  - **`## Search Commands`** (214–224 → ~5): keep the heading **verbatim**, keep the rg-over-grep
    rule, drop the fenced example block.
- **GOTCHA — the `Orchestrate publish` line is a contract, not prose.** `CLAUDE.md:131`
  (`**Orchestrate publish:** push`) and its blockquote at 133 must survive **verbatim**.
  `orchestrate.md:103` reads that value; `create-CLAUDE_MD.md:119` derives it and `:208` fills the
  slot. Deleting it throws no error — `/orchestrate` just falls back to its `push` default, so a
  downstream PR-gated project that had declared `branch-local` silently starts pushing again. This is
  the single highest-consequence line in the section.
- **GOTCHA — keep one sentence of the `allow` tier.** The enumeration goes, but the sentence about
  `worktree remove --force` and its clean-and-fully-merged guard must stay (one line is enough).
  `orchestrate.md:660` cites it by name, and unlike the rest of the tier list it is **not** a
  restatement of `settings.json` — that guard exists nowhere else. Alternative if you prefer a
  cleaner section: keep the sentence in `parallel-orchestration.md` and update `orchestrate.md:660`
  to point there instead. Either is acceptable; silently dropping it is not.
- **GOTCHA**: `### Default branch` (135) is filled by `create-CLAUDE_MD.md:207`. The subheading must
  survive the Git Workflow compression.
- **GOTCHA**: `## Project Knowledge Layers` must keep its **table**, not merely its heading —
  `createwikillm.md:249` inserts a row into it. Structural dependency.
- **GOTCHA — preserve an uncommitted edit.** The working tree already carries a change to the
  `When uncertain about approach` bullet: it now reads *"make routine judgment calls yourself; stop
  and ask when different readings of the request would lead to materially different work"*, replacing
  an earlier `NEVER ASSUME OR GUESS`. Keep the new wording; do not restore the old one from any
  description of the pre-change file.
- **VALIDATE**:
  ```bash
  rg -n '^## (Project Knowledge Layers|Git Workflow|Automatic Behaviors|Search Commands)$|^### Default branch$' CLAUDE.md   # → 5 hits
  rg -n '^\*\*Orchestrate publish:\*\*' CLAUDE.md                    # → 1 hit (content contract)
  rg -n -i 'worktree remove --force|force-remove' CLAUDE.md          # → ≥1 hit, unless you moved it and updated orchestrate.md:660
  ```

### UPDATE `CLAUDE.md` — light-trim five sections

- **IMPLEMENT**: Tighten prose only; every heading and every rule survives.
  `Language Rules` · `Code Structure & Modularity` · `Error Handling` · `Security` · `Architecture`.
- **PATTERN**: One dense line per rule beats a rule plus its explanation. Where an explanation is
  genuinely load-bearing, keep it as a `>` blockquote.
- **GOTCHA**: `Security` **is** contractual (`recon.md:80`, backtick form) — heading text immutable.
  `Error Handling` is the only section in the file kept purely on policy grounds, so it is the only
  one whose heading is negotiable; keep it anyway, and trim its prose hardest.
- **GOTCHA**: Do **not** touch `## Validation` (46–64), `## Commands` (28–45), `## Tech Stack` (65),
  `## Style & Conventions` (94), `## Project Overview` (9). Explicitly out of scope, and checked for
  byte-identity in the gate.
- **VALIDATE**: `wc -l -c CLAUDE.md` → **≤165 lines and ≤9 500 chars** (from 239 / 18 700)
- **CHARACTERS ARE THE REAL GATE.** Lines are a weak proxy: the seed averages 78 chars/line and holds
  a 1 227-char line, so line count understates content. Measured landing: **~161 lines / ~9 200
  chars** — the line budget has ~4 lines of slack, the char budget ~300. Neither is generous; if the
  metrics conflict, **characters win** — a 160-line file still at 15 000 chars has not solved the
  problem.
- **The contract outranks both numbers.** Never cut into a contractual anchor, a content contract, a
  surviving rule, or an out-of-scope section to hit a figure. If you cannot reach budget without
  that, **report and stop**. A 168-line file with every rule intact is a success; a 150-line file
  missing the `Orchestrate publish` line is a regression that nothing will alert you to.

### UPDATE `.claude/templates/CLAUDE-template.md` — audit, then mirror

> **NOT a blind mirror.** The two files share section *names* but diverge in section *content*.
> Several instructions above are no-ops here. Audit before editing.

- **STEP A — audit.** Read each shared section in the template before touching it. Verified
  divergences (confirm nothing else drifted):

  | Section | Seed | Template |
  |---|---|---|
  | `Project Knowledge Layers` | 6 layers incl. `backlog.md`, 3 blockquotes, **+ `### Memory — routing discoveries`** | 5 layers, 1 blockquote, **subsection absent** |
  | `Automatic Behaviors` | **11** bullets (`CLAUDE.md:183–193`) | **7** (`tpl:187–193`) — see Step B for the exact gap |
  | `Git Workflow` | 3 tiers + push-model paragraph + `**Orchestrate publish:** push` (filled) | 3 tiers, **push-model paragraph absent**, `**Orchestrate publish:** {push \| branch-local}` (placeholder, `tpl:142–144`) |
  | `On-Demand Context` | filled 15-line table | 10-line placeholder stub |

  So "delete the routing subsection", "shrink the guard-memory bullet", and "drop the push-model
  paragraph" are **no-ops on the template**. Do not hunt for that content and do not invent it in
  order to delete it. Apply only what has a target.

  **The `Orchestrate publish` placeholder at `tpl:142` and its blockquote at `tpl:144` are NOT a
  no-op — they must survive the Git Workflow compression exactly as the seed's filled version does.**
  The generator fills that slot (`create-CLAUDE_MD.md:208`); remove it from the template and every
  future bootstrap loses the setting entirely.

- **STEP B — close the trigger gap, do not preserve it.** The template is missing **four** triggers,
  not two — merge `d869d42` added two more to the seed after this plan was first written. Add all
  four in slim form:

  | Missing trigger | Seed source |
  |---|---|
  | `Before any non-trivial response` (user-profile, incl. the "absent file is fine" clause) | `CLAUDE.md:184` |
  | `Before editing code` (guard-memory — pointer form, not the 874-char version) | `CLAUDE.md:186` |
  | `When writing to memory at the end of a run` (→ `reflection-protocol.md`) | `CLAUDE.md:190` |
  | `Output-Discipline Convention` (→ `index.md → Output-Discipline Convention`) | `CLAUDE.md:193` |

  **Also fix, do not copy, the trigger the template already has:** `tpl:191`
  (`When a domain/ memory file doesn't exist`) still points at `index.md`; the template for domain
  files now lives in `.agents/memory/reflection-protocol.md`. Copying it as-is propagates a dead
  pointer to every new project.

  Leaving the gap open means every newly bootstrapped project silently ships without four always-on
  rules the starter treats as baseline — the propagation invariant would be claimed but not achieved.
  **After Step B the template has 11 triggers, matching the seed.**

- **STEP C — apply.** On the template body (starts at `# CLAUDE.md`, line 20):
  1. Delete `## Proactive Agent Usage` (197), `## Plan Mode` (206), `## On-Demand Context` (223).
  2. Apply the compressions and trims **that have a target**, per Step A.
  3. **Fix the binary rule the seed already fixed.** Template line 189 still reads
     `**When uncertain about approach**: stop and ask — **NEVER ASSUME OR GUESS**`. Replace with the
     seed's principle-based wording (`CLAUDE.md:187`). Without this, every newly bootstrapped project
     reinherits the rule that conflicts with the Claude 5 system prompt — silently undoing a
     completed fix.
  4. Preamble: cap at line 5 `≤200 lines` → `≤165 lines`; drop `Proactive Agent Usage` and
     `Plan Mode` from the mandatory list at lines 13–14, and add the four contractual headings it
     never protected (`Validation`, `Commands`, `Style & Conventions`, `Tech Stack`) — same addition
     as the generator's list.
- **GOTCHA — measure the BODY, not the file.** The cap applies from the exact line `# CLAUDE.md`
  (line 20) onward; the 19-line preamble is generator instructions and never reaches a generated
  `CLAUDE.md`. Body today: **218 lines / 9 295 chars**. Measure with
  `tail -n +20 "$TPL" | wc -l -c`, never `wc -l "$TPL"`. Using the whole file makes the template look
  like it violates a cap it does not, and invites a cut of content that was never the problem.
- **GOTCHA**: Work from **heading names, not the seed's line numbers** — the template is offset by
  its 19-line preamble and orders sections differently (`Language Rules` at 148, not 15).
- **GOTCHA**: Preserve `{communication-language}` placeholders (152–160). The seed has them
  substituted to Polish; the template must not.
- **GOTCHA**: Leave `## Testing` (73–82) and `## Notes` (233) alone — template-only by design.
- **VALIDATE**:
  ```bash
  TPL=.claude/templates/CLAUDE-template.md
  rg -n '165 lines' "$TPL"                                              # → preamble cap updated
  rg -n '^## (Proactive Agent Usage|Plan Mode|On-Demand Context)' "$TPL"  # → no output
  rg -n 'Orchestrate publish' "$TPL"                                    # → placeholder survived
  rg -n 'reflection-protocol' "$TPL"                                    # → ≥1 (dead index.md pointer fixed)
  tail -n +20 "$TPL" | wc -l -c                                         # → body ≤165 / ≤9 500
  ```

### UPDATE `.claude/commands/setup/create-CLAUDE_MD.md` — cap, list, rationale, **gate**

- **IMPLEMENT**:
  1. Line 191: `Hard cap: ≤200 lines` → `Hard cap: ≤165 lines`.
  2. Lines 210–220: drop `Proactive Agent Usage` and `Plan Mode` from the mandatory list, **and add
     the four contractual headings it never protected** — `Validation`, `Commands`,
     `Style & Conventions`, `Tech Stack`. Today the list names **7 of the 11** unconditional anchors
     (plus policy-retained `Error Handling` and the two being removed), so a future generation could
     legally drop the other four and every gate would pass.
     Mirror the same addition into the template's list at lines 13–14.
  3. **Add the missing rationale, inline — names only, never `file:line`.** State that these headings
     are mandatory *because commands and hooks address them by name*, list the eleven protected names
     plus the conditional `Code Navigation` substring, and embed the spec's *Verification command*
     (the heading-outward loop, **not** a pointer regex) so a future reader can re-derive the
     consumers instead of trusting a frozen list.
     **Do NOT copy the spec's `file:line` consumer table into this file.** It decays on contact: the
     spec cites `orchestrate.md:635` and nine commits later that consumer sits at 660, with nothing
     flagging the drift. The spec is a point-in-time audit and stays in this repo; the generator
     ships to every downstream project and is read long after the lines have moved. Heading names are
     stable, offsets are not.
  4. **Add the two content contracts to the protected set.** The list is heading-only today, so it
     cannot protect a line. Add an explicit clause: the `**Orchestrate publish:**` line and the
     force-remove guard sentence inside `Git Workflow` are mandatory content, not prose to be
     trimmed. The generator already knows how to fill the first (`:119` derive, `:208` fill) — it
     just never declares it un-droppable.
  5. **Add an executable cap gate** before the success report (lines 300–346): `wc -l` and `wc -c` the
     file just written; while over 165 lines or 9 500 chars, push detail into the memory file named in
     the "where detail lives" table (193–201) and re-check; if a mandatory rule makes compliance
     impossible, say so explicitly in the report. **Without this the change is cosmetic** — a
     declared-but-unenforced cap is precisely what let the seed drift to 239 lines, past a ≤200 cap
     that was written down in two separate files the whole time.
  6. Add a per-section prose budget: a section carries its rule plus a pointer; detail goes to the
     memory file named in that same table.
  7. **Fix the stale trigger description at line 224.** It reads *"The `Automatic Behaviors` block in
     the template contains only generic triggers (`read index.md`, `check plans/active/`, `ask when
     uncertain`)"* — three, against seven today and eleven after Step B. Restate it as "the generic
     baseline triggers" without enumerating them, so it cannot go stale again the next time a trigger
     is added.
  8. **Close the regeneration hole at line 236.** The *Optional sections* block still offers
     `- On-demand context references — point to wiki / reference docs`. Step 2 deletes
     `## On-Demand Context` from the seed and the template — but the generator can put it straight
     back on the next bootstrap, and a gate that only diffs seed against template will never notice.
     Delete that bullet, or redirect it: such pointers belong in `index.md → When to Read` or
     `.agents/reference/`.
- **GOTCHA**: The rationale must be **self-contained**. It may not cite
  `.agents/specs/2026-07-26-context-layer-claude5.md` — `.agents/specs/` is sync category C
  (`starter-sync-playbook.md:66`) and never reaches downstream projects, so the pointer would dangle
  everywhere except this repo.
- **GOTCHA**: Line 206 conditionally emits `## Code Navigation (LSP)` when an LSP is detected, keyed
  to the phrase `nudge-lsp.sh:42` greps. Leave that instruction intact — the contract is the
  **substring**, not the full heading.
- **VALIDATE**:
  ```bash
  GEN=.claude/commands/setup/create-CLAUDE_MD.md
  rg -n '≤165 lines' "$GEN"                    # → cap updated
  rg -n 'wc -l|wc -c' "$GEN"                   # → executable gate present
  rg -n 'Orchestrate publish' "$GEN"           # → ≥2 (derive + fill), plus the new protected clause
  rg -n 'On-demand context references' "$GEN"  # → no output (regeneration hole closed)
  rg -n 'orchestrate\.md:[0-9]|plan-feature\.md:[0-9]' "$GEN"   # → no output (no frozen file:line)
  ```

### VERIFY — run the full gate

Not a formality: every failure this catches is silent. Run the whole Level 3 block below. **Every
command in it has been executed against this repo** — an untested gate is worse than no gate, which
is how an earlier draft shipped a sweep whose `--glob` options were being read as file paths.

---

## VALIDATION COMMANDS

### Level 1: Syntax & Style — N/A (no markdown linter configured)
### Level 2: Tests — N/A (no test suite; see umbrella → Testing strategy)

### Level 3: Manual Validation — MANDATORY

Run with **bash** (uses `shasum`, `comm`, arithmetic tests). Do not add `2>/dev/null` anywhere —
suppressing stderr is what hid the broken `--glob` placement in an earlier draft.

```bash
cd /Users/mrozo/Desktop/AI_Coding_Starter
TPL=.claude/templates/CLAUDE-template.md
GEN=.claude/commands/setup/create-CLAUDE_MD.md

# Extract one "## Section" block, stopping at the next "## ". A naive awk RANGE does NOT work here:
# /^## Heading/,/^## / matches the same line twice and closes immediately, printing nothing.
sect() { awk -v s="## $2" 'index($0,s)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$1"; }
git show HEAD:CLAUDE.md > /tmp/base-seed.md
git show "HEAD:$TPL"    > /tmp/base-tpl.md

# 1. HEADING SWEEP over the UNION of before+after headings. Reading only the post-edit file can
#    never flag a heading you just deleted — the one failure this gate exists to catch.
#    --glob MUST precede --, or rg treats it as a path and silently applies no exclusion.
{ cat /tmp/base-seed.md; cat CLAUDE.md; } | rg -o '^## (.+)$' -r '$1' | sort -u |
while IFS= read -r h; do
  n=$(rg -l -F --glob '!**/templates/**' --glob '!**/create-CLAUDE_MD.md' \
        --glob '!**/starter-sync-playbook.md' --glob '!**/specs/**' --glob '!**/plans/**' \
        -- "$h" .claude/ .agents/ | wc -l | tr -d ' ')
  p=$(rg -c "^## $h\$" CLAUDE.md || echo 0)
  printf '%-32s refs:%-3s inSeed:%s\n' "$h" "$n" "$p"
  [ "$n" -gt 0 ] && [ "$p" -eq 0 ] && echo "  🔴 DELETED BUT REFERENCED — restore it"
done
# BASELINE (re-verified 2026-07-29, post-merge): refs:0 for exactly Proactive Agent Usage / Plan Mode
# / On-Demand Context / Project Overview. The first three are the planned deletions.
# KNOWN FALSE POSITIVES — do not act on these, they are not references to CLAUDE.md headings:
#   Error Handling  refs:2 → plan-feature.md:225 (a section of the PLAN template) and
#                            gates/verify-implementation.md:123 (that file's own heading)
#   Architecture    refs:13 → the word is common; architecture.md is its own artifact
# Substring matching over-reports by design. A false positive costs one kept line; a false negative
# breaks a consumer with no error. Never "clean up" a heading because the sweep looks noisy.

# 2. All 11 unconditional anchors verbatim in BOTH files. EXPECT every row "seed:1 tpl:1"
for s in "Language Rules" "Validation" "Commands" "Code Structure & Modularity" \
         "Style & Conventions" "Tech Stack" "Automatic Behaviors" "Search Commands" \
         "Security" "Git Workflow" "Project Knowledge Layers"; do
  printf '%-30s seed:%s tpl:%s\n' "$s" \
    "$(rg -c "^## $s\$" CLAUDE.md || echo 0)" "$(rg -c "^## $s\$" "$TPL" || echo 0)"
done

# 3. Conditional Code Navigation contract intact on BOTH ends
rg -n 'Code Navigation \(LSP\)' "$GEN"                # EXPECT >=1 (generator still emits it)
rg -n 'Code Navigation' .claude/hooks/nudge-lsp.sh    # EXPECT >=1 (hook still probes it)
rg -n 'Code Navigation' CLAUDE.md                     # EXPECT no output (absent from seed by design)

# 4. Mandatory lists protect all 11 anchors + policy-retained Error Handling. EXPECT: no output.
#    Match the list ITEM (backtick-wrapped), not a substring — plain "Commands" matches inside
#    "Search Commands" and hides a genuinely missing entry.
#    Stop at the first BLANK line after the marker — the two files format the list differently
#    (generator: indented `- ` items; template: a blockquote). Exiting on `^**Generate` works only
#    for the generator: on the template it runs to EOF and returns 221 lines, so any later
#    backtick-wrapped mention masks a genuinely missing entry.
for f in "$GEN" "$TPL"; do
  BLOCK=$(awk '/DO NOT remove or soften/{f=1} f&&NF==0{exit} f' "$f")
  for s in "Language Rules" "Validation" "Commands" "Code Structure & Modularity" \
           "Style & Conventions" "Tech Stack" "Automatic Behaviors" "Search Commands" \
           "Security" "Git Workflow" "Project Knowledge Layers" "Error Handling"; do
    printf '%s' "$BLOCK" | rg -q -F -- "\`$s\`" || echo "MISSING from $f list: $s"
  done
done

# 5. Deletions applied in both files. EXPECT: no output
rg -n '^## (Proactive Agent Usage|Plan Mode|On-Demand Context)' CLAUDE.md "$TPL"

# 6. Binary rule gone from both. EXPECT: no output
rg -n 'NEVER ASSUME OR GUESS' CLAUDE.md "$TPL"

# 7. SIZE — both axes are hard. Seed: whole file. Template: BODY ONLY (from `# CLAUDE.md`, line 20)
#    — the 19-line preamble is generator instructions and never reaches a generated CLAUDE.md.
#    EXPECT: no output. (Baseline pre-change: seed 239/18700, tpl body 218/9295.)
sl=$(wc -l < CLAUDE.md); sc=$(wc -c < CLAUDE.md)
tl=$(tail -n +20 "$TPL" | wc -l); tc=$(tail -n +20 "$TPL" | wc -c)
printf 'seed: %s lines / %s chars\ntpl body: %s lines / %s chars\n' "$sl" "$sc" "$tl" "$tc"
[ "$sl" -gt 165 ]  && echo "🔴 seed over 165 lines"
[ "$sc" -gt 9500 ] && echo "🔴 seed over 9500 chars"
[ "$tl" -gt 165 ]  && echo "🔴 tpl body over 165 lines"
[ "$tc" -gt 9500 ] && echo "🔴 tpl body over 9500 chars"

# 8. Out-of-scope sections BYTE-IDENTICAL in both files. Comparing whole extracted blocks, not
#    grepping the diff for a heading name — a body edit that never repeats the heading is invisible
#    to that. EXPECT: no output
for s in "Validation" "Commands" "Tech Stack" "Style & Conventions" "Project Overview"; do
  [ "$(sect /tmp/base-seed.md "$s" | shasum)" = "$(sect CLAUDE.md "$s" | shasum)" ] \
    || echo "🔴 CHANGED in seed: $s"
  [ "$(sect /tmp/base-tpl.md "$s" | shasum)" = "$(sect "$TPL" "$s" | shasum)" ] \
    || echo "🔴 CHANGED in template: $s"
done

# 9. Project Knowledge Layers keeps its table, with consistent columns.
#    EXPECT 8 lines / 4 columns, not ragged. (Pre-cut this reads 16 lines RAGGED because the
#    routing-discoveries subsection's 3-column table is still inside the section.)
sect CLAUDE.md "Project Knowledge Layers" | rg '^\|' \
  | awk -F'|' 'NR==1{c=NF} NF!=c{bad=1} END{printf "%d table lines, %d columns%s\n", NR, c-2, (bad?"  🔴 RAGGED":"")}'

# 10. Automatic Behaviors triggers. EXPECT: seed 11, tpl 11 (tpl was 7 — Step B closes a gap of 4).
#     A COUNT is a weak check: it passes if a trigger is swapped for a different one. So also assert
#     the four semantics Step B adds, and that the domain-file pointer was fixed, not copied.
for f in CLAUDE.md "$TPL"; do printf '%s: %s triggers\n' "$f" "$(sect "$f" "Automatic Behaviors" | rg -c '^- \*\*')"; done
for pat in 'non-trivial response' 'Before editing code' 'reflection-protocol' 'Output-Discipline'; do
  sect "$TPL" "Automatic Behaviors" | rg -q "$pat" || echo "🔴 tpl missing trigger semantics: $pat"
done
sect "$TPL" "Automatic Behaviors" | rg -q "domain/.*index\.md" && echo "🔴 tpl still points domain-file template at index.md"

# 11. No monster line left — EXCEPT the two content contracts, which must stay at full length.
#     EXPECT: no output. (`Orchestrate publish` blockquote ~500 chars, Output-Discipline ~462.)
awk 'length($0)>400 && $0 !~ /publish mode/ && $0 !~ /Output-Discipline/ {printf "LONG LINE %d: %d chars\n", NR, length($0)}' CLAUDE.md

# 12. Generator cap gate must be EXECUTABLE, not prose. Grepping for the string "wc -l" passes on a
#     sentence; require a real numeric comparison too, then READ the snippet.
rg -n 'wc -l' "$GEN"                       # EXPECT: a shell snippet assigning the count
rg -n '\-gt 165|\-le 165|-ge 9500|-gt 9500' "$GEN"   # EXPECT >=1 numeric branch
rg -n '9500|9 500' "$GEN"                  # EXPECT: the char threshold present

# 13. Section-set diff — template a superset by exactly {Testing, Notes}
rg -o '^## .*' CLAUDE.md | sort > /tmp/s.txt; rg -o '^## .*' "$TPL" | sort > /tmp/t.txt
comm -13 /tmp/s.txt /tmp/t.txt   # EXPECT exactly: ## Notes, ## Testing
comm -23 /tmp/s.txt /tmp/t.txt   # EXPECT: empty

# 14. No category-C leak: generator must not cite the spec. EXPECT: no output
rg -n '\.agents/specs/' "$GEN"

# 15. CONTENT CONTRACT — `Orchestrate publish` survives in all three files. A heading sweep cannot
#     see this: it is a line inside a section, and losing it throws no error anywhere.
#     EXPECT: seed 1 (filled `push`), tpl >=1 (placeholder), gen >=2 (derive + fill). No 🔴 lines.
rg -c '^\*\*Orchestrate publish:\*\*' CLAUDE.md          || echo "🔴 seed lost the Orchestrate publish line"
rg -q 'Orchestrate publish' "$TPL"                       || echo "🔴 template lost the publish slot"
rg -q 'Orchestrate publish' "$GEN"                       || echo "🔴 generator lost the fill instruction"
rg -n 'Orchestrate publish' .claude/commands/orchestrate.md   # EXPECT: the consumer at ~line 103

# 16. CONTENT CONTRACT — the force-remove guard. Either it still lives in CLAUDE.md, or it was moved
#     and orchestrate.md:660 was repointed. Exactly one of those must hold. EXPECT: "OK" line.
if rg -qi 'worktree remove --force|force-remove' CLAUDE.md; then
  echo "OK — guard kept in CLAUDE.md"
elif ! rg -q 'CLAUDE.md.*Git Workflow' .claude/commands/orchestrate.md; then
  echo "OK — guard moved and the consumer no longer cites CLAUDE.md"
else
  echo "🔴 guard deleted from CLAUDE.md but orchestrate.md still cites it — dangling reference"
fi

# 17. The generator cannot resurrect a section this step deleted. EXPECT: no output.
rg -n 'On-demand context references' "$GEN"
rg -n 'only generic triggers' "$GEN"      # the stale 3-trigger description must be gone
```

---

## Definition of Done

- [ ] All 11 contractual anchors survive verbatim in both files; `Project Knowledge Layers` keeps its
      table
- [ ] **Both content contracts intact**: `**Orchestrate publish:**` in seed + template + generator;
      the force-remove guard either kept in `CLAUDE.md` or moved with `orchestrate.md:660` repointed
- [ ] `CLAUDE.md` ≤165 lines **and** ≤9 500 chars — or the deviation is reported with a reason
- [ ] Template **body** (from `# CLAUDE.md`, line 20) ≤165 lines **and** ≤9 500 chars — the preamble
      is excluded from the measurement, not from the file
- [ ] `NEVER ASSUME OR GUESS` gone from both files; both carry **11** Automatic Behaviors triggers,
      and the template's domain-file trigger points at `reflection-protocol.md`
- [ ] The three zero-referent sections removed from seed **and** template
- [ ] Template preamble declares `≤165 lines`; mandatory list drops the two removed sections and gains
      `Validation`, `Commands`, `Style & Conventions`, `Tech Stack`
- [ ] `create-CLAUDE_MD.md`: `≤165`, protected-name list + heading-outward verification command,
      **no frozen `file:line` table**, **executable** post-generation cap gate, stale 3-trigger
      description fixed, `On-demand context references` licence removed, no `.agents/specs/` reference
- [ ] Template remains a superset by exactly `{Testing, Notes}`
- [ ] `Validation`, `Commands`, `Tech Stack`, `Style & Conventions`, `Project Overview` byte-identical
- [ ] Every Level 3 check run (17, not 14); before→after line **and** char counts recorded

## Commit

`refactor(context): slim the always-loaded layer for Claude 5 models`

Body: state the before→after line and char counts, name the three deleted sections and why each had
zero referents, and note that the generator's cap is now enforced rather than declared.
