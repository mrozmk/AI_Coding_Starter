---
description: Re-explain what just happened in plain language — short, concrete, decision-ready
argument-hint: "[optional: what to re-explain | empty → the last thing we did]"
---

# /simply — say it again, simply

## Focus: $ARGUMENTS

Re-state what we just did / decided / found, following the rules below.

**If `$ARGUMENTS` is empty**, the subject is the immediately preceding work in this
conversation — your last answer, the last command that ran, or the last decision made.
Do not ask what to summarize; pick the obvious subject and say which one you picked.

---

## Rules

Talk to me like a tired human at the end of a long day — simply, like I'm 5.

Small words, short sentences, short paragraphs. If you have to use a big word,
explain it right after. Only return what's actually necessary.

Just tell me what you did, did it work, what do I do now.

If I have to decide something: 3 options max, the minimum context I need to
pick fast, one marked as your recommendation.

Keep paths and commands exact, verbatim.

---

## Shape of the answer

Four short blocks, in this order (the fourth is optional). Drop any block that
has nothing real in it — an empty block is noise.

1. **What I did** — what happened, 1–3 sentences.
2. **Did it work** — yes / no / partly, plus the one fact that proves it
   (test output, exit code, the file that now exists). If something failed, say it
   plainly — never round a failure up to a success.
3. **What now** — the single next thing to do, as an exact command or path.
   If there is a real choice, then and only then: max 3 options, one marked
   **← recommended**.
4. **Want more?** *(optional)* — one closing sentence naming 1–2 concrete
   topics you deliberately simplified or dropped, e.g. "I can expand on: why
   the test failed / what this hook does — want that?". Omit it when nothing
   was simplified — an empty offer is noise.

---

## Hard rules (these do not bend)

- **Language: the project's communication language** (per CLAUDE.md → Language
  Rules), including the three block headers above — translate them; paths,
  commands, code and identifiers stay verbatim, never translated, never
  reformatted.
- **Simplify the wording, never the facts.** Do not drop a caveat, a failed step,
  or a risk because it complicates the sentence. If a thing is uncertain, say
  "I'm not sure" in plain words — do not smooth it into confidence.
- **No new work.** This command only re-explains what already happened. Do not
  edit files, run fixes, or start the next step — just say what the next step is.
  That includes memory: never write to `.agents/memory/` from this command.
- **No headers beyond the blocks above, no nested bullets. Tables: no by
  default** — yields only at a real choice between options, when one simple
  table (max 3 rows × 3 columns, no nesting) is shorter and clearer than
  describing the options in prose.
