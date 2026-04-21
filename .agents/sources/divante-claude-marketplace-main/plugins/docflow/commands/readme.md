---
description: Generate or update README documentation for a repository or directory
argument-hint: [path-or-scope]
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - mcp__plugin_context7_context7__resolve-library-id
  - mcp__plugin_context7_context7__query-docs
---

Generate or update README documentation for the specified scope.

## Context Gathering

First, analyze the codebase to understand:
1. Project type and technology stack
2. Main entry points and structure
3. Dependencies from package.json, composer.json, requirements.txt, or similar
4. Existing README content (if any)
5. Configuration files and their purposes

## README Structure

Create comprehensive README with these sections:

### Required Sections
- **Title and Description**: Clear project name and one-paragraph summary
- **Installation**: Step-by-step setup instructions
- **Usage**: Basic usage examples with code snippets
- **Configuration**: Environment variables and config options

### Recommended Sections (include if applicable)
- **Requirements/Prerequisites**: System requirements, dependencies
- **API Reference**: If the project exposes an API
- **Architecture**: For complex projects, explain structure
- **Development**: How to set up dev environment, run tests
- **Deployment**: Production deployment instructions
- **Contributing**: Guidelines for contributors
- **License**: License information

## Formatting Guidelines

- Use clear heading hierarchy (h1 for title, h2 for main sections)
- Include code blocks with language identifiers
- Add a table of contents for documents > 5 sections
- Use bullet lists for related items
- Include badges where applicable (build status, version, license)
- Keep line lengths reasonable for git diff readability

## Library Documentation

When detecting framework/library dependencies, use Context7 to fetch current documentation for accurate usage examples and best practices.

## Output

1. Show proposed README structure
2. Create or update the README.md file
3. Summarize what was documented
4. Note any sections that need manual input (API keys, specific URLs, etc.)

## Scope Handling

If $ARGUMENTS is provided:
- Use it as the target directory path
- If "full" or "comprehensive", include all optional sections
- If a specific section name, update only that section

If no argument provided:
- Generate README for current working directory
- Include all applicable sections based on project analysis
