# Claude Project Instructions

This is the Divante Claude Marketplace repository. Follow these conventions when working here.

## Branch Naming Convention

**Prefixes:**
- `feat/` - New features
- `fix/` - Bug fixes
- `hotfix/` - Urgent production fixes
- `docs/` - Documentation
- `test/` - Tests
- `chore/` - Maintenance (deps, CI)
- `refactor/` - Code restructuring

**Working on existing plugins** - use nested structure:
```
{prefix}/{plugin-name}/{description}
```
Examples: `feat/docflow/confluence-templates`, `fix/docflow/jira-auth-error`

**Creating new plugins** - use flat structure:
```
feat/{new-plugin-name}
```
Examples: `feat/symfony-developer`, `feat/code-reviewer`

## Commit Messages

Follow conventional commits format:
```
type(scope): description

[optional body]

[optional footer]
```

**Types:** `feat`, `fix`, `docs`, `test`, `chore`, `refactor`, `style`, `perf`, `ci`, `build`, `revert`

**Rules:**
- Description in imperative mood, lowercase, no period
- Scope is optional but recommended for plugin work
- Example: `feat(docflow): add confluence templates`

See `plugins/git-conventions/skills/conventional-commits/SKILL.md` for details.

## Plugin Development

- Place plugins in `plugins/{plugin-name}/`
- Use kebab-case for all names
- Manifest at `.claude-plugin/plugin.json`
- See README.md for full development rules

## Code Quality

- Complete, runnable code examples
- Include error handling
- Add type hints
- Test before committing
