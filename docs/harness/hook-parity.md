# Hook parity — legacy .claude/hooks → shared core + host adapters

> Rendered from `harness-source/contracts/hook-parity.json`. Activation: **none** — No real project has activated the ported hooks. Legacy .claude/hooks/*.sh stay registered in .claude/settings.json until an installed-host run records their replacement (installation.md → Activation). A unit test is not an activation.

| Hook | Strength | Core | Claude | Codex | Tests |
|---|---|---|---|---|---|
| `guard-commit` | hard | harness-source/hooks/core/commit.mjs | ported · exit 2 + stderr (deny) | ported · exit 2 + stderr (deny) | tests/harness/hook-guards.test.mjs |
| `guard-push` | hard | harness-source/hooks/core/push.mjs | ported · exit 2 + stderr (deny) | ported · exit 2 + stderr (deny) | tests/harness/hook-guards.test.mjs |
| `guard-memory` | hard | harness-source/hooks/core/memory-guard.mjs | ported · exit 2 + stderr (deny) | conditional · exit 2 + stderr (deny) | tests/harness/hook-guards.test.mjs, tests/harness/hook-context-scope.test.mjs |
| `guard-comments` | advisory | harness-source/hooks/core/comments.mjs | ported · hookSpecificOutput.additionalContext | ported · hookSpecificOutput.additionalContext | tests/harness/hook-advisory.test.mjs |
| `nudge-files` | advisory | harness-source/hooks/core/nudge-files.mjs | ported · hookSpecificOutput.additionalContext | ported · hookSpecificOutput.additionalContext | tests/harness/hook-advisory.test.mjs |
| `guard-memory-scope` | advisory | harness-source/hooks/core/memory-scope.mjs | ported · hookSpecificOutput.additionalContext | ported · hookSpecificOutput.additionalContext | tests/harness/hook-advisory.test.mjs |
| `track-memory-read` | telemetry | harness-source/hooks/core/memory-read.mjs | ported · none (side effect only) | conditional · none · Codex has no Read tool event; only shell reads are observed. Missing telemetry is unknown usage, never evidence a file is unused. | tests/harness/hook-telemetry.test.mjs |
| `audit-append` | telemetry | harness-source/hooks/core/audit.mjs | ported · none | conditional · none · Hosted web tools carry no hook; fetches are not audited on Codex. | tests/harness/hook-telemetry.test.mjs |
| `nudge-lsp` | advisory | harness-source/hooks/core/lsp-hint.mjs | conditional · hookSpecificOutput.additionalContext · when project declares an LSP (rules Code Navigation section present) | legacy-only · Codex has no structured Grep tool and no symbol-navigation surface; parsing shell bodies as if they were Grep is not a port. | tests/harness/hook-advisory.test.mjs |
| `check-deps` | preflight | harness-source/hooks/core/deps.mjs | ported · hookSpecificOutput.additionalContext | ported · hookSpecificOutput.additionalContext | tests/harness/hook-preflight.test.mjs |
| `check-project-deps` | preflight | — | project-owned · stdout relayed as additionalContext | project-owned · stdout relayed as additionalContext | tests/harness/hook-preflight.test.mjs |

## Known limits

- `guard-commit`: Chained `git add X && git commit` is blocked by design (the index is inspected before the chain runs).
- `guard-commit`: Only `git -C <dir>` and a leading `cd <dir> &&` are parsed; other directory changes fall back to the caller cwd.
- `guard-push`: Allowlisted paths (examples, lockfiles, docs, fixtures, this guard) are not scanned — a secret placed in a `.md` file ships.
- `guard-push`: Without git the check cannot run: it reports the missing infrastructure and does not claim protection.
- `guard-memory`: The marker is an acknowledgement, not proof the model understood memory.
- `track-memory-read`: Best-effort counter; a lost increment under concurrent hooks is acceptable.
- `audit-append`: Attempted (PreToolUse) and completed (PostToolUse) events are distinct lines; prompts, contents and credentials are never logged.
- `check-deps`: Missing infrastructure is reported as missing protection, never as healthy enforcement.
- `check-project-deps`: Its .env presence checks stay inside the script; the runner never reads .env and never exports its output to a reviewer.
