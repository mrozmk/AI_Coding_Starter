# API Reference Documentation Template

## Confluence Storage Format

```xml
<ac:structured-macro ac:name="toc">
  <ac:parameter ac:name="printable">true</ac:parameter>
  <ac:parameter ac:name="maxLevel">3</ac:parameter>
</ac:structured-macro>

<ac:structured-macro ac:name="panel">
  <ac:parameter ac:name="bgColor">#f4f5f7</ac:parameter>
  <ac:parameter ac:name="titleBGColor">#5243aa</ac:parameter>
  <ac:parameter ac:name="title">API Information</ac:parameter>
  <ac:rich-text-body>
    <p><strong>API Version:</strong> v1</p>
    <p><strong>Base URL:</strong> <code>https://api.example.com/v1</code></p>
    <p><strong>Last Updated:</strong> YYYY-MM-DD</p>
    <p><strong>OpenAPI Spec:</strong> [Link to spec]</p>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Overview</h2>

<p>[Brief description of what this API provides and its main use cases]</p>

<h2>Authentication</h2>

<h3>Authentication Method</h3>

<p>[Describe authentication method: API Key, OAuth 2.0, JWT, etc.]</p>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">bash</ac:parameter>
  <ac:parameter ac:name="title">Authentication Example</ac:parameter>
  <ac:plain-text-body><![CDATA[
curl -X GET "https://api.example.com/v1/resource" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json"
]]></ac:plain-text-body>
</ac:structured-macro>

<h3>Obtaining Credentials</h3>
<ol>
  <li>[Step 1 to get credentials]</li>
  <li>[Step 2]</li>
  <li>[Step 3]</li>
</ol>

<ac:structured-macro ac:name="warning">
  <ac:rich-text-body>
    <p><strong>Security Note:</strong> Never expose API keys in client-side code or public repositories.</p>
  </ac:rich-text-body>
</ac:structured-macro>

<h2>Endpoints</h2>

<h3>Resource: [Resource Name]</h3>

<h4>List [Resources]</h4>

<table>
  <tbody>
    <tr>
      <td><strong>Method</strong></td>
      <td><code>GET</code></td>
    </tr>
    <tr>
      <td><strong>Endpoint</strong></td>
      <td><code>/resources</code></td>
    </tr>
    <tr>
      <td><strong>Description</strong></td>
      <td>Retrieves a paginated list of resources</td>
    </tr>
  </tbody>
</table>

<p><strong>Query Parameters:</strong></p>
<table>
  <tbody>
    <tr>
      <th>Parameter</th>
      <th>Type</th>
      <th>Required</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>page</code></td>
      <td>integer</td>
      <td>No</td>
      <td>Page number (default: 1)</td>
    </tr>
    <tr>
      <td><code>limit</code></td>
      <td>integer</td>
      <td>No</td>
      <td>Items per page (default: 20, max: 100)</td>
    </tr>
    <tr>
      <td><code>filter</code></td>
      <td>string</td>
      <td>No</td>
      <td>Filter by name</td>
    </tr>
  </tbody>
</table>

<ac:structured-macro ac:name="expand">
  <ac:parameter ac:name="title">Example Request</ac:parameter>
  <ac:rich-text-body>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">bash</ac:parameter>
      <ac:plain-text-body><![CDATA[
curl -X GET "https://api.example.com/v1/resources?page=1&limit=10" \
  -H "Authorization: Bearer YOUR_TOKEN"
]]></ac:plain-text-body>
    </ac:structured-macro>
  </ac:rich-text-body>
</ac:structured-macro>

<ac:structured-macro ac:name="expand">
  <ac:parameter ac:name="title">Example Response (200 OK)</ac:parameter>
  <ac:rich-text-body>
    <ac:structured-macro ac:name="code">
      <ac:parameter ac:name="language">json</ac:parameter>
      <ac:plain-text-body><![CDATA[
{
  "data": [
    {
      "id": "res_123",
      "name": "Example Resource",
      "created_at": "2024-01-15T10:30:00Z",
      "status": "active"
    }
  ],
  "pagination": {
    "page": 1,
    "limit": 10,
    "total": 42,
    "total_pages": 5
  }
}
]]></ac:plain-text-body>
    </ac:structured-macro>
  </ac:rich-text-body>
</ac:structured-macro>

<h4>Get [Resource]</h4>

<table>
  <tbody>
    <tr>
      <td><strong>Method</strong></td>
      <td><code>GET</code></td>
    </tr>
    <tr>
      <td><strong>Endpoint</strong></td>
      <td><code>/resources/{id}</code></td>
    </tr>
    <tr>
      <td><strong>Description</strong></td>
      <td>Retrieves a single resource by ID</td>
    </tr>
  </tbody>
</table>

<p><strong>Path Parameters:</strong></p>
<table>
  <tbody>
    <tr>
      <th>Parameter</th>
      <th>Type</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>id</code></td>
      <td>string</td>
      <td>Resource ID (format: res_*)</td>
    </tr>
  </tbody>
</table>

<h4>Create [Resource]</h4>

<table>
  <tbody>
    <tr>
      <td><strong>Method</strong></td>
      <td><code>POST</code></td>
    </tr>
    <tr>
      <td><strong>Endpoint</strong></td>
      <td><code>/resources</code></td>
    </tr>
    <tr>
      <td><strong>Description</strong></td>
      <td>Creates a new resource</td>
    </tr>
  </tbody>
</table>

<p><strong>Request Body:</strong></p>
<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">json</ac:parameter>
  <ac:plain-text-body><![CDATA[
{
  "name": "string (required, 1-255 chars)",
  "description": "string (optional)",
  "type": "string (required, enum: type_a|type_b|type_c)",
  "metadata": {
    "key": "value (optional)"
  }
}
]]></ac:plain-text-body>
</ac:structured-macro>

<h4>Update [Resource]</h4>

<table>
  <tbody>
    <tr>
      <td><strong>Method</strong></td>
      <td><code>PUT</code> or <code>PATCH</code></td>
    </tr>
    <tr>
      <td><strong>Endpoint</strong></td>
      <td><code>/resources/{id}</code></td>
    </tr>
    <tr>
      <td><strong>Description</strong></td>
      <td>Updates an existing resource</td>
    </tr>
  </tbody>
</table>

<h4>Delete [Resource]</h4>

<table>
  <tbody>
    <tr>
      <td><strong>Method</strong></td>
      <td><code>DELETE</code></td>
    </tr>
    <tr>
      <td><strong>Endpoint</strong></td>
      <td><code>/resources/{id}</code></td>
    </tr>
    <tr>
      <td><strong>Description</strong></td>
      <td>Deletes a resource</td>
    </tr>
  </tbody>
</table>

<h2>Error Handling</h2>

<h3>Error Response Format</h3>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">json</ac:parameter>
  <ac:plain-text-body><![CDATA[
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Human-readable error message",
    "details": [
      {
        "field": "name",
        "message": "Name is required"
      }
    ],
    "request_id": "req_abc123"
  }
}
]]></ac:plain-text-body>
</ac:structured-macro>

<h3>HTTP Status Codes</h3>

<table>
  <tbody>
    <tr>
      <th>Code</th>
      <th>Meaning</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>200</code></td>
      <td>OK</td>
      <td>Request succeeded</td>
    </tr>
    <tr>
      <td><code>201</code></td>
      <td>Created</td>
      <td>Resource created successfully</td>
    </tr>
    <tr>
      <td><code>204</code></td>
      <td>No Content</td>
      <td>Request succeeded, no content returned</td>
    </tr>
    <tr>
      <td><code>400</code></td>
      <td>Bad Request</td>
      <td>Invalid request parameters</td>
    </tr>
    <tr>
      <td><code>401</code></td>
      <td>Unauthorized</td>
      <td>Missing or invalid authentication</td>
    </tr>
    <tr>
      <td><code>403</code></td>
      <td>Forbidden</td>
      <td>Insufficient permissions</td>
    </tr>
    <tr>
      <td><code>404</code></td>
      <td>Not Found</td>
      <td>Resource not found</td>
    </tr>
    <tr>
      <td><code>429</code></td>
      <td>Too Many Requests</td>
      <td>Rate limit exceeded</td>
    </tr>
    <tr>
      <td><code>500</code></td>
      <td>Internal Server Error</td>
      <td>Server error, contact support</td>
    </tr>
  </tbody>
</table>

<h3>Error Codes</h3>

<table>
  <tbody>
    <tr>
      <th>Code</th>
      <th>Description</th>
      <th>Resolution</th>
    </tr>
    <tr>
      <td><code>VALIDATION_ERROR</code></td>
      <td>Request validation failed</td>
      <td>Check details array for specific field errors</td>
    </tr>
    <tr>
      <td><code>AUTHENTICATION_ERROR</code></td>
      <td>Authentication failed</td>
      <td>Verify API key/token is valid</td>
    </tr>
    <tr>
      <td><code>RESOURCE_NOT_FOUND</code></td>
      <td>Requested resource doesn't exist</td>
      <td>Verify the resource ID</td>
    </tr>
    <tr>
      <td><code>RATE_LIMIT_EXCEEDED</code></td>
      <td>Too many requests</td>
      <td>Wait and retry with backoff</td>
    </tr>
  </tbody>
</table>

<h2>Rate Limiting</h2>

<table>
  <tbody>
    <tr>
      <th>Plan</th>
      <th>Requests/minute</th>
      <th>Requests/day</th>
    </tr>
    <tr>
      <td>Free</td>
      <td>60</td>
      <td>1,000</td>
    </tr>
    <tr>
      <td>Pro</td>
      <td>600</td>
      <td>50,000</td>
    </tr>
    <tr>
      <td>Enterprise</td>
      <td>Custom</td>
      <td>Custom</td>
    </tr>
  </tbody>
</table>

<p><strong>Rate Limit Headers:</strong></p>
<ul>
  <li><code>X-RateLimit-Limit</code>: Maximum requests per window</li>
  <li><code>X-RateLimit-Remaining</code>: Requests remaining</li>
  <li><code>X-RateLimit-Reset</code>: Unix timestamp when limit resets</li>
</ul>

<h2>SDKs and Code Examples</h2>

<h3>JavaScript/Node.js</h3>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">javascript</ac:parameter>
  <ac:plain-text-body><![CDATA[
const response = await fetch('https://api.example.com/v1/resources', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${apiToken}`,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    name: 'New Resource',
    type: 'type_a'
  })
});

