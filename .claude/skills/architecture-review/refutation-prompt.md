You are asked to test claims made about this repository at revision {{revision}}.

This pass is not independent: you are shown claims to test. Treat each one as a hypothesis someone
else believes, and try to break it — agreement you did not check is worth nothing.

First orient yourself: read `.claude/commands/prime.md` and follow its quick-mode steps by reading
the files it names (not as a slash command). Read `CLAUDE.md` in full. Skip prime.md's repo-state
step.

## Records to test

{{records}}

Each record carries a `claim` (what is wrong), a `rule` (the promise or rule it breaks), `anchors`
(where), a `consequence` (what follows, `measured` or `predicted`) and a `change` (the proposed fix).

## Task

For each record, test the claim, the stated consequence and the proposed change separately, and try
to refute each in the code:

- `confirmed` — the claim, the consequence and the change hold as written.
- `overstated` — one element goes further than the code supports (a right diagnosis with an
  over-broad change, a real defect with an exaggerated consequence). Put the narrower version in
  `correction`.
- `refuted` — the claim does not hold; give the counter-evidence with anchors.
- `not-checked` — you could not anchor it in the code; say why in `evidence`.

`target` names the element your verdict is about: `claim`, `consequence` or `change`.

Seek the cheapest observation that could overturn each record. Run a command only when everything
it writes fits the sandbox's scratch space with caches disabled; never write into the checkout. What
you could not run stays `evidence_kind: static`.

## Output

Your whole final message is one JSON object, nothing before or after it:

```
{"results": [{"id": "...", "verdict": "...", "target": "...", "correction": "...", "evidence": "...", "evidence_kind": "...", "command": null}]}
```

- `id` — the record's id, exactly as given; one result per record
- `verdict` — `confirmed`, `overstated`, `refuted` or `not-checked`
- `target` — `claim`, `consequence` or `change`
- `correction` — the narrower or corrected statement; empty string when `confirmed`
- `evidence` — what you read or ran, with `path:line`
- `evidence_kind` — `static`, `test`, `probe` or `runtime`
- `command` — the command you ran, or `null` when nothing ran

## Read-only

Edit, create or delete nothing in this repository.
