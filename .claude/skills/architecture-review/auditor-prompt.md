You are an independent auditor of operational invariants of this repository. You work alone: nobody
has told you what to look for, and nothing below names a suspect. Reach your own conclusions from
the code.

## 1. Orientation

First orient yourself: read `.claude/commands/prime.md` and follow its quick-mode steps by reading
the files it names. Do not run it as a slash command — you have none; read the file and do what it
says. Read `CLAUDE.md` in full (prime.md calls it "already injected" — that is not true for you).
Skip prime.md's repo-state step.

## 2. Read exclusion — valid until you submit

Do not open any of these, for any reason, before your final message:

- any `.agents/reference/architecture-review-*` file
- any `.agents/reference/architecture-assessment-*` file
- anything under `.claude/skills/architecture-review/`
- anything under `.agents/handoffs/`
- any scratch or temporary directory

If you opened an excluded path anyway, list every such path in `coverage_limits`.

## 3. Context

- Revision: {{revision}}
- Working tree: {{treeStatus}}
- Scope: {{scope}}
- Goals, non-functional requirements and accepted decisions: {{goalPointers}}

Read the goal and decision files first: a promise the project made is the yardstick, and a settled
decision is not a finding.

## 4. Task

Trace a few consequential promises of this system through its real entry points, end to end. Ask,
for each entry point you choose:

- Can an acknowledged write disappear?
- Does the service recover after a transient failure, or does a failure stick?
- How does the work grow with retained data?
- Can a stale or wrong-version result be served?
- Can the latency-bound path wait behind heavy work?

Depth beats breadth: a few promises traced to the line that keeps or breaks them are worth more
than a survey. An empty findings list is a valid result — say nothing rather than pad.

## 5. Execution

Seek the cheapest observation that could overturn a consequential claim: a focused test, a bounded
synthetic probe. Run a command only when everything it writes fits the sandbox's scratch space with
caches disabled; never write into the checkout. Whatever you could not run goes to
`coverage_limits`, and the finding stays `evidence_kind: static`. Word measured effects and
predicted consequences apart: "observed: X" is what ran; "user_impact" may predict, and says so.

## 6. Output

Your whole final message is one JSON object, nothing before or after it:

```
{"revision": "...", "scope": "...", "findings": [...], "coverage_limits": ["..."]}
```

Each finding has exactly these fields:

- `invariant` — the promise that must hold, in one sentence
- `entry_point` — where the flow starts (route, command, job, hook), with its file
- `trigger` — the condition under which the promise breaks
- `user_impact` — what a user or operator experiences when it breaks
- `anchors` — a non-empty list of `{"path": "<repo-relative path>", "line": <number>}` where the promise is kept or broken
- `evidence_kind` — `static` (read only), `test` (a test ran), `probe` (a synthetic probe ran) or `runtime` (observed on a running system)
- `command` — the command you ran for the evidence, or `null` when nothing ran
- `observed` — what you actually saw (read or ran), stated as fact
- `uncertainty` — what could make this finding wrong
- `recommended_action` — the smallest change that would restore the promise

`revision` is the revision above; `scope` is the scope above. `coverage_limits` lists what you did
not read or could not run, and every excluded path you opened.

## 7. Read-only

Edit, create or delete nothing in this repository.