const data = await response.json();
]]></ac:plain-text-body>
</ac:structured-macro>

<h3>Python</h3>

<ac:structured-macro ac:name="code">
  <ac:parameter ac:name="language">python</ac:parameter>
  <ac:plain-text-body><![CDATA[
import requests

response = requests.post(
    'https://api.example.com/v1/resources',
    headers={
        'Authorization': f'Bearer {api_token}',
        'Content-Type': 'application/json'
    },
    json={
        'name': 'New Resource',
        'type': 'type_a'
    }
)

data = response.json()
]]></ac:plain-text-body>
</ac:structured-macro>

<h2>Changelog</h2>

<table>
  <tbody>
    <tr>
      <th>Version</th>
      <th>Date</th>
      <th>Changes</th>
    </tr>
    <tr>
      <td>v1.2</td>
      <td>2024-01-15</td>
      <td>Added filtering to list endpoint</td>
    </tr>
    <tr>
      <td>v1.1</td>
      <td>2024-01-01</td>
      <td>Added pagination support</td>
    </tr>
    <tr>
      <td>v1.0</td>
      <td>2023-12-01</td>
      <td>Initial release</td>
    </tr>
  </tbody>
</table>
```

## Writing Guidelines

**Be complete:** Include all parameters, headers, and possible responses for each endpoint.

**Use examples:** Provide working curl commands and code snippets in multiple languages.

**Document errors:** List all possible error codes with clear resolution steps.

**Keep updated:** Track API changes in the changelog section.
