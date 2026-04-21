# Claude Symfony Plugin

A Claude Code plugin providing an autonomous Symfony developer agent with comprehensive knowledge of modern Symfony 7/8 development practices.

## Features

- **Symfony 7/8 Development**: Full support for Symfony 7.x and 8.x with PHP 8.2+
- **Symfony 8 Ready**: Uses PHP 8 attributes only (no XML configuration)
- **API Platform**: RESTful and GraphQL API development
- **Messenger**: Async message handling and queues
- **Security**: Authentication, authorization, voters, firewalls
- **Events**: Event subscribers (preferred over listeners)
- **SOLID Principles**: Clean, maintainable code architecture
- **TDD with PHPUnit**: Unit and integration tests written alongside features
- **Context7 Integration**: Live documentation lookup for latest Symfony docs

## Installation

Install via the Divante marketplace:

```bash
/plugin marketplace add git@gitlab.divante.pl:ai/divante-claude-marketplace.git
/plugin install claude-symfony-plugin
```

## Usage

The agent triggers automatically when you work on Symfony-related tasks:

- "Create a new controller for user management"
- "Add a Product entity with Doctrine"
- "Implement JWT authentication"
- "Create a message handler for order processing"
- "Add API Platform resources for the Blog entity"

## Symfony 8 Patterns

This plugin follows Symfony 8 best practices:

- **PHP 8 Attributes only** - No XML or annotation configuration
- **`readonly` classes** - For services and DTOs
- **`declare(strict_types=1)`** - Always strict typing
- **Constructor property promotion** - Clean dependency injection

## Pre-commit Hook

The plugin includes a pre-commit hook that runs PHPUnit tests before allowing commits. If tests fail, the commit is blocked.

## Requirements

- PHP 8.2+
- Symfony 7.x or 8.x project
- PHPUnit installed
- Node.js (for Context7 MCP server)

## License

MIT
