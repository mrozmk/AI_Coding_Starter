# Divante Claude Marketplace

Official plugin marketplace for Claude Code maintained by the Divante AI Team.

## Installation

Add this marketplace to your Claude Code installation:

```bash
/plugin marketplace add https://gitlab.divante.pl/ai/divante-claude-marketplace.git
```

## Available Plugins

### docflow

**Documentation workflow automation with Jira and Confluence Data Center integration.**

| | |
|---|---|
| **Version** | 1.0.0 |
| **Category** | Documentation |
| **Keywords** | `documentation` `confluence` `jira` `atlassian` `readme` `adr` `technical-writing` |

#### Features

- **README Generation** - Analyze codebase and generate comprehensive README documentation
- **Confluence Integration** - Create ADRs, technical specs, API references, and runbooks
- **Jira Task Breakdown** - Decompose user stories into well-structured sub-tasks
- **Proactive Suggestions** - Prompts documentation updates before commits

#### Commands

| Command | Description |
|---------|-------------|
| `/docflow:readme` | Generate or update README documentation |
| `/docflow:confluence` | Create Confluence page (ADR, spec, API ref, runbook) |
| `/docflow:jira-tasks` | Break down user story into Jira sub-tasks |

#### Requirements

- Jira Data Center v8.14+
- Confluence Data Center v6.0+
- Personal access tokens for both services

[View full documentation →](./plugins/docflow/README.md)

---
### claude-symfony-plugin

Symfony 7/8 developer agent with comprehensive knowledge of modern Symfony development.

**Features:**
- Autonomous Symfony 7/8 development agent
- Symfony 8 ready - PHP 8 attributes only (no XML)
- API Platform, Messenger, Security, Events expertise
- SOLID principles enforcement
- TDD with PHPUnit (unit + integration tests)
- Pre-commit hook that validates tests pass
- Context7 integration for live documentation

**Install:**
```bash
/plugin install claude-symfony-plugin
```

**Keywords:** symfony, symfony7, symfony8, php, api-platform, messenger, doctrine, phpunit, tdd

---

### git-conventions

**Git workflow conventions enforcement with branch naming and commit message validation.**

| | |
|---|---|
| **Version** | 1.0.0 |
| **Category** | Workflow |
| **Keywords** | `git` `branch-naming` `conventional-commits` `commitlint` `validation` |

#### Features

- **Branch Name Validation** - Enforces prefixes (`feat/`, `fix/`, `docs/`, etc.) and kebab-case
- **Commit Message Linting** - Validates against conventional commits format
- **Jira Integration** - Optional ticket IDs in branches and commits
- **Project Overrides** - Customize rules via `.claude/git-conventions.local.md`
- **Zero Dependencies** - Pure prompt-based validation, no external tools

#### Supported Patterns

```bash
# Branches
feat/user-auth
feat/PROJ-123-user-auth
feat/docflow/new-feature

# Commits
feat(auth): add login endpoint
fix: resolve login timeout

# With Jira ticket (in footer)
fix: resolve login timeout
# Refs: TEAM-456
```

#### Configuration

Create `.claude/git-conventions.local.md` to customize:

```yaml
---
jira_projects: [PROJ, TEAM]
ticket_required: false
prefixes: [feat, fix, hotfix, docs, test, chore, refactor, wip]
---
```

[View full documentation →](./plugins/git-conventions/README.md)

---

## Creating a New Plugin

Use the **plugin-dev** plugin to create plugins following best practices.

