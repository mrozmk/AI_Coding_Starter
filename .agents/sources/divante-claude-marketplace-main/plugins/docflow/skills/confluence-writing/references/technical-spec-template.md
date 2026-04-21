# Technical Specification Template

## Confluence Storage Format

```xml
<ac:structured-macro ac:name="toc">
  <ac:parameter ac:name="printable">true</ac:parameter>
  <ac:parameter ac:name="maxLevel">3</ac:parameter>
</ac:structured-macro>

<ac:structured-macro ac:name="panel">
  <ac:parameter ac:name="bgColor">#e3fcef</ac:parameter>
  <ac:parameter ac:name="titleBGColor">#006644</ac:parameter>
  <ac:parameter ac:name="title">Document Status</ac:parameter>
  <ac:rich-text-body>
    <p><strong>Status:</strong> [Draft | In Review | Approved | Implemented]</p>
    <p><strong>Version:</strong> 1.0</p>
    <p><strong>Last Updated:</strong> YYYY-MM-DD</p>
    <p><strong>Author:</strong> [Name]</p>
    <p><strong>Reviewers:</strong> [Names]</p>
    <p><strong>Epic:</strong> <ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">PROJ-XXX</ac:parameter></ac:structured-macro></p>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Overview</h2>

<h3>Purpose</h3>
<p>[Brief description of what this specification covers and why it exists]</p>

<h3>Objectives</h3>
<ul>
  <li>[Objective 1]</li>
  <li>[Objective 2]</li>
  <li>[Objective 3]</li>
</ul>

<h3>Scope</h3>
<p><strong>In Scope:</strong></p>
<ul>
  <li>[Item 1]</li>
  <li>[Item 2]</li>
</ul>
<p><strong>Out of Scope:</strong></p>
<ul>
  <li>[Item 1]</li>
  <li>[Item 2]</li>
</ul>

<h2>Requirements</h2>

<h3>Functional Requirements</h3>

<table>
  <tbody>
    <tr>
      <th>ID</th>
      <th>Requirement</th>
      <th>Priority</th>
      <th>Notes</th>
    </tr>
    <tr>
      <td>FR-001</td>
      <td>[Requirement description]</td>
      <td>Must Have</td>
      <td>[Additional notes]</td>
    </tr>
    <tr>
      <td>FR-002</td>
      <td>[Requirement description]</td>
      <td>Should Have</td>
      <td>[Additional notes]</td>
    </tr>
  </tbody>
</table>

<h3>Non-Functional Requirements</h3>

<table>
  <tbody>
    <tr>
      <th>Category</th>
      <th>Requirement</th>
      <th>Target</th>
    </tr>
    <tr>
      <td>Performance</td>
      <td>[Description]</td>
      <td>[Metric/SLA]</td>
    </tr>
    <tr>
      <td>Security</td>
      <td>[Description]</td>
      <td>[Standard]</td>
    </tr>
    <tr>
      <td>Scalability</td>
      <td>[Description]</td>
      <td>[Target]</td>
    </tr>
  </tbody>
</table>

<h2>Design</h2>

<h3>Architecture Overview</h3>

<p>[High-level architecture description]</p>

<ac:structured-macro ac:name="info">
  <ac:rich-text-body>
    <p><strong>Architecture Diagram:</strong> [Link to diagram or embed image]</p>
  </ac:rich-text-body>
</ac:structured-macro>

<h3>Components</h3>

<h4>[Component 1 Name]</h4>
<p><strong>Responsibility:</strong> [What this component does]</p>
<p><strong>Technology:</strong> [Stack/framework used]</p>
<p><strong>Interfaces:</strong></p>
<ul>
  <li>[Interface 1]</li>
  <li>[Interface 2]</li>
</ul>

<h4>[Component 2 Name]</h4>
<p><strong>Responsibility:</strong> [What this component does]</p>
<p><strong>Technology:</strong> [Stack/framework used]</p>

<h3>Data Model</h3>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">sql</ac:parameter>
  <ac:parameter ac:name="title">Database Schema</ac:parameter>
  <ac:plain-text-body><![CDATA[
CREATE TABLE example (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
]]></ac:plain-text-body>
</ac:structured-macro>

<h3>API Design</h3>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">json</ac:parameter>
  <ac:parameter ac:name="title">API Endpoint Example</ac:parameter>
  <ac:plain-text-body><![CDATA[
POST /api/v1/resource
{
  "name": "string",
  "type": "string"
}

Response 201:
{
  "id": "uuid",
  "name": "string",
  "created_at": "datetime"
}
]]></ac:plain-text-body>
</ac:structured-macro>

<h2>Implementation</h2>

<h3>Approach</h3>
<p>[Describe the implementation approach]</p>

<h3>Phases</h3>

<table>
  <tbody>
    <tr>
      <th>Phase</th>
      <th>Description</th>
      <th>Deliverables</th>
    </tr>
    <tr>
      <td>Phase 1</td>
      <td>[Description]</td>
      <td><ul><li>[Deliverable 1]</li><li>[Deliverable 2]</li></ul></td>
    </tr>
    <tr>
      <td>Phase 2</td>
      <td>[Description]</td>
      <td><ul><li>[Deliverable 1]</li></ul></td>
    </tr>
  </tbody>
</table>

<h3>Dependencies</h3>
<ul>
  <li>[External dependency 1]</li>
  <li>[External dependency 2]</li>
</ul>

<h2>Testing Strategy</h2>

<h3>Test Types</h3>

<table>
  <tbody>
    <tr>
      <th>Type</th>
      <th>Scope</th>
      <th>Tools</th>
    </tr>
    <tr>
      <td>Unit Tests</td>
      <td>[Coverage target]</td>
      <td>[Testing framework]</td>
    </tr>
    <tr>
      <td>Integration Tests</td>
      <td>[Scope]</td>
      <td>[Tools]</td>
    </tr>
    <tr>
      <td>E2E Tests</td>
      <td>[Critical paths]</td>
      <td>[Tools]</td>
    </tr>
  </tbody>
</table>

<h3>Acceptance Criteria</h3>
<ul>
  <li>[Criterion 1]</li>
  <li>[Criterion 2]</li>
  <li>[Criterion 3]</li>
</ul>

<h2>Deployment</h2>

<h3>Deployment Strategy</h3>
<p>[Blue-green, canary, rolling update, etc.]</p>

<h3>Rollout Plan</h3>
<ol>
  <li>[Step 1]</li>
  <li>[Step 2]</li>
  <li>[Step 3]</li>
</ol>

<h3>Rollback Plan</h3>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p><strong>Rollback Triggers:</strong></p>
    <ul>
      <li>[Trigger 1]</li>
      <li>[Trigger 2]</li>
    </ul>
    <p><strong>Rollback Steps:</strong></p>
    <ol>
      <li>[Step 1]</li>
      <li>[Step 2]</li>
    </ol>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Monitoring and Observability</h2>

<h3>Metrics</h3>
<ul>
  <li>[Metric 1] - [Purpose]</li>
  <li>[Metric 2] - [Purpose]</li>
</ul>

<h3>Alerts</h3>
<ul>
  <li>[Alert condition 1] - [Response action]</li>
  <li>[Alert condition 2] - [Response action]</li>
</ul>

<h2>Security Considerations</h2>
<ul>
  <li>[Security consideration 1]</li>
  <li>[Security consideration 2]</li>
</ul>

<h2>Open Questions</h2>

<table>
  <tbody>
    <tr>
      <th>Question</th>
      <th>Owner</th>
      <th>Status</th>
      <th>Answer</th>
    </tr>
    <tr>
      <td>[Question 1]</td>
      <td>[Name]</td>
      <td>[Open/Resolved]</td>
      <td>[Answer if resolved]</td>
    </tr>
  </tbody>
</table>

<h2>References</h2>
<ul>
  <li><ac:link><ri:page ri:content-title="Related ADR" ri:space-key="DEV"/></ac:link></li>
  <li>[External reference link]</li>
</ul>
```

## Status Values

- **Draft** - Initial creation, not ready for review
- **In Review** - Under review by stakeholders
- **Approved** - Approved for implementation
- **Implemented** - Development complete

## Writing Guidelines

**Keep it concise:** Technical specs should be detailed enough to implement but not overwhelming. Link to external resources where appropriate.

**Update regularly:** As implementation progresses, update the spec to reflect actual decisions made.

**Track changes:** Use the version field and last updated date to track document evolution.
