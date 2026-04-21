# docflow

Documentation workflow automation with Jira and Confluence Data Center integration.

## Overview

docflow is a Claude Code plugin that streamlines technical documentation across your development workflow. It integrates with Atlassian Jira and Confluence (Data Center) to:

- Write and maintain README files in markdown
- Create Confluence documentation pages using proper storage format
- Break down user stories into well-structured Jira sub-tasks
- Maintain connections between code, documentation, and project management
- Proactively suggest documentation updates before commits

## Features

### Agent: documentation-engineer

A proactive documentation specialist that triggers when you need to:
- Document new features or code changes
- Create Architecture Decision Records (ADRs)
- Write technical specifications
- Break down user stories into tasks
- Connect documentation to code and Jira issues

### Commands

| Command | Description |
|---------|-------------|
| `/docflow:readme` | Generate or update README documentation |
| `/docflow:confluence` | Create Confluence page (ADR, spec, API ref, runbook) |
| `/docflow:jira-tasks` | Break down user story into Jira sub-tasks |

### Skills

- **confluence-writing**: Best practices for Confluence storage format, macros, and documentation templates
- **jira-workflow**: Patterns for Epic → Story → Sub-task hierarchy and task breakdown

### Proactive Hook

When you're about to commit code, docflow suggests documentation updates to ensure your changes are properly documented.

## Prerequisites

### uv Package Manager

