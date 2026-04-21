# Feature Breakdown Example: User Data Export

This example shows how to break down a user story into actionable Jira sub-tasks.

## User Story

**Title:** Export User Data to CSV

**Description:**
```
As a user,
I want to export my data to CSV format,
So that I can analyze it offline or import it into other tools.

Acceptance Criteria:
- User can export all their records
- Export includes all data fields
- Large exports are handled asynchronously
- User receives notification when export is ready
- Download link expires after 24 hours
```

## Task Breakdown

### Backend Tasks

#### 1. [DB] Create export_jobs table
**Summary:** Create database migration for export job tracking

**Description:**
```
h2. Objective
Create migration to add export_jobs table for tracking async export operations.

h2. Acceptance Criteria
* [ ] Migration creates export_jobs table
* [ ] Indexes added for user_id and status
* [ ] Migration is reversible

h2. Schema
{code:sql}
CREATE TABLE export_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    file_path VARCHAR(500),
    record_count INTEGER,
    created_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP,
    expires_at TIMESTAMP,
    error_message TEXT
);

CREATE INDEX idx_export_jobs_user_id ON export_jobs(user_id);
CREATE INDEX idx_export_jobs_status ON export_jobs(status);
{code}

h2. Files
* {{src/migrations/20240115_create_export_jobs.ts}}
```

**Labels:** backend, database
**Story Points:** 1

---

#### 2. [BE] Implement ExportJob entity and repository
**Summary:** Create ExportJob entity with repository methods

**Description:**
```
h2. Objective
Implement ExportJob entity and repository for managing export operations.

h2. Acceptance Criteria
* [ ] ExportJob entity with all fields
* [ ] Repository with CRUD operations
* [ ] Method to find pending jobs for processing
* [ ] Method to find expired jobs for cleanup

h2. Files
* {{src/entities/ExportJob.ts}} - Create
* {{src/repositories/ExportJobRepository.ts}} - Create
* {{src/repositories/ExportJobRepository.test.ts}} - Create

h2. Dependencies
* Requires: [DB] Create export_jobs table
```

**Labels:** backend
**Story Points:** 2

---

#### 3. [BE] Create CSV generation service
**Summary:** Implement service for generating CSV files from user data

**Description:**
```
h2. Objective
Create service that generates CSV files from user data with proper formatting.

h2. Acceptance Criteria
* [ ] Handles all data types correctly
* [ ] Properly escapes special characters
* [ ] Streams data for memory efficiency
* [ ] Supports large datasets (100k+ rows)

h2. Technical Approach
Use streaming CSV library to avoid loading all data into memory.

{code:typescript}
interface CsvExportService {
  exportUserData(userId: string, outputPath: string): Promise<ExportResult>;
}

interface ExportResult {
  recordCount: number;
  fileSize: number;
  filePath: string;
}
{code}

h2. Files
* {{src/services/CsvExportService.ts}} - Create
* {{src/services/CsvExportService.test.ts}} - Create

h2. Testing
* Small dataset export
* Large dataset export (10k rows)
* Special characters handling
* Empty dataset handling
```

**Labels:** backend
**Story Points:** 3

---

#### 4. [BE] Implement async job processor
**Summary:** Create background job processor for handling export requests

**Description:**
```
h2. Objective
Implement job processor that picks up pending export jobs and processes them.

h2. Acceptance Criteria
* [ ] Processes pending jobs in order
* [ ] Updates job status during processing
* [ ] Handles errors gracefully
* [ ] Sends notification on completion
* [ ] Retries failed jobs up to 3 times

h2. Files
* {{src/jobs/ExportJobProcessor.ts}} - Create
* {{src/jobs/ExportJobProcessor.test.ts}} - Create

h2. Dependencies
* Requires: CSV generation service
* Requires: Notification service
```

**Labels:** backend
**Story Points:** 3

---

### API Tasks

#### 5. [API] POST /exports - Create export request
**Summary:** Implement endpoint to initiate data export

**Description:**
```
h2. Objective
Create endpoint for users to request a data export.

h2. Endpoint Specification
*Method:* POST
*Path:* {{/api/v1/exports}}
*Auth:* Required

h3. Request
{code:json}
{
  "format": "csv",
  "includeFields": ["all"] // or specific field names
}
{code}

h3. Response (202 Accepted)
{code:json}
{
  "jobId": "uuid",
  "status": "pending",
  "estimatedRecords": 1500,
  "message": "Export started. You will be notified when ready."
}
{code}

h2. Files
* {{src/controllers/ExportController.ts}} - Create
* {{src/routes/exports.ts}} - Create
```

**Labels:** api, backend
**Story Points:** 2

---

#### 6. [API] GET /exports/:jobId - Check export status
**Summary:** Implement endpoint to check export job status

