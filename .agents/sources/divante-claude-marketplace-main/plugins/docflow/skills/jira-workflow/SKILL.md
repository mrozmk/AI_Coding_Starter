---
name: Jira Workflow
description: This skill should be used when the user asks to "create Jira tasks", "break down a user story", "create sub-tasks", "structure Jira issues", "write Jira descriptions", "link Jira to code", "use Epic Story Sub-task hierarchy", or needs guidance on Jira issue structure, task breakdown patterns, and agile workflow integration.
version: 1.0.0
---

# Jira Workflow for Task Management

## Overview

This skill provides guidance on breaking down user stories into well-structured Jira tasks following the Epic → Story → Sub-task hierarchy. It covers task breakdown patterns, description writing, and integration with code repositories.

## Issue Hierarchy

Jira uses a three-level hierarchy for organizing work:

```
Epic (Large initiative, spans multiple sprints)
├── Story (User-facing feature, deliverable in one sprint)
│   ├── Sub-task (Technical work unit, 1-2 days max)
│   ├── Sub-task
│   └── Sub-task
├── Story
│   └── Sub-tasks...
└── Story
```

**When to use each:**
- **Epic**: Major features, initiatives, or themes (e.g., "User Authentication System")
- **Story**: User-facing functionality in user story format (e.g., "As a user, I want to login with SSO")
- **Sub-task**: Technical implementation units (e.g., "Implement OAuth2 callback handler")

## Breaking Down User Stories

### Step 1: Analyze the Story

Identify all technical work required:
1. Backend changes (API, database, services)
2. Frontend changes (UI, state management)
3. Integration work (external services, APIs)
4. Testing requirements (unit, integration, e2e)
5. Documentation needs
6. Deployment/configuration changes

### Step 2: Create Sub-tasks

Each sub-task should be:
- **Independent**: Can be assigned and completed separately
- **Small**: 1-2 days maximum effort
- **Clear**: Specific acceptance criteria
- **Testable**: Verifiable completion

### Standard Sub-task Types

| Type | Prefix | Example |
|------|--------|---------|
| Backend | `[BE]` | `[BE] Create user repository` |
| Frontend | `[FE]` | `[FE] Build login form component` |
| API | `[API]` | `[API] Implement /auth/login endpoint` |
| Database | `[DB]` | `[DB] Add users table migration` |
| Testing | `[TEST]` | `[TEST] Write unit tests for auth service` |
| Docs | `[DOCS]` | `[DOCS] Update API documentation` |
| Config | `[CONFIG]` | `[CONFIG] Add OAuth environment variables` |
| Review | `[REVIEW]` | `[REVIEW] Code review and approval` |

## Creating Issues via MCP

Use the `mcp__atlassian__jira_create_issue` tool:

```json
{
  "project_key": "PROJ",
  "issue_type": "Sub-task",
  "summary": "[BE] Implement user authentication service",
  "description": "Description in Jira markup format",
  "parent_key": "PROJ-123",
  "labels": ["backend", "authentication"],
  "components": ["api"]
}
```

**Required settings from docflow.local.md:**
- `jira_project_key` - Default project for new issues
- `jira_default_labels` - Labels to apply automatically
- `jira_default_components` - Components to assign

## Writing Issue Descriptions

### Story Description Format

```
h3. User Story
As a [user type], I want [goal] so that [benefit].

h3. Acceptance Criteria
* [ ] [Criterion 1]
* [ ] [Criterion 2]
* [ ] [Criterion 3]

h3. Technical Notes
[Implementation considerations, constraints, dependencies]

h3. Out of Scope
* [What this story does NOT include]

h3. Links
* Design: [link]
* API Spec: [link]
* Confluence: [link]
```

### Sub-task Description Format

```
h3. Objective
[Clear statement of what this task accomplishes]

h3. Acceptance Criteria
* [ ] [Specific, testable criterion]
* [ ] [Another criterion]

h3. Technical Approach
[Brief description of implementation approach]

h3. Files to Modify
* {{src/services/auth.ts}}
* {{src/repositories/user.ts}}

h3. Dependencies
* Blocked by: PROJ-124
* Related: PROJ-125
```

## Jira Markup Quick Reference

| Element | Markup | Result |
|---------|--------|--------|
| Heading | `h1.`, `h2.`, `h3.` | Heading levels |
| Bold | `*text*` | **text** |
| Italic | `_text_` | *text* |
| Code | `{{code}}` | `code` |
| Link | `[text\|url]` | link |
| Bullet list | `* item` | • item |
| Numbered | `# item` | 1. item |
| Checkbox | `* [ ] item` | ☐ item |
| Code block | `{code:java}...{code}` | formatted code |
| Panel | `{panel}...{panel}` | highlighted section |
| Quote | `{quote}...{quote}` | quoted text |

## Task Breakdown Examples

### Example: Login Feature

**Story**: "As a user, I want to log in with my email and password so I can access my account."

**Sub-tasks:**
1. `[DB] Create users table migration`
2. `[BE] Implement User entity and repository`
3. `[BE] Create authentication service with password hashing`
4. `[API] Implement POST /auth/login endpoint`
5. `[API] Implement JWT token generation`
6. `[FE] Build login form component`
7. `[FE] Implement auth state management`
8. `[FE] Add protected route handling`
9. `[TEST] Write unit tests for auth service`
10. `[TEST] Write integration tests for login flow`
11. `[DOCS] Update API documentation`

### Example: Data Export Feature

**Story**: "As a user, I want to export my data to CSV so I can analyze it offline."

**Sub-tasks:**
1. `[BE] Create export service with CSV generation`
2. `[API] Implement GET /export/csv endpoint`
3. `[API] Add async job processing for large exports`
4. `[FE] Add export button to dashboard`
5. `[FE] Show download progress indicator`
6. `[TEST] Write tests for CSV generation`
7. `[DOCS] Document export feature in user guide`

## Linking Issues

### Link Types

| Type | Usage |
|------|-------|
| `blocks` | This issue blocks another |
| `is blocked by` | This issue is blocked by another |
| `relates to` | General relationship |
| `duplicates` | This is a duplicate of another |
| `is cloned by` | This was cloned from another |

### Linking to Code

Include repository references in descriptions:
```
h3. Code References
* Repository: [project-name|https://github.com/org/repo]
* Branch: {{feature/PROJ-123-login}}
* PR: [#456|https://github.com/org/repo/pull/456]
```

## Best Practices

**Story Level:**
- Write from user perspective ("As a...")
- Include clear acceptance criteria
- Define what's out of scope
- Link to designs and specifications

**Sub-task Level:**
- Use type prefixes consistently
- Keep tasks small (1-2 days)
- Include files to be modified
- Note dependencies and blockers

**Workflow:**
- Create all sub-tasks before starting work
- Update status as work progresses
- Link PRs to sub-tasks for traceability
- Add time estimates for sprint planning

## Additional Resources

### Reference Files

For detailed patterns, consult:

- **`references/task-breakdown-patterns.md`** - Common decomposition patterns
- **`references/description-templates.md`** - Full description templates

### Example Files

Working examples in `examples/`:

- **`examples/feature-breakdown.md`** - Complete feature breakdown example
