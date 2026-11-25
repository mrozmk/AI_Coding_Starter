# /wcag-audit — judge contract

Human-readable copy of the contract in `runner/lib/contract.mjs`. `pack` writes that object into the
trusted header of every pack; `ingest` validates every answer against it. Change the code, then this
file.

## Item kinds

| Kind | `allowed_sc` | False positive if… |
|---|---|---|
| `alt-vs-image` | 1.1.1 | the image is decorative and `alt=""`; the alt names what the crop shows or its purpose in the surrounding text |
| `link-purpose` | 2.4.4 | the surrounding sentence, heading, list item or table cell names the target |
| `heading-label` | 2.4.6 | the heading or label names the topic or purpose of its section or field |
| `heading-structure` | 1.3.1 | the visual hierarchy matches the heading levels in the excerpt |
| `language-of-parts` | 3.1.2 | the passage is a proper name, technical term or a word that became part of the page language |
| `label-in-name` | 2.5.3 | the visible label text appears in the accessible name (case and punctuation aside) |
| `error-text` | 3.3.1, 3.3.3 | the message names the field and says what is wrong and how to fix it |
| `consistent-help` | 3.2.6 | the help mechanism appears in the same relative order on every scanned page that has it |
| `axe-incomplete` | the SC of that axe rule | the evidence shows the rule condition is met (e.g. enough contrast at every sampled point) |

A broken image (HTTP error or nothing decoded) is never a judge item: the runner reports it as
`broken-image` with its load diagnostic.

## Output schemas

Probe:

```json
{"probe": "done", "nonce": "<nonce>"}
```

Judge — one answer per item; `outcome` is `needs-review` or `no-issue-seen`; `impact` is `blocker`,
`serious`, `moderate` or `minor`; texts ≤ 300 characters:

```json
{"phase": "judge", "nonce": "<nonce>", "answers": [{"item_id": "s1", "sc": "1.1.1", "outcome": "needs-review", "impact": "moderate", "rationale": "…", "false_positive_if": "…"}]}
```

Disprove — `verdict` is `upheld` or `rejected`:

```json
{"phase": "disprove", "nonce": "<nonce>", "answers": [{"candidate_id": "c-s1", "verdict": "upheld", "reason": "…"}]}
```

## Ingest rules

Dropped and logged in `run.json → model.dropped[]`: invalid JSON, an unknown or missing key, an enum
outside the schema, an unknown `item_id`/`candidate_id`, an `sc` outside the item's `allowed_sc`, an
answer for another phase, a wrong or missing nonce, a text over the cap, and any answer that addresses
a non-model finding. Only a candidate with a valid `upheld` answer is published, always as ◐
`suspected`; the rest go to the needs-review queue as manual checks.
