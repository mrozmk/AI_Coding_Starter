---
name: Confluence Writing
description: This skill should be used when the user asks to "write Confluence documentation", "create a Confluence page", "format for Confluence", "use Confluence storage format", "write an ADR", "create a technical spec", "document an API", "create a runbook", or needs guidance on Confluence XHTML markup, macros, and documentation templates.
version: 1.0.0
---

# Confluence Writing for Data Center

## Overview

Confluence Data Center uses XHTML-based storage format for page content. This skill provides guidance on writing properly formatted Confluence pages, using macros, and applying documentation templates (ADR, Technical Spec, API Reference, Runbook).

## Storage Format Basics

Confluence stores content in XHTML format with Atlassian-specific XML namespaces:

```xml
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">python</ac:parameter>
  <ac:plain-text-body><![CDATA[print("Hello World")]]></ac:plain-text-body>
</ac:structured-macro>
```

**Key namespaces:**
- `ac:` - Atlassian Confluence elements (macros, parameters)
- `ri:` - Resource identifiers (pages, attachments, users)

## Essential Macros

### Code Block

```xml
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">javascript</ac:parameter>
  <ac:parameter ac:name="title">Example Code</ac:parameter>
  <ac:parameter ac:name="collapse">false</ac:parameter>
  <ac:plain-text-body><![CDATA[
const greeting = "Hello";
console.log(greeting);
]]></ac:plain-text-body>
</ac:structured-macro>
```

Supported languages: `javascript`, `python`, `java`, `bash`, `sql`, `xml`, `json`, `php`, `ruby`, `go`, `typescript`, `csharp`, `kotlin`, `swift`, `rust`.

### Info/Warning/Note Panels

```xml
<ac:structured-macro ac:name="info">
  <ac:rich-text-body>
    <p>Informational message here.</p>
  </ac:rich-text-body>
</ac:structured-macro>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p>Warning message here.</p>
  </ac:rich-text-body>
</ac:structured-macro>

<ac:structured-macro ac:name="note">
  <ac:rich-text-body>
    <p>Note content here.</p>
  </ac:rich-text-body>
</ac:structured-macro>
```

### Table of Contents

```xml
<ac:structured-macro ac:name="toc">
  <ac:parameter ac:name="printable">true</ac:parameter>
  <ac:parameter ac:name="maxLevel">3</ac:parameter>
</ac:structured-macro>
```

### Expand (Collapsible Section)

```xml
<ac:structured-macro ac:name="expand">
  <ac:parameter ac:name="title">Click to expand</ac:parameter>
  <ac:rich-text-body>
    <p>Hidden content here.</p>
  </ac:rich-text-body>
</ac:structured-macro>
```

### Page Links

```xml
<ac:link>
  <ri:page ri:content-title="Target Page Title" ri:space-key="SPACE"/>
</ac:link>
```

### Jira Issue Link

```xml
<ac:structured-macro ac:name="jira">
  <ac:parameter ac:name="key">PROJ-123</ac:parameter>
</ac:structured-macro>
```

## Basic XHTML Elements

Standard HTML elements wrapped in Confluence format:

```xml
<h1>Main Heading</h1>
<h2>Section Heading</h2>
<h3>Subsection Heading</h3>

<p>Paragraph text with <strong>bold</strong> and <em>italic</em>.</p>

<ul>
  <li>Unordered list item</li>
  <li>Another item</li>
</ul>

<ol>
  <li>Ordered list item</li>
  <li>Second item</li>
</ol>

<table>
  <tbody>
    <tr>
      <th>Header 1</th>
      <th>Header 2</th>
    </tr>
    <tr>
      <td>Cell 1</td>
      <td>Cell 2</td>
    </tr>
  </tbody>
</table>
```

## Documentation Templates

Four primary templates are available for different documentation needs:

### 1. ADR (Architecture Decision Record)

Use for documenting architectural decisions with context, decision, and consequences. Template in `references/adr-template.md`.

**Structure:**
- Title and metadata (status, date, authors)
- Context - What problem prompted this decision?
- Decision - What was decided and why?
- Consequences - What are the positive and negative impacts?

### 2. Technical Specification

Use for detailed technical designs before implementation. Template in `references/technical-spec-template.md`.

**Structure:**
- Overview and objectives
- Requirements (functional and non-functional)
- Design and architecture
- Implementation approach
- Testing strategy
- Deployment and rollout

### 3. API Reference

Use for documenting REST/GraphQL APIs. Template in `references/api-reference-template.md`.

**Structure:**
- Endpoint overview
- Authentication requirements
- Request/response formats
- Error codes and handling
- Code examples
- Rate limits

### 4. Runbook

Use for operational procedures and incident response. Template in `references/runbook-template.md`.

**Structure:**
- Purpose and scope
- Prerequisites
- Step-by-step procedures
- Troubleshooting guide
- Rollback procedures
- Escalation contacts

## Creating Pages via MCP

Use the `mcp__atlassian__confluence_create_page` tool:

```json
{
  "space_key": "DEV",
  "title": "Page Title",
  "body": "<XHTML content here>",
  "parent_id": "123456"
}
```

**Required settings from docflow.local.md:**
- `confluence_space_key` - Default space for new pages
- `confluence_parent_page_id` - Optional parent page ID

## Best Practices

**Structure:**
- Start with Table of Contents macro for documents > 3 sections
- Use h1 for page title (typically set in page metadata), h2 for main sections, h3 for subsections
- Include status panel at top for ADRs and specs (Proposed/Approved/Deprecated)

**Readability:**
- Keep paragraphs short (3-5 sentences)
- Use bullet lists for related items
- Include code examples in code blocks with proper language highlighting
- Add info/warning panels to highlight important information

**Linking:**
- Link to related Confluence pages using `<ac:link>`
- Include Jira issue links with the jira macro
- Reference code repositories with external links

**Maintenance:**
- Include "Last Updated" date
- Add author information
- Mark deprecated content clearly

## Additional Resources

### Reference Files

For complete templates, consult:

- **`references/adr-template.md`** - Complete ADR template in Confluence format
- **`references/technical-spec-template.md`** - Technical specification template
- **`references/api-reference-template.md`** - API documentation template
- **`references/runbook-template.md`** - Operational runbook template

### Example Files

Working examples in `examples/`:

- **`examples/sample-adr.xml`** - Sample ADR in Confluence storage format
- **`examples/sample-api-doc.xml`** - Sample API documentation page
