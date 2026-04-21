---
description: Create Confluence documentation page from code, context, or requirements
argument-hint: [template-type] [subject]
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
  - mcp__atlassian__confluence_search
  - mcp__atlassian__confluence_get_page
  - mcp__atlassian__confluence_create_page
  - mcp__atlassian__confluence_update_page
  - mcp__atlassian__jira_get_issue
  - mcp__atlassian__jira_search
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
---

Create or update Confluence documentation based on the specified template and subject.

## Settings Check

First, check for `.claude/docflow.local.md` configuration:
- `confluence_space_key`: Target space for documentation
- `confluence_parent_page_id`: Optional parent page for hierarchy
- Default labels and components

If settings not found, ask user for:
- Confluence space key (e.g., "DEV", "DOCS", "TEAM")
- Parent page title (optional, for hierarchy)

## Template Selection

Argument $1 determines template type:
- `adr` - Architecture Decision Record
- `spec` - Technical Specification
- `api` - API Reference Documentation
- `runbook` - Operational Runbook
- `general` or omitted - Let me determine based on content

Argument $2 and beyond ($ARGUMENTS after first word) is the subject to document.

## Template Processing

### For ADR (Architecture Decision Record)
1. Understand the decision context
2. Analyze the problem and alternatives
3. Document decision and consequences
4. Structure using ADR template (Status, Context, Decision, Alternatives, Consequences)

### For Technical Specification
1. Gather requirements from context
2. Analyze technical approach
3. Document design, implementation, testing
4. Structure using Technical Spec template

### For API Reference
1. Analyze API code/specification
2. Document endpoints, authentication, errors
3. Include code examples
4. Structure using API Reference template

### For Runbook
1. Understand the operational procedure
2. Document step-by-step instructions
3. Include troubleshooting and rollback
4. Structure using Runbook template

## Code Context

When documenting code:
1. Analyze relevant source files
2. Use Context7 for framework/library documentation
3. Include accurate code examples
4. Link to related Jira issues if mentioned

## Confluence Integration

Create page using `confluence_create_page` with:
- Proper XHTML storage format
- Appropriate macros (toc, code, panels, etc.)
- Jira issue links where applicable
- Links to related Confluence pages

## Output

1. Show preview of documentation structure
2. Create/update the Confluence page
3. Provide link to created page
4. List any related documents that may need updates

## Examples

```
/docflow:confluence adr Redis caching decision
/docflow:confluence spec User authentication feature
/docflow:confluence api Payment endpoints
/docflow:confluence runbook Database backup procedure
/docflow:confluence The new notification system we built
```
