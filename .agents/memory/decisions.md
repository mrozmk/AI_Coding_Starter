# Memory: Decisions

Architectural and technical decisions with rationale.

Add newest entries at the **TOP**.

---

## Format

```
## YYYY-MM-DD — Title

**Decision:** what was decided
**Why:** reasoning
**Alternatives considered:** what was rejected and why
**Impact:** where this shows up in the code
```

---

## 2026-06-30 — Backlog is the single source of truth for delivery order; Jira is a one-way manual mirror

**Decision:** `.agents/backlog.md` holds the canonical "what to build, in what order" map and is created first, always. Jira (when used) derives its issues *from* the backlog via `/jira bulk` — a manual/assisted export, no automatic sync — strictly one-way (backlog → Jira). A bare `/brainstorm` (no topic, no Jira reference) now resolves its topic from the backlog: next free task (Status `TODO`, all `Dependencies` `DONE`, lowest `Wave`), with a stale-status guard.
**Why:** Two parallel task lists (backlog + Jira) drift. One source of truth removes the redundancy. Making bare `/brainstorm` pull from the backlog lets the user work "top of the backlog" without retyping task names.
**Alternatives considered:** "Backlog OR Jira, pick one" (rejected — backlog and Jira are different layers, not interchangeable; a team wants both, just not as two task lists). "Backlog mandatory unless Jira" (rejected — contradicts the `opt-in` invariant repeated in plan-feature/orchestrate/create-backlog: a project without a backlog has an untouched pipeline).
**Impact:** `brainstorm.md` Step 0; `create-backlog.md` (E0-1 scaffold now a MUST as first dependency-free task on greenfield); CLAUDE.md + README delivery-map notes; `docs/TUTORIAL.md` Step 3.

## 2026-06-30 — `git remote add` stays denied for Claude; remote is set up via "Use this template" or by the user

**Decision:** Keep `git remote add` (and `remote set-url`/`remove`/`rename`) in `settings.json` `deny`. The tutorial's primary onboarding is **"Use this template" on GitHub** (gives the user a repo with `origin` already wired from the first second), so no `git remote add` is needed. The fallback `git clone` path requires the user to run `git remote add origin <url>` themselves in the terminal — Claude must NOT do it.
**Why:** Wiring a remote is a deliberate, security-sensitive act (where your code gets published). CLAUDE.md explicitly protects this. Letting Claude add a remote from a chat-supplied URL would weaken that guard for the convenience of a once-per-project command.
**Alternatives considered:** Unblock `git remote add` so the user pastes a URL and Claude wires it (rejected — weakens a deliberate security boundary). Add a manual `git remote add` step at project start (rejected — "Use this template" achieves remote-from-start with zero extra commands).
**Impact:** `docs/TUTORIAL.md` "Stwórz swoje repo" section + Krok 11; `settings.json` deny list (unchanged, by design). NOTE for future sessions: do not "helpfully" propose `git remote add` or unblocking it — it is intentional.
