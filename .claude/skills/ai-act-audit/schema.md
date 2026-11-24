# JSON output schema

Emit exactly one fenced ```json``` block matching this shape. Keys in English; free-text values
in the report language. No extra keys, no markdown inside values.

```json
{
  "audit": {
    "subject": "https://example.com | /path/to/repo | 'pasted copy'",
    "mode": "www | repo | marketing | full",
    "date": "YYYY-MM-DD",
    "auditor": "ai-act-audit v1",
    "legalState": "Reg. (EU) 2024/1689 as amended by Reg. (EU) 2026/1744; references verified 2026-11-24"
  },
  "overallVerdict": {
    "tier": "prohibited | high-risk | limited | minimal | out-of-scope",
    "summary": "1-3 sentences: the single most important conclusion",
    "exposure": "worst applicable penalty tier phrased for an SME (lower-of rule)"
  },
  "touchpoints": [
    {
      "name": "e.g. Tidio chat widget",
      "tier": "prohibited | high-risk | limited | minimal | out-of-scope",
      "role": "provider | deployer | provider-by-art25 | not-a-deployer",
      "decidingRule": "e.g. Art. 50(1) — interacts with humans",
      "evidence": "URL / file:line / quote"
    }
  ],
  "findings": [
    {
      "id": "F-1",
      "checkId": "CODE-01",
      "severity": "CRITICAL | HIGH | MEDIUM | LOW | INFO",
      "article": "50(1)",
      "articleUrl": "https://artificialintelligenceact.eu/article/50/",
      "appliesFrom": "YYYY-MM-DD when the obligation applies only after the audit date, else null",
      "title": "short finding title",
      "evidence": "where + quote",
      "explanation": "why this fails the obligation",
      "remediation": "concrete fix; include suggested disclosure wording where applicable"
    }
  ],
  "checklist": [
    { "id": "CODE-01", "verdict": "pass | fail | partial | n/a | needs-owner", "note": "one line" }
  ],
  "verifications": [
    {
      "id": "ASK-19",
      "article": "50(4)",
      "action": "concrete verification action for the site operator",
      "ifConfirmed": "legal consequence when confirmed",
      "ifNot": "concrete step required when not confirmed"
    }
  ],
  "disclaimer": "the not-legal-advice sentence in the report language"
}
```

Rules: `findings` sorted by severity (CRITICAL first). Every finding maps to a checklist item
with verdict `fail` or `partial`. A finding with a non-null `appliesFrom` is an upcoming
obligation: severity MEDIUM at most, and its title and explanation name the date
(`audit.legalState` copies the "Last verified" date of legal-refs.md). `verifications` contains only outcome-changing items (see
checklist.md ASK rules) — an empty array is a legitimate result, as is an empty `findings`
array with tier `minimal`.
