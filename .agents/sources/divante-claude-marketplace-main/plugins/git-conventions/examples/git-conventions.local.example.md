---
# Git Conventions Local Configuration
# Copy to: .claude/git-conventions.local.md

# Branch prefixes (defaults: feat, fix, hotfix, docs, test, chore, refactor)
prefixes:
  - feat
  - fix
  - hotfix
  - docs
  - test
  - chore
  - refactor
  - wip        # add work-in-progress branches

# Commit types (defaults: feat, fix, docs, test, chore, refactor, style, perf, ci, build, revert)
commit_types:
  - feat
  - fix
  - docs
  - test
  - chore
  - refactor
  - style
  - perf
  - ci
  - build
  - revert

# Jira integration
jira_projects:
  - PROJ
  - TEAM

# Require ticket ID in branches and commits
ticket_required: false

# Ticket position in branch names: prefix or suffix
# prefix: feat/PROJ-123-add-login
# suffix: feat/add-login-PROJ-123
ticket_position: prefix
---

# Project-Specific Rules

Add any additional context or rules for this project below.

## Examples

Valid branches for this project:
- `feat/PROJ-123-user-authentication`
- `fix/TEAM-456-resolve-timeout`

Valid commits:
- `feat(auth): add user authentication` with footer `Refs: PROJ-123`
- `fix: resolve timeout issue` with footer `Refs: TEAM-456`
