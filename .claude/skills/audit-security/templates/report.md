# Security audit — {{target_name}}

**Run:** `{{run_id}}` · **Created:** {{created_utc}} · **Mode:** {{mode}} · **Target:** `{{target_root}}` @ `{{git_head}}`

## Outcome

| Axis | Value |
|---|---|
| Execution | **{{execution}}** |
| Verdict | **{{verdict}}** |
| Blocking findings | {{blocking_count}} |
| Coverage gaps | {{gap_count}} |

{{gaps_list}}

## Executive summary

<!-- report-agent: 3–6 sentences. State the verdict and the top risk first; never soften a gap. -->
{{executive_summary}}

## Run manifest

**Required classes:** {{required_classes}}
**Not required:** {{not_required}}

### Tools

| Class | Status | Tool | Version | Ruleset | Units | Basis | Reason |
|---|---|---|---|---|---|---|---|
{{tools_table}}

### Partitions (model passes)

| Partition | Claimed model | Attested | Status | Stop reason |
|---|---|---|---|---|
{{partitions_table}}

> `Claimed model` is always a recorded claim. `Attested: yes` means the claim is CLI-recorded (the Codex log banner) — still a claim, not runtime proof of which weights served the turn. See `methodology.md → Host attestation`.

## Ranked findings

| # | Id | Severity | Confidence | Verdict | Confirmations | Exposure / reach | Title | Location | CWE |
|---|---|---|---|---|---|---|---|---|---|
{{findings_table}}

## Disputed and rejected

| Id | Verdict | Reason | Title |
|---|---|---|---|
{{disputed_table}}

## Coverage matrix

| Class | Status | Units reported / expected | Basis | Ingested | Reason |
|---|---|---|---|---|---|
{{coverage_table}}

> `Basis: analyzed` — the count was read back from the tool's own output. `in-scope` — the wrapper counted the files in scope because the tool exposes no scanned list; it is not evidence the tool looked at them. `Ingested` — tool hits that became validator candidates; an `OK_FINDINGS` scan with 0 is the gap `findings-not-ingested`.

**Repo-side suppression:** {{suppression_line}} — see `methodology.md → Repo-side suppression`.

**Uncovered units:** {{uncovered_count}}
{{uncovered_list}}

**Read confinement:** the in-host Opus passes (threat-model, control-verifier, finding-validator) read with the host user's permissions and are **not** confined to the target root on this host; only the Codex pass is (sanitized pack). Review this report before sharing it — see `methodology.md → Host attestation → 6`.

## Missing tools and untested surfaces

{{missing_tools}}

## Raw artifact index

| Artifact | sha256 |
|---|---|
{{artifacts_table}}
