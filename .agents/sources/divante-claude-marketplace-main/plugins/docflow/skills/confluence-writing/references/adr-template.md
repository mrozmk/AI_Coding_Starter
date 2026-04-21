# ADR (Architecture Decision Record) Template

## Confluence Storage Format

```xml
<ac:structured-macro ac:name="toc">
  <ac:parameter ac:name="printable">true</ac:parameter>
  <ac:parameter ac:name="maxLevel">2</ac:parameter>
</ac:structured-macro>

<ac:structured-macro ac:name="panel">
  <ac:parameter ac:name="bgColor">#deebff</ac:parameter>
  <ac:parameter ac:name="titleBGColor">#0052cc</ac:parameter>
  <ac:parameter ac:name="title">ADR Status</ac:parameter>
  <ac:rich-text-body>
    <p><strong>Status:</strong> [Proposed | Accepted | Deprecated | Superseded]</p>
    <p><strong>Date:</strong> YYYY-MM-DD</p>
    <p><strong>Authors:</strong> [Names]</p>
    <p><strong>Stakeholders:</strong> [Names/Teams]</p>
    <p><strong>Related Jira:</strong> <ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">PROJ-XXX</ac:parameter></ac:structured-macro></p>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Context</h2>

<p>Describe the technical or business context that requires a decision. Include:</p>
<ul>
  <li>Current situation and constraints</li>
  <li>Forces at play (technical, organizational, business)</li>
  <li>Why this decision is needed now</li>
</ul>

<h2>Decision</h2>

<p>State the decision clearly and concisely. Include:</p>
<ul>
  <li>What will be done</li>
  <li>The chosen approach or technology</li>
  <li>Key implementation details</li>
</ul>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">text</ac:parameter>
  <ac:parameter ac:name="title">Decision Summary</ac:parameter>
  <ac:plain-text-body><![CDATA[
We will [decision statement].

Key aspects:
- [Aspect 1]
- [Aspect 2]
- [Aspect 3]
]]></ac:plain-text-body>
</ac:structured-macro>

<h2>Alternatives Considered</h2>

<table>
  <tbody>
    <tr>
      <th>Alternative</th>
      <th>Pros</th>
      <th>Cons</th>
      <th>Why Not Chosen</th>
    </tr>
    <tr>
      <td>[Alternative 1]</td>
      <td><ul><li>Pro 1</li><li>Pro 2</li></ul></td>
      <td><ul><li>Con 1</li><li>Con 2</li></ul></td>
      <td>[Reason]</td>
    </tr>
    <tr>
      <td>[Alternative 2]</td>
      <td><ul><li>Pro 1</li><li>Pro 2</li></ul></td>
      <td><ul><li>Con 1</li><li>Con 2</li></ul></td>
      <td>[Reason]</td>
    </tr>
  </tbody>
</table>

<h2>Consequences</h2>

<h3>Positive</h3>
<ul>
  <li>[Positive consequence 1]</li>
  <li>[Positive consequence 2]</li>
  <li>[Positive consequence 3]</li>
</ul>

<h3>Negative</h3>
<ul>
  <li>[Negative consequence 1]</li>
  <li>[Negative consequence 2]</li>
</ul>

<h3>Neutral</h3>
<ul>
  <li>[Neutral consequence 1]</li>
</ul>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p><strong>Risks to Monitor:</strong></p>
    <ul>
      <li>[Risk 1 and mitigation]</li>
      <li>[Risk 2 and mitigation]</li>
    </ul>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Implementation</h2>

<p>High-level implementation approach:</p>
<ol>
  <li>[Step 1]</li>
  <li>[Step 2]</li>
  <li>[Step 3]</li>
</ol>

<h2>Related Documents</h2>

<ul>
  <li><ac:link><ri:page ri:content-title="Related Page 1" ri:space-key="DEV"/></ac:link></li>
  <li><ac:link><ri:page ri:content-title="Related Page 2" ri:space-key="DEV"/></ac:link></li>
</ul>
```

## Status Values

- **Proposed** - Decision is being discussed, not yet accepted
- **Accepted** - Decision has been approved and should be followed
- **Deprecated** - Decision is no longer relevant but kept for history
- **Superseded** - Decision has been replaced by a newer ADR (link to new one)

## Writing Guidelines

**Context Section:**
- Explain the problem without jumping to solutions
- Include relevant constraints (time, budget, technology)
- Reference any previous decisions that led here

**Decision Section:**
- Be direct and specific
- State what will be done, not what might be done
- Include enough detail for implementation

**Consequences Section:**
- Be honest about trade-offs
- List both positive and negative impacts
- Consider operational, maintenance, and team impacts
