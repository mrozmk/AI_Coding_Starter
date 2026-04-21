---
name: Conventional Commits
description: This skill should be used when the user asks to "write a commit message", "format commit", "conventional commits", "commit lint", "commitlint", "git commit format", or needs guidance on commit message structure, types, scopes, and best practices.
version: 1.0.0
---

# Conventional Commits

## Overview

Conventional Commits is a specification for writing standardized commit messages. This skill provides guidance on writing commit messages that are both human and machine-readable.

## Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

## Commit Types

| Type | When to Use | Example |
|------|-------------|---------|
| `feat` | New feature for the user | `feat(cart): add quantity selector` |
| `fix` | Bug fix | `fix(auth): resolve session timeout issue` |
| `docs` | Documentation changes only | `docs: update installation guide` |
| `style` | Formatting, no code change | `style: fix indentation in utils` |
| `refactor` | Code change, no new feature or fix | `refactor(api): simplify error handling` |
| `perf` | Performance improvement | `perf(query): optimize user search` |
| `test` | Adding or fixing tests | `test: add unit tests for checkout` |
| `chore` | Maintenance tasks | `chore(deps): update lodash` |
| `ci` | CI/CD changes | `ci: add deploy workflow` |
| `build` | Build system changes | `build: update webpack config` |
| `revert` | Reverting commits | `revert: feat(cart): add quantity selector` |

## Scope

The scope is optional and describes what part of the codebase changed — **not a ticket number**:

- **Module/component name**: `feat(auth):`, `fix(payment):`
- **File/area affected**: `docs(readme):`, `test(api):`
- **Layer**: `refactor(service):`, `fix(controller):`

## Description Rules

1. **Imperative mood** - "add" not "added" or "adds"
2. **Lowercase** - Start with lowercase letter
3. **No period** - Don't end with a period
4. **Concise** - Under 72 characters
5. **What, not how** - Describe the change, not implementation

### Good Descriptions

```
feat(user): add email verification flow
fix: resolve null reference in order processing
refactor(api): simplify authentication middleware
```

### Bad Descriptions

```
feat(user): Added email verification.     # Past tense, period
fix: Fix the bug                          # Capitalized, vague
refactor: refactoring authentication      # Gerund form
```

## Body

The body is optional and provides additional context:

```
fix(payment): handle declined card gracefully

Previously, declined cards caused an unhandled exception.
Now we catch the error and display a user-friendly message
with retry options.
```

Rules for body:
- Separate from description with blank line
- Wrap at 72 characters
- Explain the "what" and "why", not the "how"

## Footer

Footers are optional and used for:

### Breaking Changes

```
feat(api): change authentication endpoint

BREAKING CHANGE: /auth/login now returns JWT instead of session cookie.
Clients must update their token handling.
```

### Issue References

```
fix(checkout): resolve race condition in inventory check

Fixes #123
Closes #456
Refs #789
```

### Ticket References (Jira, Linear, etc.)

Keep the subject line clean — put the ticket reference in the footer trailer, not the scope:

```
feat(auth): add SSO integration

Refs: PROJ-123
```

Or multiple tickets:

```
fix(checkout): resolve payment race condition

Refs: PROJ-456, TEAM-789
```

### Co-authors

```
feat(dashboard): add analytics widget

Co-Authored-By: Jane Doe <jane@example.com>
Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```

## Breaking Changes

Two ways to indicate breaking changes:

1. **Footer notation** (preferred for details):
   ```
   feat(api): change response format

   BREAKING CHANGE: Response now uses camelCase keys.
   ```

2. **Exclamation mark** (quick indication):
   ```
   feat(api)!: change response format
   ```

## Examples by Scenario

### Adding a Feature

```
feat(notifications): add push notification support

Implement Firebase Cloud Messaging integration for real-time
push notifications. Supports both foreground and background
message handling.

Refs: PROJ-234
```

### Fixing a Bug

```
fix(form): prevent duplicate submission

Add debounce to submit handler and disable button during
API call to prevent duplicate orders.

Refs: TEAM-567
```

### Updating Dependencies

```
chore(deps): upgrade react to 18.2.0

- Update react and react-dom
- Adjust concurrent mode usage
- Update tests for new behavior
```

### Documentation

```
docs(api): add authentication examples

Include curl examples for all auth endpoints and common
error responses.
```

### Refactoring

```
refactor(services): extract shared validation logic

Move duplicate validation code from UserService and
OrderService into shared ValidationService.
```

## Automation Benefits

Conventional commits enable:

1. **Automatic changelogs** - Group changes by type
2. **Semantic versioning** - Determine version bumps:
   - `fix` → patch (1.0.0 → 1.0.1)
   - `feat` → minor (1.0.0 → 1.1.0)
   - `BREAKING CHANGE` → major (1.0.0 → 2.0.0)
3. **Filtered history** - `git log --grep="^feat"` for features only
4. **CI/CD triggers** - Different pipelines for different types
