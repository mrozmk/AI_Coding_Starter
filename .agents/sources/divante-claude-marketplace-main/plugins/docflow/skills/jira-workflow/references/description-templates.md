# Jira Description Templates

## Epic Description Template

```
h2. Epic Overview
[High-level description of the initiative and its business value]

h2. Goals
* [Goal 1]
* [Goal 2]
* [Goal 3]

h2. Success Metrics
|| Metric || Target || Current ||
| [Metric 1] | [Target value] | [Current value] |
| [Metric 2] | [Target value] | [Current value] |

h2. Scope
h3. In Scope
* [Feature/capability 1]
* [Feature/capability 2]
* [Feature/capability 3]

h3. Out of Scope
* [Explicitly excluded item 1]
* [Explicitly excluded item 2]

h2. Stories
This epic includes the following stories:
* PROJ-101: [Story 1 summary]
* PROJ-102: [Story 2 summary]
* PROJ-103: [Story 3 summary]

h2. Dependencies
* [External dependency 1]
* [External dependency 2]

h2. Risks
|| Risk || Likelihood || Impact || Mitigation ||
| [Risk 1] | Medium | High | [Mitigation plan] |
| [Risk 2] | Low | Medium | [Mitigation plan] |

h2. Timeline
* Start Date: [Date]
* Target Completion: [Date]
* Key Milestones:
** [Date]: [Milestone 1]
** [Date]: [Milestone 2]

h2. Resources
* [Link to PRD]
* [Link to designs]
* [Link to technical spec]
```

## Story Description Template

```
h2. User Story
*As a* [user type/persona],
*I want* [goal/desire],
*So that* [benefit/value].

h2. Background
[Context and motivation for this story. Why is it needed? What problem does it solve?]

h2. Acceptance Criteria
* [ ] [Given/When/Then or simple criterion 1]
* [ ] [Criterion 2]
* [ ] [Criterion 3]
* [ ] [Criterion 4]

h2. Technical Notes
[Implementation considerations, architectural decisions, or constraints]

{code:none}
// Pseudocode or key implementation details if helpful
{code}

h2. UI/UX
* Design mockup: [link to Figma/design file]
* User flow: [link or description]

h2. API Changes
|| Method || Endpoint || Description ||
| POST | /api/v1/resource | Create new resource |
| GET | /api/v1/resource/:id | Get resource by ID |

h2. Database Changes
* New table: {{resources}}
* Modified table: {{users}} (add {{resource_count}} column)

h2. Out of Scope
* [What this story explicitly does NOT include]
* [Future enhancement not part of this story]

h2. Dependencies
* Blocked by: [PROJ-XXX if applicable]
* Related: [PROJ-YYY]

h2. Testing Notes
[Special testing considerations, edge cases to verify]

h2. Documentation
* [ ] API docs updated
* [ ] User guide updated
* [ ] README updated

h2. Links
* Epic: [PROJ-XXX]
* Design: [link]
* PRD: [link]
* Confluence: [link]
```

## Sub-task Description Template (Backend)

```
h2. Objective
[Clear, one-sentence description of what this task accomplishes]

h2. Acceptance Criteria
* [ ] [Specific, testable criterion]
* [ ] [Another criterion]
* [ ] Unit tests pass with >80% coverage
* [ ] Code review approved

h2. Technical Approach
[Description of implementation approach]

{code:java}
// Key interface or method signature
public interface UserRepository {
    User findById(String id);
    User save(User user);
    void delete(String id);
}
{code}

h2. Files to Create/Modify
* {{src/entities/User.ts}} - Create
* {{src/repositories/UserRepository.ts}} - Create
* {{src/services/UserService.ts}} - Modify

h2. Database Changes
{code:sql}
CREATE TABLE users (
    id UUID PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
{code}

h2. Dependencies
* Requires: [PROJ-XXX] to be completed first
* Blocks: [PROJ-YYY]

h2. Testing
* Unit tests for: [list functions/methods]
* Test cases:
** Happy path: [description]
** Error case: [description]
** Edge case: [description]

h2. Notes
[Any additional context or considerations]
```

## Sub-task Description Template (Frontend)