For official documentation, see:
- [Plugin Reference](https://code.claude.com/docs/en/plugins-reference) - Complete plugin structure and API
- [Plugin Marketplaces](https://code.claude.com/docs/en/plugin-marketplaces) - Marketplace configuration

### Prerequisites

1. Install the plugin-dev plugin:
   ```bash
   /plugin install plugin-dev
   ```

2. Clone this marketplace repository:
   ```bash
   git clone git@gitlab.divante.pl:ai/divante-claude-marketplace.git
   cd divante-claude-marketplace
   ```

3. Create a feature branch (see [Branch Naming Convention](#branch-naming-convention)):
   ```bash
   git checkout -b feat/your-plugin-name
   ```

### Creating Your Plugin

Use the `/plugin-dev:create-plugin` skill to guide you through the creation process:

```
Create a plugin for [describe your plugin purpose] in plugins/your-plugin-name
```

The plugin-dev plugin will guide you through:
1. **Discovery** - Understanding requirements
2. **Component Planning** - Determining needed components (agents, skills, commands, hooks, MCP)
3. **Detailed Design** - Specifying each component
4. **Structure Creation** - Setting up directories and manifest
5. **Implementation** - Building components with best practices
6. **Validation** - Quality checks
7. **Testing** - Verifying functionality
8. **Documentation** - Finalizing README and docs

### Plugin Development Rules

Follow these rules when creating plugins for this marketplace:

#### Structure Rules

- Place plugins in `plugins/your-plugin-name/`
- Use **kebab-case** for all directory and file names
- Plugin manifest must be at `.claude-plugin/plugin.json`
- Components go at plugin root: `agents/`, `skills/`, `commands/`, `hooks/`

#### Naming Conventions

- Plugin name: `kebab-case`, descriptive (e.g., `symfony-developer`, `code-reviewer`)
- Agent names: lowercase, hyphens, 3-50 chars (e.g., `symfony-developer`)
- Skill directories: kebab-case (e.g., `symfony-development/`)
- Command files: kebab-case `.md` files (e.g., `run-tests.md`)

#### Agent Rules

- Include **2-4 concrete examples** in the description with `<example>` blocks
- Use **third-person** in descriptions ("Use this agent when...")
- Set `model: inherit` unless specific model needed
- Choose distinct colors for different agents
- Limit tools to minimum needed (principle of least privilege)

#### Skill Rules

- Use **third-person** in description with specific trigger phrases
- Keep SKILL.md **lean** (1,500-2,000 words)
- Move detailed content to `references/` directory
- Write in **imperative form** (not second person)
- Reference supporting files in SKILL.md

#### Hook Rules

- Use `${CLAUDE_PLUGIN_ROOT}` for portable paths
- Set appropriate timeouts (default: 60s for commands, 30s for prompts)
- Prefer **prompt-based hooks** for complex logic
- Always validate inputs in command hooks
- Quote all bash variables

#### Code Quality Rules

- All code examples must be **complete and runnable**
- Include **error handling**
- Add **type hints** and strict types
- Test all scripts before committing

#### Documentation Rules

- Include a comprehensive `README.md` in your plugin
- Document all prerequisites and requirements
- Provide usage examples
- List all components and their purposes

### Plugin Entry Format

Add plugin entries to `.claude-plugin/marketplace.json`:

```json
{
  "name": "plugin-name",
  "source": "./plugins/plugin-name",
  "description": "Brief description of the plugin",
  "version": "1.0.0",
  "author": {
    "name": "Author Name",
    "email": "author@divante.pl"
  },
  "keywords": ["keyword1", "keyword2"],
  "category": "category-name"
}
```

### Validation Checklist

Before submitting your plugin, verify:

- [ ] Plugin manifest has required fields (`name`, `version`, `description`)
- [ ] All agents have proper frontmatter and examples
- [ ] All skills have SKILL.md with trigger phrases
- [ ] Hook scripts are executable and use `${CLAUDE_PLUGIN_ROOT}`
- [ ] README.md documents all features and usage
- [ ] No hardcoded paths or credentials
- [ ] All referenced files exist
- [ ] Plugin tested with `claude --plugin-dir ./plugins/your-plugin-name`

### Testing Plugins Locally

Before committing your plugin, thoroughly test it locally to ensure everything works correctly.

#### Basic Plugin Loading

Start Claude Code with your plugin loaded:

```bash
claude --plugin-dir ./plugins/your-plugin-name
```

#### Verify Components Are Registered

Once Claude starts, verify your components are available:

1. **Check slash commands** - Type `/your-plugin:` and verify your commands appear in autocomplete
2. **Check MCP servers** - Run `/mcp` to verify any MCP servers are connected and tools are available
3. **Check agents** - Your agents should appear when relevant context triggers them

#### Test Each Component

| Component | How to Test |
|-----------|-------------|
| **Commands** | Run each command with sample inputs: `/your-plugin:command-name arg1 arg2` |
| **Agents** | Trigger agent scenarios described in your examples |
| **Skills** | Reference skill content in prompts to verify it's loaded |
| **Hooks** | Trigger the hook event (e.g., make a commit for `PreToolUse` Bash hooks) |
| **MCP Tools** | Use the MCP tools directly and verify API connections |

#### Test with Print Mode

For quick validation without interactive sessions:

```bash
# Test that commands are registered
claude --plugin-dir ./plugins/your-plugin-name --print "List available slash commands"

# Test a specific command
claude --plugin-dir ./plugins/your-plugin-name --print "/your-plugin:command-name test-input"

# Test MCP connectivity
claude --plugin-dir ./plugins/your-plugin-name --print "Check MCP server status"
```

#### Environment Variables

If your plugin requires environment variables (e.g., API tokens):

1. Set them in your shell before testing:
   ```bash
   export YOUR_API_TOKEN="your-token"
   claude --plugin-dir ./plugins/your-plugin-name
   ```

2. Or add to `~/.claude/settings.json`:
   ```json
   {
     "env": {
       "YOUR_API_TOKEN": "your-token"
     }
   }
   ```

#### Common Issues

| Issue | Solution |
|-------|----------|
| Commands not showing | Check command file has valid YAML frontmatter |
| MCP server not connecting | Verify `uvx`/`npx` is installed and the package exists |
| Agent not triggering | Review agent description and examples for trigger phrases |
| Hook not running | Ensure script is executable (`chmod +x`) and paths use `${CLAUDE_PLUGIN_ROOT}` |

## Team Configuration

To enable this marketplace for your team, add to `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "divante-claude-marketplace": {
      "source": {
        "source": "url",
        "url": "https://gitlab.divante.pl/ai/divante-claude-marketplace.git"
      }
    }
  }
}
```

## Troubleshooting

### GitLab Token Configuration

If you're having trouble accessing the marketplace, you may need to configure a GitLab Personal Access Token.

#### Where to Put the Token

**Option 1: Claude Code settings file**

Add your GitLab token to `~/.claude/settings.json`:

```json
{
  "gitTokens": {
    "gitlab.divante.pl": "glpat-xxxxxxxxxxxxxxxxxxxx"
  }
}
```

**Option 2: Environment variable**

Export the token in your `~/.bashrc` or `~/.zshrc`:

```bash
export GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"
```

Then reload your shell configuration:

```bash
source ~/.bashrc  # or source ~/.zshrc
```

#### Token Format

GitLab Personal Access Tokens **must** start with the `glpat-` prefix. A valid token looks like:

```
glpat-xxxxxxxxxxxxxxxxxxxx
```

Common mistakes:
- ❌ `xxxxxxxxxxxxxxxxxxxx` - Missing the `glpat-` prefix
- ❌ `glpat_xxxxxxxxxxxxxxxxxxxx` - Using underscore instead of hyphen
- ✅ `glpat-xxxxxxxxxxxxxxxxxxxx` - Correct format with hyphen

#### Creating a GitLab Token

1. Go to GitLab → User Settings → Access Tokens
2. Create a new token with at least `read_repository` scope
3. Copy the token (it starts with `glpat-`)
4. Add it to your settings file or export it as an environment variable

## Contributing

1. Fork or clone this repository
2. Create a branch following the [Branch Naming Convention](#branch-naming-convention) below
3. Follow the [Creating a New Plugin](#creating-a-new-plugin) guide above
4. Ensure your plugin passes the [Validation Checklist](#validation-checklist)
5. Add your plugin entry to `.claude-plugin/marketplace.json`
6. Commit with a descriptive message
7. Submit a merge request

### Branch Naming Convention

Use the following prefixes for branch names:

| Prefix | Purpose | Example |
|--------|---------|---------|
| `feat/` | New features or functionality | `feat/code-reviewer-plugin` |
| `fix/` | Bug fixes | `fix/mcp-connection-timeout` |
| `hotfix/` | Urgent production fixes | `hotfix/auth-token-expiry` |
| `docs/` | Documentation changes | `docs/branch-naming` |
| `test/` | Test additions or fixes | `test/docflow-integration` |
| `chore/` | Maintenance tasks (deps, CI, tooling) | `chore/update-dependencies` |
| `refactor/` | Code restructuring without feature changes | `refactor/hook-system` |

#### Working on Existing Plugins

When modifying an existing plugin, use a **nested structure** with the plugin name:

```
{prefix}/{plugin-name}/{description}
```

**Examples:**
- `feat/docflow/confluence-templates` - Adding templates feature to docflow
- `fix/docflow/jira-auth-error` - Fixing auth error in docflow plugin
- `docs/docflow/readme-examples` - Updating docflow documentation
- `refactor/plugin-dev/skill-loader` - Refactoring plugin-dev internals

#### Creating New Plugins

When creating a new plugin, use a flat structure:

```
feat/{new-plugin-name}
```

**Examples:**
- `feat/symfony-developer` - New Symfony developer plugin
- `feat/code-reviewer` - New code review plugin

#### Why This Structure?

The nested `{prefix}/{plugin}/{description}` pattern was chosen over alternatives like:

- ❌ `feat/docflow-new-feature` - Ambiguous: is "docflow" the plugin or part of "docflow-new-feature"?
- ❌ `feat/docflow--new-feature` - Double-dash is unusual and error-prone
- ✅ `feat/docflow/new-feature` - Clear hierarchy, easy to filter by plugin

This aligns with conventional commits (`feat`, `fix`, `docs`) and provides clear organization when multiple developers work on different plugins.

### Merge Request Guidelines

- Use a clear, descriptive title
- Include a summary of the plugin's purpose and features
- List all components (agents, skills, commands, hooks)
- Confirm you've tested the plugin locally
- Request review from the AI Team

## References

- [Claude Code Plugin Reference](https://code.claude.com/docs/en/plugins-reference) - Official plugin documentation
- [Plugin Marketplaces Guide](https://code.claude.com/docs/en/plugin-marketplaces) - How marketplaces work
- [plugin-dev Plugin](https://github.com/anthropics/claude-code-plugins) - Plugin development toolkit

## License

MIT
