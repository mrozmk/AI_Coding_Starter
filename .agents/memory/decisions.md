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

## 2026-04-30 — Token-prefix deny patterns over broad curl-form bans

**Decision:** `.claude/settings.json` denies Bash commands containing literal token prefixes (`ATATT`, `ghp_`, `github_pat_`, `gho_`, `ghs_`, `ghu_`, `xoxb-`, `xoxp-`, `xapp-`, `xoxa-`, `AKIA`, `ASIA`, `sk-ant-`) rather than blocking entire command shapes like `Bash(curl * -u *)` or `Bash(curl * -H *Authorization:*)`.
**Why:** broad shape-bans block both the leaky form (`-u "user:hardcodedToken"`) AND the secure env-var form (`-u "$USER:$TOKEN"`, `-H "Authorization: Bearer $TOKEN"`) — they don't distinguish literal secret from `$VAR` reference. Prefix matching catches only the literal-token case, which is the exact failure mode (a "hardcoded token gets cached in `permissions.allow` after an Always-allow click" incident in another project).
**Alternatives considered:**
- Broad curl/wget shape bans — rejected: too many false positives, would push users to remove the rule.
- DB-URL credential patterns (`postgres://*:*@*` etc.) — rejected: Claude Code's permission validator forbids `:*` in the middle of a glob (legacy prefix-match conflict). DB URLs are also normally consumed via env vars.
- PreToolUse hook with regex secret scanner — rejected for v1: more moving parts, runs on every Bash call. Reconsider if compliance/audit requirements escalate.
**Impact:** [.claude/settings.json](../../.claude/settings.json) lines 75-87. Documented in [README.md](../../README.md) "Permissions & safety" and [CLAUDE.md](../../CLAUDE.md) Security. When adding support for a new SaaS provider whose tokens carry a stable documented prefix, append a new `Bash(*PREFIX*)` line — keep the zero-false-positive bar.

---