```
h2. Objective
[Clear description of the UI component or feature being built]

h2. Acceptance Criteria
* [ ] Component renders correctly
* [ ] Responsive on mobile/tablet/desktop
* [ ] Accessible (keyboard navigation, screen reader)
* [ ] Loading states handled
* [ ] Error states handled
* [ ] Unit tests pass

h2. Component Specification
*Component:* {{LoginForm}}
*Location:* {{src/components/auth/LoginForm.tsx}}

h3. Props
|| Prop || Type || Required || Description ||
| onSubmit | (credentials) => void | Yes | Called on form submission |
| isLoading | boolean | No | Shows loading spinner |
| error | string | No | Displays error message |

h3. State
* {{email}}: string - Email input value
* {{password}}: string - Password input value
* {{errors}}: object - Validation errors

h2. UI/UX Reference
* Design: [link to Figma]
* Prototype: [link if available]

h2. Files to Create/Modify
* {{src/components/auth/LoginForm.tsx}} - Create
* {{src/components/auth/LoginForm.test.tsx}} - Create
* {{src/components/auth/LoginForm.module.css}} - Create
* {{src/pages/login.tsx}} - Modify

h2. API Integration
{code:javascript}
// API call to integrate
const login = async (email, password) => {
  return api.post('/auth/login', { email, password });
};
{code}

h2. Dependencies
* API endpoint: [PROJ-XXX] POST /auth/login

h2. Testing
* Render tests
* User interaction tests
* API mock tests
* Accessibility tests

h2. Notes
[Browser support notes, known limitations, etc.]
```

## Sub-task Description Template (API)

```
h2. Objective
Implement [HTTP Method] [endpoint path] endpoint.

h2. Acceptance Criteria
* [ ] Endpoint responds correctly to valid requests
* [ ] Proper error responses for invalid requests
* [ ] Authentication/authorization working
* [ ] Rate limiting applied (if applicable)
* [ ] Integration tests pass

h2. Endpoint Specification
*Method:* POST
*Path:* {{/api/v1/auth/login}}
*Auth Required:* No

h3. Request
{code:json}
{
  "email": "user@example.com",
  "password": "securepassword123"
}
{code}

h3. Response (200 OK)
{code:json}
{
  "user": {
    "id": "uuid",
    "email": "user@example.com"
  },
  "token": "jwt-token-here",
  "expiresAt": "2024-01-15T12:00:00Z"
}
{code}

h3. Error Responses
|| Status || Code || When ||
| 400 | VALIDATION_ERROR | Invalid email format |
| 401 | INVALID_CREDENTIALS | Wrong email or password |
| 429 | RATE_LIMIT_EXCEEDED | Too many attempts |

h2. Implementation
* Controller: {{src/controllers/AuthController.ts}}
* Service: {{src/services/AuthService.ts}}
* Middleware: [any specific middleware]

h2. Dependencies
* [PROJ-XXX] Auth service implementation

h2. Testing
* Success case: Valid credentials return token
* Validation: Invalid email format returns 400
* Auth failure: Wrong password returns 401
* Rate limiting: 5 failed attempts triggers 429

h2. Documentation
* Update OpenAPI spec
* Add to API documentation page
```

## Bug Description Template

```
h2. Bug Summary
[One-line description of the bug]

h2. Environment
* *Browser/Device:* [e.g., Chrome 120, iPhone 15]
* *OS:* [e.g., macOS 14.2, iOS 17]
* *Environment:* [Production/Staging/Local]
* *User Account:* [if relevant]

h2. Steps to Reproduce
# [Step 1]
# [Step 2]
# [Step 3]
# [Step 4]

h2. Expected Behavior
[What should happen]

h2. Actual Behavior
[What actually happens]

h2. Evidence
* Screenshot: [attachment or link]
* Video: [attachment or link]
* Console errors:
{code:none}
Error message here
{code}

h2. Impact
* *Severity:* [Critical/High/Medium/Low]
* *Affected Users:* [All users / Specific segment]
* *Workaround:* [If any workaround exists]

h2. Root Cause Analysis
[To be filled during investigation]

h2. Fix
* Files modified: [list]
* PR: [link when available]

h2. Testing
* [ ] Bug no longer reproducible
* [ ] Regression tests added
* [ ] Tested on affected environments
```

## Spike/Research Description Template

```
h2. Objective
[What question(s) are we trying to answer?]

h2. Background
[Context for why this research is needed]

h2. Questions to Answer
# [Question 1]
# [Question 2]
# [Question 3]

h2. Scope
* *Timebox:* [X hours/days]
* *Deliverable:* [Document/POC/Recommendation]

h2. Approach
# [Research step 1]
# [Research step 2]
# [Prototype if needed]
# [Document findings]

h2. Options to Evaluate
|| Option || Pros || Cons ||
| [Option A] | | |
| [Option B] | | |
| [Option C] | | |

h2. Success Criteria
* [ ] All questions answered
* [ ] Recommendation documented
* [ ] Next steps identified

h2. Findings
[To be filled after investigation]

h2. Recommendation
[To be filled after investigation]

h2. Next Steps
[To be filled after investigation]
```
