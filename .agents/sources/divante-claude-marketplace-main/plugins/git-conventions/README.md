# Git Conventions Plugin

A Claude Code plugin that enforces consistent git workflow conventions through branch naming and commit message validation.

## Features

- **Branch Name Validation** - Ensures branches follow naming conventions with proper prefixes
- **Commit Message Linting** - Validates commit messages against Conventional Commits format
- **Skills Reference** - Provides Claude with knowledge of conventions for natural assistance

## Installation

Add this plugin to your Claude Code project:

```bash
claude --plugin-dir ./plugins/git-conventions
```

Or reference it in your settings for the marketplace:

```json
{
  "plugins": ["./plugins/git-conventions"]
}
```

## Branch Naming

### Prefixes

| Prefix | Purpose |
|--------|---------|
| `feat/` | New features |
| `fix/` | Bug fixes |
| `hotfix/` | Urgent production fixes |
| `docs/` | Documentation |
| `test/` | Tests |
| `chore/` | Maintenance |
| `refactor/` | Code restructuring |

### Patterns

```bash
# Simple work
{prefix}/{description}
# Examples: feat/user-auth, fix/login-bug, docs/api-reference

# With Jira ticket
{prefix}/{TICKET-ID}-{description}
# Examples: feat/PROJ-123-user-auth, fix/TEAM-456-login-bug

# Plugin/module work
{prefix}/{plugin-name}/{description}
# Examples: feat/docflow/templates, fix/docflow/auth-error

# New plugin creation
feat/{plugin-name}
# Examples: feat/code-reviewer, feat/symfony-developer
```

### Rules

- Use kebab-case (lowercase with hyphens)
- No uppercase letters
- No underscores
- Descriptive but concise names
- Ticket ID is optional (unless configured as required)

## Commit Messages

### Format

```
type(scope): description

[optional body]

[optional footer]
```

### Types

| Type | Purpose |
|------|---------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation |
| `test` | Tests |
| `chore` | Maintenance |
| `refactor` | Code restructuring |
| `style` | Formatting (no code change) |
| `perf` | Performance improvement |
| `ci` | CI/CD changes |
| `build` | Build system changes |
| `revert` | Reverting commits |

### Examples

```bash
# Good
git commit -m "feat(auth): add OAuth2 support"
git commit -m "fix: resolve null pointer in user service"
git commit -m "docs: update API documentation"

# With Jira ticket (reference goes in footer, not scope)
git commit -m "feat(auth): add user authentication" -m "Refs: PROJ-123"
git commit -m "fix: resolve login timeout" -m "Refs: TEAM-456"

# Bad
git commit -m "Added new feature"             # Missing type
git commit -m "feat: Add feature"             # Uppercase description
git commit -m "feat: added feature."          # Past tense, period
git commit -m "feat(PROJ-123): add login"     # Ticket as scope, not footer
git commit -m "fix: resolve timeout [TEAM-456]"  # Inline bracket notation
```

## Hooks

The plugin provides PreToolUse hooks that validate:

1. **Branch creation** - Triggers on `git checkout -b`, `git branch`, `git switch -c`
2. **Commits** - Triggers on `git commit`

Invalid operations are blocked with explanations and suggestions.

## Skills

### conventional-commits

Trigger phrases: "commit message", "conventional commits", "commitlint"

Provides detailed reference for:
- Commit message format
- Type selection
- Scope usage
- Body and footer conventions
- Breaking changes

### branch-naming

Trigger phrases: "branch name", "create branch", "naming convention"

Provides detailed reference for:
- Branch prefixes
- Naming patterns
- Common mistakes
- Integration with commits

## Configuration

The plugin works out of the box with sensible defaults. For project-specific customization, create a local config file.

### Local Config File

Create `.claude/git-conventions.local.md` in your project:

```yaml
---
# Custom prefixes (add 'wip' for work-in-progress)
prefixes:
  - feat
  - fix
  - hotfix
  - docs
  - test
  - chore
  - refactor
  - wip

# Jira integration
jira_projects:
  - PROJ
  - TEAM

# Require ticket ID in branches and commits
ticket_required: false

# Ticket position: prefix or suffix
# prefix: feat/PROJ-123-add-login
# suffix: feat/add-login-PROJ-123
ticket_position: prefix
---

Additional project-specific notes...
```

See `examples/git-conventions.local.example.md` for a full template.

### Override Behavior

Project-level hooks take priority over plugin hooks. To completely replace the plugin's validation:

1. Add your own hooks in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "prompt",
        "prompt": "${CLAUDE_PROJECT_ROOT}/.claude/hooks/my-commit-rules.md",
        "if": "Bash(git commit *)"
      }]
    }]
  }
}
```

2. Your project hooks will be evaluated alongside (or instead of) plugin hooks.

### Integration with Existing Tools

If your project uses commitlint, husky, or other git hooks:
- This plugin validates within Claude Code sessions
- Traditional git hooks validate manual commits
- Both can coexist without conflict

## License

MIT
