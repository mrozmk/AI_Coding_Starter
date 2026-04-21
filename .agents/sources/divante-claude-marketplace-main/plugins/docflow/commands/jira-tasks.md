---
description: Break down a user story into Jira sub-tasks following Epic > Story > Sub-task hierarchy
argument-hint: [story-key-or-description]
allowed-tools:
  - Read
  - Glob
  - Grep
  - mcp__atlassian__jira_get_issue
  - mcp__atlassian__jira_search
  - mcp__atlassian__jira_create_issue
  - mcp__atlassian__jira_update_issue
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
---

Break down a user story into well-structured Jira sub-tasks.

## Settings Check

First, check for `.claude/docflow.local.md` configuration:
- `jira_project_key`: Default project for creating tasks
- `jira_default_labels`: Labels to apply to all tasks
- `jira_default_components`: Components to assign

If settings not found, ask user for:
- Jira project key (e.g., "PROJ", "DEV")

## Input Processing

If $ARGUMENTS starts with a Jira key (e.g., "PROJ-123"):
1. Fetch the story using `jira_get_issue`
2. Analyze story description and acceptance criteria
3. Check for existing sub-tasks

If $ARGUMENTS is a description:
1. Parse as user story format: "As a [user], I want [goal], so that [benefit]"
2. Ask user which parent story to attach sub-tasks to, OR
3. Create as standalone tasks linked to each other

## Task Breakdown Process

### Step 1: Analyze Story
Identify all work required:
- Backend changes (API, database, services)
- Frontend changes (UI, state, routing)
- Integration work (external services)
- Testing requirements
- Documentation needs
- Configuration/deployment

### Step 2: Apply Type Prefixes
Use consistent prefixes:
- `[BE]` - Backend/service work
- `[FE]` - Frontend/UI work
- `[API]` - API endpoint work
- `[DB]` - Database/migration work
- `[TEST]` - Testing work
- `[DOCS]` - Documentation
- `[CONFIG]` - Configuration/deployment

### Step 3: Size Tasks Appropriately
Each sub-task should be:
- Independently completable
- 1-2 days maximum effort
- Clearly scoped with acceptance criteria

### Step 4: Identify Dependencies
Note which tasks:
- Block other tasks
- Can be done in parallel
- Require specific sequence

## Sub-task Structure

Each sub-task includes:

**Summary:** `[TYPE] Brief description`

**Description (Jira markup):**
```
h3. Objective
[Clear statement of what this task accomplishes]

h3. Acceptance Criteria
* [ ] [Specific criterion 1]
* [ ] [Specific criterion 2]

h3. Technical Approach
[Implementation guidance]

h3. Files to Modify
* {{file/path.ts}}

h3. Dependencies
* Blocked by: [PROJ-XXX] if any
* Related: [PROJ-YYY]
```

## Jira Integration

Create sub-tasks using `jira_create_issue` with:
- issue_type: "Sub-task"
- parent_key: Parent story key
- Appropriate labels and components
- Clear descriptions in Jira markup

## Output

1. Show proposed task breakdown as table:
   | # | Type | Summary | Est. Points | Dependencies |
2. Confirm with user before creating
3. Create all sub-tasks in Jira
4. Provide summary with links to created tasks
5. Show dependency diagram if complex

## Examples

```
/docflow:jira-tasks PROJ-123
/docflow:jira-tasks As a user, I want to export my data to CSV so I can analyze it offline
/docflow:jira-tasks Add user authentication with OAuth2
```
