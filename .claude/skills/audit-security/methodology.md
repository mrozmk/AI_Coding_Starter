# /audit-security — methodology

Resource file for [`.claude/commands/audit-security.md`](../../commands/audit-security.md). The command owns the procedure; this file holds the method, the artifact contracts and the host facts the procedure depends on. Reference it by full path — the command lives in `commands/`.

Design rationale: `.agents/specs/2026-09-17-audit-security.md`. Vocabulary used below: **partition** = one detector pass with its own manifest (threat-model, control-verifier, attacker-path, finding-validator); **class** = one deterministic scanner family (`secrets`, `sast`, `sca`, `iac`); **unit** = one file in scope; **runner** = `scripts/audit-runner.mjs`, the only writer of artifacts.

---

## Host attestation

**Spike run 2026-09-17 on the installed host (Claude Code, main session), before the executor spawn.** Method: one throwaway subagent spawned with `model: opus`, asked to report only what it can observe in its own context, plus direct observation of the main session. Recorded values, verbatim from the run-log:

| Probe | Observed |
|---|---|
| Subagent self-reported model name | `Opus 5 (1M context)` |
| Subagent self-reported model ID | `claude-opus-5[1m]` |
| Model-identity env var in the subagent's environment | **none** (only `CLAUDE_CODE_EXECPATH`, an executable path) |
| Caller-side runtime attestation mechanism | **none** — nothing lets a parent verify which model served a turn without trusting the subagent's own text |
| `[cyber]` safeguard tripped in the subagent | no |
| `[cyber]` safeguard tripped in the main session (routing + reading a security-audit plan) | no |
| Main session's own effective model | `claude-opus-5[1m]` — not Fable |
| `model: opus` passed to a subagent | resolved to the parent's variant (`[1m]`) — the spawn parameter does not independently pin a variant |

**Branch taken: effective model identity is NOT observable.** Consequences, encoded in the runner and the schemas:

1. **The attestation field is a claim plus an explicit marker.** `partition-manifest.attestation.kind` is one of:
   - `none` — the agent reported no model at all;
   - `self-reported` — the agent named a model in its own output (the in-host Opus passes);
   - `cli-provenance` — a CLI path recorded the model outside the model's own text. Today only the Codex pass has this: the Codex CLI prints a `--------`-delimited banner with `model: <id>` to stderr, which `codex-bg.sh` captures as the run log; the runner parses only that banner block (`parseCodexLogHeader` — the rest of the log quotes the prompt and repository content) and stores the line as `attestation.evidence`. This is a claim by the CLI, not by the model; it is the strongest evidence this host offers, not proof of which weights served the turn. The **requested** model it is compared against is fixed before the spawn (the `model` key of `~/.codex/config.toml`, which `codex-bg.sh` does not override) — never read back from the run's own log, or `model-mismatch` could not fire.

   `partition-manifest.attested` is `true` only for `cli-provenance` with non-empty evidence. `claimed_model` is always recorded, never presented as verified.

2. **The verifier (`attestPartition` in the runner) never marks a partition COMPLETE on the strength of "the right model ran it".** Rules, in order:
   - status `ERROR` stays `ERROR`;
   - `attested: false` and status `COMPLETE` → status `INCOMPLETE`, `stop_reason: model-identity-unattested` (an already-`INCOMPLETE` partition keeps its own first cause, e.g. `malformed-output`);
   - `attested: true` but `claimed_model` ≠ the requested model → `INCOMPLETE`, `stop_reason: model-mismatch`;
   - otherwise the agent's own status stands (`COMPLETE`, or `INCOMPLETE` with its own stop reason).

   An `INCOMPLETE` partition is also a declared coverage gap in `coverage.partitions.<name>` with the same reason, so the outcome's coverage axis and verdict see it (verdict can be at most `UNKNOWN` unless a blocking finding makes it `FAIL`).

3. **No model-switch detection is claimed.** A pass interrupted by a platform safeguard cannot be told apart from a pass that finished on a different model, because the host exposes neither. The honest states are `INCOMPLETE` with `model-identity-unattested`, or a declared coverage gap — never "zero findings".