**Description:**
```
h2. Objective
Create endpoint for users to check the status of their export job.

h2. Endpoint Specification
*Method:* GET
*Path:* {{/api/v1/exports/:jobId}}
*Auth:* Required

h3. Response (200 OK) - Pending
{code:json}
{
  "jobId": "uuid",
  "status": "processing",
  "progress": 45
}
{code}

h3. Response (200 OK) - Complete
{code:json}
{
  "jobId": "uuid",
  "status": "completed",
  "downloadUrl": "/api/v1/exports/uuid/download",
  "recordCount": 1500,
  "expiresAt": "2024-01-16T12:00:00Z"
}
{code}

h2. Files
* {{src/controllers/ExportController.ts}} - Modify
```

**Labels:** api, backend
**Story Points:** 1

---

#### 7. [API] GET /exports/:jobId/download - Download export file
**Summary:** Implement secure file download endpoint

**Description:**
```
h2. Objective
Create endpoint to download the generated export file.

h2. Endpoint Specification
*Method:* GET
*Path:* {{/api/v1/exports/:jobId/download}}
*Auth:* Required

h3. Response
* Content-Type: text/csv
* Content-Disposition: attachment; filename="export-2024-01-15.csv"
* Streams file content

h2. Security
* Verify user owns the export job
* Check job is completed
* Check download link hasn't expired

h2. Files
* {{src/controllers/ExportController.ts}} - Modify
```

**Labels:** api, backend
**Story Points:** 2

---

### Frontend Tasks

#### 8. [FE] Add export button to data page
**Summary:** Add export button with format selection

**Description:**
```
h2. Objective
Add export functionality to the user data page.

h2. Acceptance Criteria
* [ ] Export button visible on data page
* [ ] Click opens confirmation dialog
* [ ] Shows estimated record count
* [ ] Disables button while export in progress

h2. Design
[Link to Figma design]

h2. Files
* {{src/components/data/ExportButton.tsx}} - Create
* {{src/pages/data/index.tsx}} - Modify
```

**Labels:** frontend
**Story Points:** 2

---

#### 9. [FE] Implement export status polling
**Summary:** Add status polling and progress display

**Description:**
```
h2. Objective
Poll export status and display progress to user.

h2. Acceptance Criteria
* [ ] Poll every 5 seconds while job pending
* [ ] Show progress bar during processing
* [ ] Show download button when complete
* [ ] Handle error states

h2. Files
* {{src/hooks/useExportStatus.ts}} - Create
* {{src/components/data/ExportProgress.tsx}} - Create
```

**Labels:** frontend
**Story Points:** 2

---

#### 10. [FE] Add export notification handler
**Summary:** Handle push notification for export completion

**Description:**
```
h2. Objective
Display toast notification when export is ready.

h2. Acceptance Criteria
* [ ] Toast appears when export completes
* [ ] Toast includes download link
* [ ] Toast can be dismissed

h2. Files
* {{src/components/notifications/ExportNotification.tsx}} - Create
```

**Labels:** frontend
**Story Points:** 1

---

### Testing Tasks

#### 11. [TEST] Write unit tests for export service
**Summary:** Unit tests for CSV generation and job processing

**Description:**
```
h2. Objective
Comprehensive unit tests for export functionality.

h2. Test Cases
* CSV generation with various data types
* Special character escaping
* Large dataset handling
* Job status transitions
* Error handling and retries

h2. Files
* {{src/services/CsvExportService.test.ts}}
* {{src/jobs/ExportJobProcessor.test.ts}}
```

**Labels:** testing
**Story Points:** 2

---

#### 12. [TEST] Write E2E tests for export flow
**Summary:** End-to-end tests for complete export workflow

**Description:**
```
h2. Objective
E2E tests covering the full export user journey.

h2. Test Scenarios
# User initiates export
# User checks status
# User downloads completed export
# User handles expired download
# User handles failed export

h2. Files
* {{tests/e2e/export.spec.ts}}
```

**Labels:** testing, e2e
**Story Points:** 2

---

### Documentation Tasks

#### 13. [DOCS] Update API documentation
**Summary:** Document export endpoints in API docs

**Description:**
```
h2. Objective
Add export endpoints to API documentation.

h2. Content
* Endpoint descriptions
* Request/response examples
* Error codes
* Rate limits

h2. Files
* {{docs/api/exports.md}} - Create
* OpenAPI spec update
```

**Labels:** documentation
**Story Points:** 1

---

## Summary

| Type | Count | Total Points |
|------|-------|--------------|
| Backend | 4 | 9 |
| API | 3 | 5 |
| Frontend | 3 | 5 |
| Testing | 2 | 4 |
| Documentation | 1 | 1 |
| **Total** | **13** | **24** |

## Dependency Graph

```
[DB] Schema
    └──► [BE] Entity/Repository
              └──► [BE] CSV Service
                        └──► [BE] Job Processor
                                  │
    ┌─────────────────────────────┘
    ▼
[API] POST /exports
    └──► [API] GET /exports/:id
              └──► [API] GET /download
                        │
    ┌─────────────────┘
    ▼
[FE] Export Button
    └──► [FE] Status Polling
              └──► [FE] Notification
                        │
    ┌─────────────────┘
    ▼
[TEST] Unit Tests
    └──► [TEST] E2E Tests
              └──► [DOCS] API Docs
```
