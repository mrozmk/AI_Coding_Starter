# Task Breakdown Patterns

## Common Feature Patterns

### CRUD Feature Pattern

For any create-read-update-delete functionality:

```
[DB] Create/modify database schema
[BE] Implement entity/model
[BE] Implement repository layer
[BE] Implement service layer with business logic
[API] Implement GET endpoint (list)
[API] Implement GET endpoint (single item)
[API] Implement POST endpoint (create)
[API] Implement PUT/PATCH endpoint (update)
[API] Implement DELETE endpoint
[FE] Create list view component
[FE] Create detail view component
[FE] Create form component (create/edit)
[FE] Implement state management
[FE] Add routing
[TEST] Write unit tests for service
[TEST] Write API integration tests
[TEST] Write E2E tests for main flows
[DOCS] Update API documentation
```

### Authentication Feature Pattern

```
[DB] Create users/sessions tables
[BE] Implement User entity
[BE] Implement password hashing utility
[BE] Implement token generation/validation
[BE] Implement auth service
[API] POST /auth/register
[API] POST /auth/login
[API] POST /auth/logout
[API] POST /auth/refresh-token
[API] Implement auth middleware
[FE] Create registration form
[FE] Create login form
[FE] Implement auth context/store
[FE] Add protected route wrapper
[FE] Handle token refresh
[TEST] Auth service unit tests
[TEST] Auth flow integration tests
[DOCS] Update authentication documentation
```

### File Upload Feature Pattern

```
[BE] Configure storage service (S3/local)
[BE] Implement file validation
[BE] Implement upload service
[API] POST /files/upload
[API] GET /files/:id
[API] DELETE /files/:id
[FE] Create file upload component
[FE] Add drag-and-drop support
[FE] Show upload progress
[FE] Display uploaded files
[TEST] Upload service tests
[TEST] E2E upload tests
[CONFIG] Configure storage credentials
[DOCS] Document file upload API
```

### Search Feature Pattern

```
[DB] Add search indexes
[BE] Implement search service
[BE] Add filtering logic
[BE] Add sorting logic
[BE] Add pagination
[API] GET /search with query params
[FE] Create search input component
[FE] Create filter controls
[FE] Create results display
[FE] Add debounced search
[FE] Handle loading states
[TEST] Search service tests
[TEST] Search E2E tests
[DOCS] Document search API
```

### Notification Feature Pattern

```
[DB] Create notifications table
[BE] Implement notification entity
[BE] Implement notification service
[BE] Create notification triggers
[API] GET /notifications
[API] PATCH /notifications/:id/read
[API] WebSocket for real-time updates
[FE] Notification bell component
[FE] Notification dropdown
[FE] Toast notifications
[FE] WebSocket connection handling
[TEST] Notification service tests
[DOCS] Document notification system
```

### Integration Feature Pattern

For third-party API integrations:

```
[BE] Create API client wrapper
[BE] Implement authentication (OAuth/API key)
[BE] Implement retry logic
[BE] Implement rate limiting
[BE] Create data mapping layer
[BE] Implement webhook handler
[API] Expose integration endpoints
[CONFIG] Add API credentials
[TEST] Mock API tests
[TEST] Integration tests (sandbox)
[DOCS] Document integration setup
```

## Size Guidelines

### Extra Small (< 4 hours)
- Bug fixes
- UI tweaks
- Config changes
- Documentation updates

### Small (4-8 hours)
- Single API endpoint
- Single component
- Unit test suite
- Database migration

### Medium (1-2 days)
- Service implementation
- Complex component
- Integration work
- E2E test suite

### Large (> 2 days)
**Split into smaller tasks!**
If a task takes more than 2 days, it should be broken down further.

## Dependency Management

### Identifying Dependencies

Tasks have dependencies when:
- Task B requires Task A's output (e.g., API needs entity)
- Task B uses Task A's code (e.g., FE needs API)
- Task B tests Task A's work (e.g., tests need implementation)

### Visualizing Dependencies

```
[DB] Schema ──────┐
                  ├──► [BE] Entity ──► [BE] Repository ──► [BE] Service
                  │                                              │
                  │                                              ▼
                  │                                         [API] Endpoints
                  │                                              │
                  └────────────────────────────────────────► [TEST] Unit
                                                                 │
                                                                 ▼
                                                            [FE] Components
                                                                 │
                                                                 ▼
                                                            [TEST] E2E
```

### Parallel Work Opportunities

Tasks that can be done in parallel:
- FE components (before API ready, use mocks)
- Unit tests (alongside implementation)
- Documentation (after design, before code complete)
- Config/deployment (alongside development)

## Story Point Estimation

### Fibonacci Scale Reference

| Points | Effort | Example |
|--------|--------|---------|
| 1 | < 4 hours | Bug fix, config change |
| 2 | 4-8 hours | Single endpoint, simple component |
| 3 | 1-2 days | Service layer, complex component |
| 5 | 2-3 days | Feature slice (BE or FE) |
| 8 | 3-5 days | Full feature (BE + FE) |
| 13 | 1 week+ | **Should be split** |

### Estimation Tips

- Estimate sub-tasks individually
- Sum sub-task estimates for story points
- If story > 13 points, break into smaller stories
- Include buffer for code review and testing
- Consider team familiarity with technology
