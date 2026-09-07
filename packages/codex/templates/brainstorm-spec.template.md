# Design: <Feature Name>

**Date:** YYYY-MM-DD
**Status:** Draft
**External docs required:** yes | no
**Approval:** none — replaced by `scripts/approval.mjs stamp` after the user's explicit decision at the brainstorm approval point. The stamp names the approved bytes (hashed with this line excluded); any later edit to this file invalidates it.

## Summary

<1-2 sentences: what this builds and why>

## Problem

<The gap or issue this addresses — the *why*, not the feature request>

## Solution

<Chosen approach and rationale, then each rejected approach with a one-line reason>

## Assumptions

<Every default resolved without asking, one bullet each: "Assumed X (because Y)". Never blank — write "None — no defaults taken without asking" if so.>

## Architecture

<How it fits the existing codebase — components affected, data flow>

## Files

- **New:** `path/to/file.ext` — purpose
- **Modified:** `path/to/existing.ext` — what changes

## External dependencies

<If External docs required = yes: one bullet per library / API / service with the area to look up. If no: "None — all integrations covered by `.agents/reference/`".>

## Edge Cases

<Known edge cases and how they are handled>

## Out of Scope

<What this explicitly does NOT do>

## Appetite & Cut Lines

- **Appetite:** <how much this is worth — a budget, not an estimate>
- **Cut first:** <what gets dropped first if this grows, in priority order>

## Independent Review

<Filled by the review step: reviewer host/model/effort, review_id, reviewed SHA-256, verdict, accepted and rejected findings with reasons, repeat/skip reason. Never hand-written as "ship".>

## Open Questions

<Anything unresolved — delete this section if none>