4. **Asymmetry, stated rather than papered over.** The Codex pass can be attested (CLI log header). The in-host Opus passes cannot, on this host. Therefore on this host every in-host partition is `INCOMPLETE`, the execution axis is `INCOMPLETE`, and `PASS` is unreachable until the host offers a caller-side attestation mechanism or those passes move to a CLI path with provenance. `gate` mode surfaces this as a non-zero exit unless a recorded waiver is supplied (`policies/gate.yaml → waiver`).

5. **Unverified assumption, kept visible.** The design premise that the main session is Fable and may trip `[cyber]` while routing did not reproduce (the main session was Opus). It is *unverified*, not *cleared*: the command still keeps all cyber reasoning in pinned subagents and the runner, and the main session only routes and links.

6. **The in-host passes are not read-confined (residual accepted 2026-09-18).** The three in-host Opus passes (`threat-model`, `control-verifier`, `finding-validator`) read the checkout with the host user's permissions through the host's `Read` / `Glob` / `Grep` tools, and Claude Code cannot scope those tools to `REPO_ROOT` per agent. A prompt-injected repository can therefore induce a pass to read files outside the target (another checkout, `~/.ssh`, a credentials file) and return their contents inside its JSON. The only barriers are the agent prompts and the runner's pattern-based redaction at ingest — which recognises known token shapes, not arbitrary private data. Consequence: **the report must be reviewed by a human before it is shared**, and an audit of an untrusted repository is not a contained operation on this host. The Codex pass is confined (it reads only the sanitized pack). A root-confined read broker for the in-host passes is the planned remediation; it is not in v1.

---

## Phase 0 — Authorization and run contract

- Target = the current repository (cwd). No target-path argument in v1.
- Mode = `report` (default) or `gate` (`--gate`).
- Optional `--url <base>` enables the passive-exposure smoke only, executed by `audit-runner.mjs smoke` (`scripts/lib/smoke.mjs`), never by the session: every address the host resolves to is classified and a loopback / RFC-1918 / link-local / ULA / unspecified / multicast answer refuses the target (`--allow-private` exists only for a host the user typed verbatim); the connection is pinned to one validated address through the socket `lookup` option, so a second resolution cannot redirect the connect (DNS-rebinding guard); redirects are recorded, never followed automatically — a hop is contacted only after it passes the same address rules and is same-origin (scheme, host and port), at most five hops; HEAD then GET of the base path only, query and fragment stripped, no body. `smoke.json` records the exact addresses contacted. Never a payload, never a crawl.
- The runner writes the run manifest first (`run-manifest.json`) so an aborted run leaves a record of what was attempted. A destination that already holds a `run-manifest.json` is refused unless `--resume` is passed: finalize reads every partition and finding in the dir, so a second run on top of an old one would inherit stale judgments. The command therefore names the dir with a UTC time suffix (`.agents/audits/<YYYY-MM-DD>-<HHMMSS>-<slug>`).

## Phase 1 — Capability probe

`scripts/probe-tools.sh` prints one line per candidate scanner — `available <tool> <version>` or `missing <tool>` — and exits 0 by construction. The runner derives the **required set** from the inventory (`policies/*.yaml → required_classes`): `secrets` always; `sast` when source files exist; `sca` when a dependency manifest/lockfile exists; `iac` when IaC files exist. A missing tool for a required class is a coverage `gap`, never a silent pass.

**Inventory guard (the self-excluding half-pass).** The runner enumerates every file outside the skip-list. A file of unrecognized type, a symlink, or a directory the runner could not read becomes an entry in `coverage.uncovered_units` with a reason. Uncovered units are a coverage gap. Nothing in the inventory can *shrink* the required set.

## Phase 2 — Threat model (partition `threat-model`)

`@audit-threat-modeler` (pinned `claude-opus-5`, high) returns JSON: assets, actors, trust boundaries, security invariants, entry points, privileged operations, external dependencies, and a `control → tested|partial|not-tested` skeleton. The runner persists the redacted model as `threat-model.json` in the audit dir (the input of the control-verifier pass) beside the partition manifest; a result without it is `INCOMPLETE malformed-output:no-threat-model`. Without this partition the report says "automated security review", not "audit".

