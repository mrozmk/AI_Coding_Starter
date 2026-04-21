---
name: Branch Naming
description: This skill should be used when the user asks to "create a branch", "name a branch", "branch naming convention", "git branch format", or needs guidance on branch naming patterns, prefixes, and organization.
version: 1.0.0
---

# Branch Naming Conventions

## Overview

Consistent branch naming improves repository organization, enables automation, and makes collaboration easier. This skill covers branch naming patterns for plugin development and general workflows.

## Format

```
{prefix}/{description}
{prefix}/{TICKET-ID}-{description}
{prefix}/{plugin-name}/{description}
```

## Valid Prefixes

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New features | `feat/user-authentication` |
| `fix/` | Bug fixes | `fix/login-timeout` |
| `hotfix/` | Urgent production fixes | `hotfix/security-patch` |
| `docs/` | Documentation changes | `docs/api-reference` |
| `test/` | Test additions/changes | `test/checkout-flow` |
| `chore/` | Maintenance tasks | `chore/update-deps` |
| `refactor/` | Code restructuring | `refactor/api-client` |

## Naming Rules

1. **Start with valid prefix** - Must use one of the prefixes above
2. **Use kebab-case** - Lowercase with hyphens: `my-feature`
3. **No uppercase** - All lowercase letters
4. **No underscores** - Use hyphens instead: `my-feature` not `my_feature`
5. **Be descriptive** - Clear but concise names
6. **No special characters** - Avoid `@`, `#`, `$`, etc.
7. **Never commit directly to main**

## Branch Patterns

### Simple Feature/Fix

For work not tied to a specific module:

```
{prefix}/{description}
```

Examples:
- `feat/oauth-integration`
- `fix/memory-leak`
- `docs/installation-guide`
- `chore/ci-pipeline`

### With Ticket Tracker (Jira, Linear, etc.)

When work is tracked in a ticket system, include the ticket reference in the branch name:

```
{prefix}/{TICKET-ID}-{description}
```

Examples:
- `feat/PROJ-123-oauth-integration`
- `fix/TEAM-456-memory-leak`
- `docs/PROJ-789-api-reference`

GitLab surfaces the branch name prominently and the tracker integration picks up the reference automatically.

### Plugin/Module Work

For work on a specific plugin or module:

```
{prefix}/{plugin-name}/{description}
```

Examples:
- `feat/docflow/confluence-templates`
- `fix/docflow/jira-auth-error`
- `refactor/git-conventions/hook-structure`

### New Plugin Creation

When creating a new plugin, use flat structure:

```
feat/{plugin-name}
```

Examples:
- `feat/code-reviewer`
- `feat/symfony-developer`
- `feat/git-conventions`

## Common Mistakes

### Wrong Prefix

```
feature/login        # Should be: feat/login
bugfix/timeout       # Should be: fix/timeout
documentation/api    # Should be: docs/api
```

### Wrong Case

```
Feat/Login           # Should be: feat/login
feat/User_Auth       # Should be: feat/user-auth
FEAT/login           # Should be: feat/login
```

### Missing Prefix

```
add-login            # Should be: feat/add-login
fix-bug              # Should be: fix/bug (or more descriptive)
```

## Integration with Commits

Branch names often align with commit types:

| Branch Prefix | Commit Type |
|---------------|-------------|
| `feat/` | `feat:` |
| `fix/` | `fix:` |
| `docs/` | `docs:` |
| `test/` | `test:` |
| `chore/` | `chore:` |
| `refactor/` | `refactor:` |

Example workflow:
```bash
# Create branch
git checkout -b feat/user-notifications

# Commits on this branch
git commit -m "feat(notifications): add email service"
git commit -m "feat(notifications): add push support"
git commit -m "test(notifications): add unit tests"
```

## Branch Lifecycle

### Feature Development

```
main
  └── feat/user-auth
        ├── commit: feat(auth): add login endpoint
        ├── commit: feat(auth): add session handling
        └── commit: test(auth): add integration tests

# Merge back to main when complete
```

### Bug Fixes

```
main
  └── fix/cart-calculation
        ├── commit: fix(cart): correct tax calculation
        └── commit: test(cart): add edge case tests

# Merge back to main when verified
```

### Hotfixes

```
main (production)
  └── hotfix/security-vulnerability
        └── commit: fix(security): patch XSS vulnerability

# Merge directly to main, potentially cherry-pick to develop
```

## Automation Benefits

Consistent branch naming enables:

1. **CI/CD triggers** - Different pipelines for `feat/` vs `hotfix/`
2. **Protected branches** - Rules based on patterns
3. **Auto-labeling** - PRs labeled based on branch prefix
4. **Release notes** - Group changes by branch type
5. **Clean history** - Easy to filter and search

## Examples by Scenario

### Starting New Feature

```bash
git checkout -b feat/payment-gateway
# or with Jira ticket
git checkout -b feat/PROJ-123-payment-gateway
```

### Fixing Reported Bug

```bash
git checkout -b fix/order-total-calculation
# or with Jira ticket
git checkout -b fix/TEAM-456-order-total-calculation
```

### Plugin Enhancement

```bash
git checkout -b feat/docflow/confluence-templates
```

### Documentation Update

```bash
git checkout -b docs/contributing-guide
```

### Urgent Production Fix

```bash
git checkout -b hotfix/authentication-bypass
# or with Jira ticket
git checkout -b hotfix/PROJ-999-authentication-bypass
```
