# Runbook Documentation Template

## Confluence Storage Format

```xml
<ac:structured-macro ac:name="toc">
  <ac:parameter ac:name="printable">true</ac:parameter>
  <ac:parameter ac:name="maxLevel">2</ac:parameter>
</ac:structured-macro>

<ac:structured-macro ac:name="panel">
  <ac:parameter ac:name="bgColor">#fffae6</ac:parameter>
  <ac:parameter ac:name="titleBGColor">#ff991f</ac:parameter>
  <ac:parameter ac:name="title">Runbook Information</ac:parameter>
  <ac:rich-text-body>
    <p><strong>Service:</strong> [Service Name]</p>
    <p><strong>Environment:</strong> [Production/Staging/etc.]</p>
    <p><strong>Last Updated:</strong> YYYY-MM-DD</p>
    <p><strong>Owner:</strong> [Team/Person]</p>
    <p><strong>On-Call:</strong> [PagerDuty/Slack channel]</p>
  </ac:rich-text-body>
</ac:structured-macro>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p><strong>Critical Commands Warning:</strong> This runbook contains commands that can affect production systems. Always verify the environment before executing commands.</p>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Purpose and Scope</h2>

<p>[Describe what this runbook covers and when to use it]</p>

<h3>When to Use This Runbook</h3>
<ul>
  <li>[Scenario 1]</li>
  <li>[Scenario 2]</li>
  <li>[Scenario 3]</li>
</ul>

<h3>Out of Scope</h3>
<ul>
  <li>[What this runbook does NOT cover]</li>
</ul>

<h2>Prerequisites</h2>

<h3>Access Requirements</h3>
<ul>
  <li>[Required access 1] - How to obtain: [link/instructions]</li>
  <li>[Required access 2] - How to obtain: [link/instructions]</li>
</ul>

<h3>Tools Required</h3>
<ul>
  <li>[Tool 1] - Installation: <code>[command]</code></li>
  <li>[Tool 2] - Installation: <code>[command]</code></li>
</ul>

<h3>Knowledge Prerequisites</h3>
<ul>
  <li>Understanding of [concept 1]</li>
  <li>Familiarity with [concept 2]</li>
</ul>

<h2>Service Overview</h2>

<h3>Architecture</h3>
<p>[Brief description of the service architecture]</p>

<h3>Key Components</h3>
<table>
  <tbody>
    <tr>
      <th>Component</th>
      <th>Purpose</th>
      <th>Location</th>
    </tr>
    <tr>
      <td>[Component 1]</td>
      <td>[What it does]</td>
      <td>[Where it runs]</td>
    </tr>
    <tr>
      <td>[Component 2]</td>
      <td>[What it does]</td>
      <td>[Where it runs]</td>
    </tr>
  </tbody>
</table>

<h3>Key Metrics</h3>
<ul>
  <li><strong>[Metric 1]:</strong> [Dashboard link] - Normal range: [X-Y]</li>
  <li><strong>[Metric 2]:</strong> [Dashboard link] - Normal range: [X-Y]</li>
</ul>

<h2>Procedures</h2>

<h3>Procedure 1: [Name]</h3>

<ac:structured-macro ac:name="info">
  <ac:rich-text-body>
    <p><strong>Estimated Time:</strong> [X minutes]</p>
    <p><strong>Risk Level:</strong> [Low/Medium/High]</p>
    <p><strong>Requires:</strong> [Specific permissions]</p>
  </ac:rich-text-body>
</ac:structured-macro>

<h4>Steps</h4>

<ol>
  <li>
    <p><strong>[Step 1 Title]</strong></p>
    <p>[Description of what to do]</p>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">bash</ac:parameter>
      <ac:plain-text-body><![CDATA[
# Command to execute
kubectl get pods -n namespace
]]></ac:plain-text-body>
    </ac:structured-macro>
    <p><strong>Expected output:</strong> [What you should see]</p>
  </li>
  <li>
    <p><strong>[Step 2 Title]</strong></p>
    <p>[Description]</p>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">bash</ac:parameter>
      <ac:plain-text-body><![CDATA[
# Another command
echo "example"
]]></ac:plain-text-body>
    </ac:structured-macro>
  </li>
  <li>
    <p><strong>[Step 3 Title]</strong></p>
    <p>[Description]</p>
  </li>
</ol>

<h4>Verification</h4>
<p>Confirm the procedure was successful by:</p>
<ul>
  <li>[Verification check 1]</li>
  <li>[Verification check 2]</li>
</ul>

<h3>Procedure 2: [Name]</h3>

<p>[Follow same format as above]</p>

<h2>Troubleshooting</h2>

<h3>Common Issues</h3>

<ac:structured-macro ac:name="expand">
  <ac:parameter ac:name="title">Issue: [Problem Description]</ac:parameter>
  <ac:rich-text-body>
    <p><strong>Symptoms:</strong></p>
    <ul>
      <li>[Symptom 1]</li>
      <li>[Symptom 2]</li>
    </ul>
    <p><strong>Cause:</strong> [Root cause explanation]</p>
    <p><strong>Resolution:</strong></p>
    <ol>
      <li>[Resolution step 1]</li>
      <li>[Resolution step 2]</li>
    </ol>
  </ac:rich-text-body>
</ac:structured-macro>

<ac:structured-macro ac:name="expand">
  <ac:parameter ac:name="title">Issue: [Another Problem]</ac:parameter>
  <ac:rich-text-body>
    <p><strong>Symptoms:</strong></p>
    <ul>
      <li>[Symptom 1]</li>
    </ul>
    <p><strong>Cause:</strong> [Cause]</p>
    <p><strong>Resolution:</strong></p>
    <ol>
      <li>[Step 1]</li>
    </ol>
  </ac:rich-text-body>
</ac:structured-macro>

<h3>Diagnostic Commands</h3>

<table>
  <tbody>
    <tr>
      <th>Check</th>
      <th>Command</th>
      <th>Normal Output</th>
    </tr>
    <tr>
      <td>Service Status</td>
      <td><code>systemctl status service-name</code></td>
      <td>Active (running)</td>
    </tr>
    <tr>
      <td>Log Errors</td>
      <td><code>journalctl -u service-name --since "1 hour ago" | grep ERROR</code></td>
      <td>No output (no errors)</td>
    </tr>
    <tr>
      <td>Connectivity</td>
      <td><code>curl -s -o /dev/null -w "%{http_code}" http://endpoint/health</code></td>
      <td>200</td>
    </tr>
  </tbody>
</table>

<h2>Rollback Procedures</h2>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p><strong>When to Rollback:</strong></p>
    <ul>
      <li>[Condition 1 that triggers rollback]</li>
      <li>[Condition 2 that triggers rollback]</li>
      <li>[Condition 3]</li>
    </ul>
  </ac:rich-text-body>
</ac:structured-macro>

<h3>Rollback Steps</h3>

<ol>
  <li>
    <p><strong>Notify stakeholders</strong></p>
    <p>Post in #[slack-channel]: "Initiating rollback of [service] due to [reason]"</p>
  </li>
  <li>
    <p><strong>[Rollback Step 1]</strong></p>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">bash</ac:parameter>
      <ac:plain-text-body><![CDATA[
# Rollback command
kubectl rollout undo deployment/service-name -n namespace
]]></ac:plain-text-body>
    </ac:structured-macro>
  </li>
  <li>
    <p><strong>Verify rollback</strong></p>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">bash</ac:parameter>
      <ac:plain-text-body><![CDATA[
# Verification command
kubectl rollout status deployment/service-name -n namespace
]]></ac:plain-text-body>
    </ac:structured-macro>
  </li>
  <li>
    <p><strong>Update stakeholders</strong></p>
    <p>Post completion status in #[slack-channel]</p>
  </li>
</ol>

<h2>Escalation</h2>

<h3>When to Escalate</h3>
<ul>
  <li>[Escalation trigger 1]</li>
  <li>[Escalation trigger 2]</li>
  <li>If issue persists after [X minutes/attempts]</li>
</ul>

<h3>Escalation Contacts</h3>

<table>
  <tbody>
    <tr>
      <th>Level</th>
      <th>Contact</th>
      <th>Method</th>
      <th>When</th>
    </tr>
    <tr>
      <td>L1</td>
      <td>[On-call engineer]</td>
      <td>PagerDuty / #slack-channel</td>
      <td>First contact</td>
    </tr>
    <tr>
      <td>L2</td>
      <td>[Team Lead]</td>
      <td>Direct message / Phone</td>
      <td>After 15 min</td>
    </tr>
    <tr>
      <td>L3</td>
      <td>[Engineering Manager]</td>
      <td>Phone</td>
      <td>Critical/extended outage</td>
    </tr>
  </tbody>
</table>

<h2>Post-Incident</h2>

<h3>Documentation Required</h3>
<ul>
  <li>Create incident ticket: <ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">PROJ-XXX</ac:parameter></ac:structured-macro></li>
  <li>Update this runbook if new issues discovered</li>
  <li>Schedule post-mortem if P1/P2 incident</li>
</ul>

<h3>Communication Template</h3>
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">text</ac:parameter>
  <ac:parameter ac:name="title">Incident Resolution Message</ac:parameter>
  <ac:plain-text-body><![CDATA[
[Service Name] - Incident Resolved

Impact: [Description of impact]
Duration: [Start time] - [End time] ([X] minutes)
Root Cause: [Brief explanation]
Resolution: [What was done to fix it]
Follow-up: [Ticket number for post-mortem/fixes]
]]></ac:plain-text-body>
</ac:structured-macro>

<h2>Related Documents</h2>

<ul>
  <li><ac:link><ri:page ri:content-title="Service Architecture" ri:space-key="DEV"/></ac:link></li>
  <li><ac:link><ri:page ri:content-title="Deployment Guide" ri:space-key="DEV"/></ac:link></li>
  <li><ac:link><ri:page ri:content-title="Monitoring Setup" ri:space-key="DEV"/></ac:link></li>
</ul>

<h2>Revision History</h2>

<table>
  <tbody>
    <tr>
      <th>Date</th>
      <th>Author</th>
      <th>Changes</th>
    </tr>
    <tr>
      <td>YYYY-MM-DD</td>
      <td>[Name]</td>
      <td>Initial version</td>
    </tr>
  </tbody>
</table>
```

## Writing Guidelines

**Be precise:** Commands should be copy-pasteable. Include exact paths, namespace names, and expected outputs.

**Think about stress:** Runbooks are used during incidents. Keep steps clear and numbered. Avoid ambiguity.

**Include verification:** After each major step, include how to verify success.

**Plan for failure:** Include troubleshooting for each procedure and clear escalation paths.

**Keep current:** Update runbooks immediately when procedures change. Outdated runbooks are dangerous.