This plugin uses the [mcp-atlassian](https://github.com/sooperset/mcp-atlassian) MCP server which is installed via `uvx` (part of the [uv](https://github.com/astral-sh/uv) Python package manager).

**macOS (Homebrew):**

```bash
brew install uv
```

**Linux/macOS (curl):**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

After installation, verify `uvx` is available:

```bash
uvx --version
```

> **Note:** The first time the MCP server starts, `uvx` will automatically download and cache the `mcp-atlassian` package and its dependencies.

### Atlassian Data Center Access

This plugin requires:
- Jira Data Center v8.14+
- Confluence Data Center v6.0+
- Personal access tokens for both services

### Environment Variables

Configure the following environment variables using one of these methods:

**Option 1: Claude Code Settings (Recommended)**

Add to your `~/.claude/settings.json`:

```json
{
  "env": {
    "JIRA_URL": "https://jira.yourcompany.com",
    "JIRA_PERSONAL_TOKEN": "your-personal-access-token",
    "CONFLUENCE_URL": "https://confluence.yourcompany.com",
    "CONFLUENCE_PERSONAL_TOKEN": "your-personal-access-token"
  }
}
```

**Option 2: Shell Environment**

Add to your shell profile (`.bashrc`, `.zshrc`, etc.):

```bash
# Jira Data Center
export JIRA_URL="https://jira.yourcompany.com"
export JIRA_PERSONAL_TOKEN="your-personal-access-token"

# Confluence Data Center
export CONFLUENCE_URL="https://confluence.yourcompany.com"
export CONFLUENCE_PERSONAL_TOKEN="your-personal-access-token"
```

After configuring, restart Claude Code for the changes to take effect.

### Generating Personal Access Tokens

1. Log into your Jira/Confluence instance
2. Go to Profile → Personal Access Tokens
3. Create a new token with appropriate permissions
4. Copy the token (it's only shown once)

## Installation

### From Marketplace

```bash
/plugin install docflow
```

### Local Development

```bash
claude --plugin-dir /path/to/plugins/docflow
```

## Configuration

Create a settings file at `.claude/docflow.local.md` in your project:

```markdown
---
# Confluence Settings
confluence_space_key: DEV
confluence_parent_page_id: "123456789"

# Jira Settings
jira_project_key: PROJ
jira_default_labels:
  - documentation
  - automated
jira_default_components:
  - backend
  - frontend

# Documentation Preferences
preferred_adr_format: detailed
include_code_examples: true
---

# Project-Specific Documentation Notes

Additional context for documentation generation specific to this project.
```

### Settings Reference

| Setting | Type | Description |
|---------|------|-------------|
| `confluence_space_key` | string | Default Confluence space for new pages |
| `confluence_parent_page_id` | string | Optional parent page ID for hierarchy |
| `jira_project_key` | string | Default Jira project for new issues |
| `jira_default_labels` | array | Labels to apply to all created issues |
| `jira_default_components` | array | Components to assign to issues |

## Usage Examples

### Create README Documentation

```
/docflow:readme
```

Analyzes your codebase and generates comprehensive README with:
- Project overview
- Installation instructions
- Usage examples
- Configuration options
- API reference (if applicable)

### Create Confluence ADR

```
/docflow:confluence adr We decided to use Redis for session caching
```

Creates an Architecture Decision Record with:
- Context and problem statement
- Decision and rationale
- Alternatives considered
- Consequences (positive/negative)

### Create Technical Specification

```
/docflow:confluence spec User authentication with OAuth2
```

Creates a technical specification with:
- Overview and objectives
- Requirements
- Design and architecture
- Implementation plan
- Testing strategy

### Break Down User Story

```
/docflow:jira-tasks PROJ-123
```

Or with a description:

```
/docflow:jira-tasks As a user, I want to export my data to CSV so I can analyze it offline
```

Creates structured sub-tasks:
- `[BE]` Backend tasks
- `[FE]` Frontend tasks
- `[API]` API tasks
- `[TEST]` Testing tasks
- `[DOCS]` Documentation tasks

### Use the Agent Directly

Just describe what you need:

```
"I just finished implementing the payment integration. Can you help document it?"
```

The documentation-engineer agent will:
1. Analyze your code changes
2. Suggest documentation updates
3. Create/update README sections
4. Offer to create Confluence pages
5. Link to related Jira issues

## Documentation Templates

### Confluence Templates

1. **ADR (Architecture Decision Record)**
   - Status, context, decision, consequences
   - Alternative analysis table
   - Implementation notes

2. **Technical Specification**
   - Overview, requirements, design
   - Implementation phases
   - Testing and deployment

3. **API Reference**
   - Endpoints, authentication
   - Request/response formats
   - Error codes, examples

4. **Runbook**
   - Prerequisites, procedures
   - Troubleshooting
   - Rollback and escalation

## MCP Integration

docflow uses the [mcp-atlassian](https://github.com/sooperset/mcp-atlassian) MCP server for Jira and Confluence integration.

### Available MCP Tools

**Jira:**
- `jira_search` - Search issues with JQL
- `jira_get_issue` - Get issue details
- `jira_create_issue` - Create new issues
- `jira_update_issue` - Update existing issues

**Confluence:**
- `confluence_search` - Search pages with CQL
- `confluence_get_page` - Get page content
- `confluence_create_page` - Create new pages
- `confluence_update_page` - Update existing pages

## Troubleshooting

### uvx Not Found

If you see errors about `uvx` not being found:

1. Install uv (see Prerequisites section above)

2. Verify installation:
   ```bash
   which uvx
   uvx --version
   ```

3. If installed but not found, ensure it's in your PATH:
   ```bash
   # macOS/Linux - add to ~/.zshrc or ~/.bashrc
   export PATH="$HOME/.local/bin:$PATH"

   # Or for Homebrew on macOS
   export PATH="/opt/homebrew/bin:$PATH"
   ```

4. Restart Claude Code after updating PATH

### MCP Connection Issues

1. Verify environment variables are set:
   ```bash
   echo $JIRA_URL
   echo $CONFLUENCE_URL
   ```

2. Test token validity by accessing the URLs in a browser

3. Check MCP server status:
   ```bash
   /mcp
   ```

### Hook Not Triggering

The proactive documentation hook only activates for commit-related prompts. Ensure your prompt contains keywords like "commit", "push", "finished implementing", etc.

### Missing Confluence Space

If you get "space not found" errors:
1. Verify space key in settings
2. Ensure your token has space access
3. Check space exists and is accessible

## Contributing

1. Fork the marketplace repository
2. Create a feature branch
3. Make your changes
4. Test with `claude --plugin-dir ./plugins/docflow`
5. Submit a merge request

## License

MIT

## Author

Divante AI Team
