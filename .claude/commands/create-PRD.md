---
description: Create a Product Requirements Document from conversation
argument-hint: [output-filename]
---

# Create PRD: Generate Product Requirements Document

## Overview

Generate a comprehensive Product Requirements Document (PRD) based on the current conversation context and requirements discussed. Use the structure and sections defined below to create a thorough, professional PRD.

## Output File

Write the PRD to: `$ARGUMENTS` (default: `docs/PRD.md`)

**Before writing, ensure the target directory exists.** If `docs/` (or the parent directory of `$ARGUMENTS`) is missing, create it first — `mkdir -p <parent-dir>`. This guarantees the PRD lands in a predictable location even on a fresh starter clone where `docs/` has not yet been initialized.

## PRD Structure

Create a well-structured PRD with the following sections. Adapt depth and detail based on available information:

### Required Sections

**1. Executive Summary**
- Concise product overview (2-3 paragraphs)
- Core value proposition
- MVP goal statement

**2. Mission**
- Product mission statement
- Core principles (3-5 key principles)

**3. Target Users**
- Primary user personas
- Technical comfort level
- Key user needs and pain points

**4. MVP Scope**
- **In Scope:** Core functionality for MVP (use checkboxes)
- **Out of Scope:** Features deferred to future phases (use checkboxes)
- Group by categories (Core Functionality, Technical, Integration, Deployment)

**5. User Stories**
- Primary user stories (5-8 stories) in format: "As a [user], I want to [action], so that [benefit]"
- Include concrete examples for each story
- Add technical user stories if relevant

**6. Core Architecture & Patterns**
- High-level architecture approach
- Directory structure (if applicable)
- Key design patterns and principles
- Technology-specific patterns

**7. Tools/Features**
- Detailed feature specifications
- If building an agent: Tool designs with purpose, operations, and key features
- If building an app: Core feature breakdown

**8. Technology Stack**
- Backend/Frontend technologies with versions
- Dependencies and libraries
- Optional dependencies
- Third-party integrations

**9. Security & Configuration**
- Authentication/authorization approach
- Configuration management (environment variables, settings)
- Security scope (in-scope and out-of-scope)
- Deployment considerations

**10. API Specification** (if applicable)
- Endpoint definitions
- Request/response formats
- Authentication requirements
- Example payloads

**11. Success Criteria**
- MVP success definition
- Functional requirements (use checkboxes)
- Quality indicators
- User experience goals

**12. Implementation Phases**
- Break down into 3-4 phases
- Each phase includes: Goal, Deliverables (checkboxes), Validation criteria
- Realistic timeline estimates

**13. Future Considerations**
- Post-MVP enhancements
- Integration opportunities
- Advanced features for later phases

**14. Risks & Mitigations**
- 3-5 key risks with specific mitigation strategies

**15. Appendix** (if applicable)
- Related documents
- Key dependencies with links
- Repository/project structure

## Instructions

### 0. Ingest raw materials from `.agents/sources/` (if present)

**Before extracting requirements from the conversation, check whether `.agents/sources/` exists and contains files.** This directory is the project's input layer for briefs, transcripts, sketches, and other raw materials the user prepared ahead of time.

- If the directory is absent or empty → skip this step silently.
- If files are present → list them, then read each one as additional requirement context **on equal footing with the conversation**. Prefer source-file content over guesswork when a detail is covered there.
- Never modify or delete files in `.agents/sources/` — they are immutable input.
- If a source file conflicts with something stated in the conversation, flag the conflict explicitly in the output and ask the user which to trust before writing the PRD.

### 1. Extract Requirements
- Review the entire conversation history **and all files read from `.agents/sources/`**
- Identify explicit requirements and implicit needs
- Note technical constraints and preferences
- Capture user goals and success criteria

### 2. Synthesize Information
- Organize requirements into appropriate sections
- Fill in reasonable assumptions where details are missing
- Maintain consistency across sections
- Ensure technical feasibility

### 3. Write the PRD
- Use clear, professional language
- Include concrete examples and specifics
- Use markdown formatting (headings, lists, code blocks, checkboxes)
- Add code snippets for technical sections where helpful
- Keep Executive Summary concise but comprehensive

### 4. Quality Checks
- All required sections present
- User stories have clear benefits
- MVP scope is realistic and well-defined
- Technology choices are justified
- Implementation phases are actionable
- Success criteria are measurable
- Consistent terminology throughout

## Style Guidelines

- **Tone:** Professional, clear, action-oriented
- **Format:** Use markdown extensively (headings, lists, code blocks, tables)
- **Checkboxes:** Use checked for in-scope items, unchecked for out-of-scope
- **Specificity:** Prefer concrete examples over abstract descriptions
- **Length:** Match depth to product complexity — a simple tool needs a shorter PRD than a multi-service platform. Aim for comprehensive coverage without filler.

## Output Confirmation

After creating the PRD:
1. Confirm the file path where it was written (`docs/PRD.md` or custom path if provided)
2. Provide a brief summary of the PRD contents
3. Highlight any assumptions made due to missing information
4. **Recommend the concrete next steps, in order:**
   1. Review the PRD and correct anything you disagree with.
   2. Run `/brainstorm <feature idea>` to design the first feature. `/brainstorm` writes the approved design to `.agents/specs/` (including the `External docs required: yes/no` flag), then hands off to `/plan-feature` — which automatically decides whether to run a web-research phase based on that flag.
   3. Run `/create-CLAUDE_MD` once the first feature has produced scaffolding (e.g. `npm init`, `uv init`, initial config files). It analyzes the codebase and fills in the project-specific sections of `CLAUDE.md`. Skipping it early is fine — the seed `CLAUDE.md` already provides baseline rules.

## Notes

- If critical information is missing, ask clarifying questions before generating
- Adapt section depth based on available details
- For highly technical products, emphasize architecture and technical stack
- For user-facing products, emphasize user stories and experience
- This command contains the complete PRD template structure - no external references needed
- PRD is a living document of intent, not state — update it only on significant scope changes, not on every feature