## Phase 3 — Deterministic scanners

Each class runs through its wrapper only (`scripts/scan-<class>.sh`); the wrappers are the security boundary and the only scanner entrypoints the host is allowed to run:

- flags are allow-listed per wrapper; an unknown flag is `ERROR reason=bad-flag`;
- `--repo` must be the toplevel of its git worktree (a sub-directory is refused); `--out` must be writable and distinct from the repo root;
- network is disabled during analysis where the tool supports it; a control the wrapper cannot establish (no local SAST ruleset, missing offline DB) is `ERROR`, never a degraded scan;
- every artifact is redacted at ingest (`audit-runner.mjs redact`) before the runner or any model reads it;
- the last stdout line is the uniform manifest: `STATUS <tool> <version> <ruleset> <units> basis=<analyzed|in-scope> [reason=<slug>]`, `STATUS ∈ OK_FINDINGS|OK_CLEAN|ERROR|TIMEOUT|UNAVAILABLE`. `UNAVAILABLE` (binary missing) is a valid value;
- `basis=analyzed` means `<units>` was read back from the tool's own output (semgrep `paths.scanned`, trivy `Results`, osv-scanner `results[].source.path`, checkov check `file_path`s) and the wrapper also wrote the analyzed **path list** to `scan/<class>.units.json`; `basis=in-scope` means the wrapper could only count the files in scope (gitleaks exposes no scanned list). For `sast`, `sca` and `iac` only `analyzed` can be coverage (`basis-not-analyzed` otherwise); `secrets` may stay `in-scope`. An `OK_*` line with zero units, with a caveat `reason=` (semgrep parse errors, checkov parsing errors), with an expected file absent from the analyzed list (`units-missing:<n>` — a count alone cannot tell "scanned the source" from "scanned two config files"), or with fewer units than the inventory expects is a coverage **gap** — a clean exit is not evidence of analysis;
- **scanner hits reach the verdict.** After the redaction sweep the runner reads each `OK_*` artifact (`artifact=` on the manifest line) and writes one `plausible` candidate per hit to `findings/scanner-<class>.json` (`detector.family = scanner`, severity from the tool where it has one — gitleaks hits are `high` — placeholders for invariant / root cause / sink / auth context, `exposure: local`, `reachability: unknown`). The validator judges them with everything else; a scanner hit blocks only once the validator returns `confirmed` at a blocking severity. Fail-closed guard: an `OK_FINDINGS` scan with zero ingested candidates (unreadable or unrecognised artifact) is the gap `findings-not-ingested`;
- `.agents/audits/` (prior audit output) is outside the inventory, the unit count and the Codex pack;
- every wrapper runs its tool with `HOME` set to an isolated directory under the cache dir (`scan-common.sh → prepare_out`), so user-level scanner config (`~/.semgrep`, `~/.trivy.yaml`, checkov's home config) is never read and nothing is written outside the audit. The read-only git commands gitleaks runs need no `~/.gitconfig`.

Update phases (rule/DB downloads) are the human's act, outside the audit run: e.g. `trivy image --download-db-only --cache-dir <cache>` **and** `trivy image --download-java-db-only --cache-dir <cache>` (a `.jar` in the tree makes trivy fetch the Java DB mid-scan unless `--skip-java-db-update` is set — the wrapper sets it, so without the pre-step a Java-bearing repo yields `ERROR tool-exit-N`, never a silent download), then `--cache <cache>` on the wrapper.

### Repo-side suppression the audit does not honour — and the residual

The audited repository can configure its own scanners: allowlists in `.gitleaks.toml`, a `.gitleaksignore`, `nosemgrep` / `gitleaks:allow` / `checkov:skip` / `trivy:ignore` comments, `.trivyignore`, `osv-scanner.toml`, `.semgrepignore`, `.gitignore`. An attacker with a commit can therefore hide a finding from the tool, and an audit that honoured those files would be judging the repo by the repo's own rules. Every wrapper neutralises what its tool offers a flag for and **declares** both sides on its manifest line (`hardened=<a,b>`, `residual=<a,b|none>`); the report prints the declaration, never an assumption. Per tool:

| Tool | Neutralised (flag) | Residual — still honoured, no off switch |
|---|---|---|
| gitleaks (`scan-secrets.sh`) | repo `.gitleaks.toml` — `--config <skill>/config/gitleaks.toml` (precedence #1; `[extend] useDefault` keeps the built-in rules); `gitleaks:allow` comments — `--ignore-gitleaks-allow`; untracked / gitignored files — the working tree is scanned with `gitleaks dir` in addition to the history (`gitleaks git`) | `<repo>/.gitleaksignore` is **always** loaded in addition to `-i` (gitleaks 8.30 `cmd/root.go`; verified: a shipped file hid a hit from both scopes with `-i <empty dir>` and `-i <empty file>`) — no off switch. `-i <empty dir>` only shadows the cwd default. When the target ships the file the wrapper emits `reason=gitleaksignore-present` and the class degrades to `partial:gitleaksignore-present` |
| semgrep (`scan-sast.sh`) | `nosemgrep` comments — `--disable-nosem`; `.gitignore` — `--no-git-ignore`; rules — only the local `--rules` set, never the repo's `.semgrep.yml` | `.semgrepignore` at the project root is still applied: the only off switch is `--x-ignore-semgrepignore-files`, documented as `[INTERNAL] … MAY CHANGE OR DISAPPEAR WITHOUT NOTICE`, so the wrapper does not rely on it. A file excluded this way is absent from `paths.scanned` and surfaces as `units-missing` |
| trivy `fs` (`scan-sca.sh`) | `.trivyignore` / `.trivyignore.yaml` — `--ignorefile /dev/null`; `trivy.yaml` — looked up in the cwd, which the wrapper sets to the audit dir | none known for a vulnerability scan |
| osv-scanner (`scan-sca.sh`) | `osv-scanner.toml` (IgnoredVulns, PackageOverrides) — `--config <empty toml>` overrides every per-directory file; `.gitignore` — `--no-ignore` | none known |
| trivy `config` (`scan-iac.sh`) | `.trivyignore` / `.trivyignore.yaml` — `--ignorefile /dev/null`; `trivy.yaml` — cwd = audit dir | inline `trivy:ignore:<id>` comments in IaC files |
| checkov (`scan-iac.sh`) | nothing (`hardened=none`) — the empty `--config-file` only shadows the cwd/home defaults, it is not a claim | `<repo>/.checkov.yaml` / `.checkov.yml`: checkov opens `<-d>/.checkov.y(a)ml` **in addition to** `--config-file` (`checkov/main.py` → configargparse `_open_config_files`; keys absent from the explicit file still apply) — no off switch. When the target ships the file the wrapper emits `reason=checkov-yaml-present` → `partial:checkov-yaml-present`. Inline `checkov:skip=<id>` comments |

What this does not claim: the flags were taken from each tool's current CLI reference (gitleaks 8.30 verified locally; semgrep, trivy, osv-scanner v2 and checkov from their published references — none of the four is installed on the authoring host, so their behaviour is documented, not observed). A residual is a place where a repo-side comment or file can still hide a hit from the scanner; the two blind model passes and the validator read the code itself and are the compensating control, but a scanner-only signal in a residual position is not guaranteed to appear. Where the residual is a *file* the wrapper can see (`.gitleaksignore`, `.checkov.y(a)ml`), it fails closed: the manifest line carries `reason=<file>-present` and the class is a `partial:` gap, so a repo that ships the file can never be reported as fully covered by that scanner. A wrapper that prints no `hardened=` token (an older wrapper) is reported as *undeclared*, not as hardened; `hardened=none` is an explicit declaration that the tool offered nothing to neutralise.

## Phase 4 — Two blind model passes

- **control-verifier** (`@audit-control-verifier`, Opus, read-only): verifies the declared invariants source-to-sink over the checkout; authorization / tenant-isolation / business-logic reasoning.
- **attacker-path** (Codex via `.claude/lib/codex-bg.sh`, `CODEX_EFFORT=high`, no `SCHEMA`, read-only sandbox): reads **only** the sanitized context pack built by `audit-runner.mjs pack` in a directory outside the checkout. Its prose must end with a fenced JSON block; malformed or missing JSON → partition `INCOMPLETE reason=malformed-output`.

Neither pass sees the other's findings. Scanner artifacts are quoted data, never independent confirmation. Every agent **returns** JSON; the runner (`ingest-partition`) validates, attests and persists it, recording `result_hash` (the returned bytes) and, for the attacker-path pass, `input_hash` (the pack Codex read, passed as `--input-hash`) plus the pack manifest (`--pack-manifest`, the `pack.json` whose `pack_sha256` must equal `input_hash`). The pack truncates a file over its size cap and marks it `truncated: true`; bytes Codex never saw are not analyzed, so any truncated file makes the partition `INCOMPLETE pack-truncated:<n>` (a coverage gap), and a missing or mismatched manifest is `pack-manifest-missing` / `pack-manifest-mismatch` — an attacker-path partition can be COMPLETE only when the runner has seen the manifest of the exact pack Codex read and nothing in it was cut.

**Detector identity is the runner's.** At ingest the runner overwrites `detector.family` and `detector.tool` on every finding from the partition name (`threat-model` / `control-verifier` → `opus`, `attacker-path` → `codex`, `finding-validator` → `validator`); scanner candidates are built by the runner itself. A prompt-injected pass that writes `family: validator` (verdict precedence in aggregation) or `family: codex` (a second independent confirmation) into its own output gains nothing.

## Phase 5 — Merge and falsifying validation

`@audit-finding-validator` (Opus, read-only, fresh context) receives the merged candidate list written by `audit-runner.mjs candidates` — the two model passes **and** the scanner candidates from `findings/scanner-<class>.json` (Phase 3) — and must try to disprove each; verdicts `confirmed|plausible|disputed|rejected` with reasons. The runner joins each judgment to its candidate through `detector.native_ids` (exactly one known candidate id per judgment; every candidate judged exactly once) and takes only `verdict`, `verdict_reason` and `confidence` from the validator: every fingerprint field is the candidate's own, so a reworded judgment can neither escape its group nor open a new one, and a forged judgment of an id the runner never issued fails the join. An unknown, duplicate or missing id makes the partition `INCOMPLETE malformed-output:validator-join` with zero findings persisted. The runner groups findings by `invariant + root_cause + sink + auth_context + CWE` (content-hash id `f-<16 hex>`); two rules from the same ruleset are one confirmation. A scanner candidate the validator never judged stays `plausible` and never blocks; one it confirms at a blocking severity fails the verdict like any other finding.

## Phase 6 — Rank, outcome, report

`audit-runner.mjs finalize` computes the three-axis outcome and renders `report.md` from `templates/report.md`; the prose sections are left for a bounded report agent, the tables are the runner's. Prose enters the report only through `audit-runner.mjs summary` (executive-summary slot, or `--section` to append), which redacts it and re-indexes `report.md` in the run manifest — a hand edit would leave the recorded sha256 stale.

- **execution**: `ERROR` if any partition errored, else `INCOMPLETE` if any partition is incomplete or was never ingested, else `COMPLETE`.
- **coverage**: per required class `covered|gap`, per partition `covered|gap` (all four partitions always have a row; one that never ran is `gap reason=partition-not-run`), plus `uncovered_units`.
- **verdict**: (1) any blocking finding → `FAIL`; else (2) any gap → `UNKNOWN`; else (3) `PASS`.
- **exit**: `report` mode always 0; `gate` mode 0 only on `PASS` + `COMPLETE`, or with a recorded waiver (`--waiver-file`).

Artifacts live under `.agents/audits/<date>-<time>-<slug>/` (one dir per run, never reused without `--resume`), are written atomically (temp + rename) and indexed with sha256 in the run manifest. The audit never commits them, and the in-host passes that produced them are not read-confined (Host attestation → 6): a human reviews the report before it leaves the machine.
