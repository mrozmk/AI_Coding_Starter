export const meta = {
  name: 'map-codebase',
  description: 'Fan-out comprehension of a codebase into an architecture map + a reconstructed PRD draft',
  phases: [
    { title: 'Analyze', detail: 'one module-analyzer sub-agent per module, in parallel — returns distilled summaries' },
    { title: 'Synthesize', detail: 'architecture map + reverse-PRD, synthesized ONLY from the summaries' },
  ],
}

// ---------------------------------------------------------------------------
// args contract — injected by /setup:map-codebase after its Phase-0 scan +
// Checkpoint 1 (the script never scans the filesystem itself):
//   args = {
//     modules:     [{ name, files: string[], imports: string[], importedBy: string[], isCore: bool }],
//                  // approved partition; files pre-capped; imports/importedBy/isCore = coarse import-graph signal
//     docFiles:    string[],   // README/docs/ADRs for the docs-analyzer (the "why")
//     infraFiles:  string[],   // IaC/CI files for the infra-analyzer
//     readmeHead:  string,     // first ~3000 chars of README — grounding for every analyzer
//     entryPoint:  string,     // detected entry point, or ''
//     today:       'YYYY-MM-DD',  // injected (Date.now()/new Date() are unavailable here)
//     projectName: string,
//   }
// Returns: { architectureBody, prdBody, dataModelBody, hasDataModel, docsAnalysis,
//            infraAnalysis, unanalyzed, analyzed, total }
//   *Body fields are markdown BODIES — the command persists them (the script has no FS access).
//   docsAnalysis/infraAnalysis are the raw structured objects (or null) — the command routes
//   them to decisions.md / patterns.md / architecture.md.
// ---------------------------------------------------------------------------

const MODULE_SUMMARY = {
  type: 'object',
  additionalProperties: false,
  required: ['module', 'purpose', 'keyFiles', 'publicAPI', 'deps', 'domainConcepts', 'dataModel', 'externalIntegrations', 'serviceInterface'],
  properties: {
    module: { type: 'string', description: 'Module name / path' },
    purpose: { type: 'string', description: 'What this module is responsible for (1-3 sentences)' },
    keyFiles: {
      type: 'array',
      description: 'Most important files with a one-line role each',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['path', 'role'],
        properties: { path: { type: 'string' }, role: { type: 'string' } },
      },
    },
    publicAPI: {
      type: 'array',
      items: { type: 'string' },
      description: 'Exported functions/classes/endpoints other modules consume',
    },
    deps: {
      type: 'array',
      items: { type: 'string' },
      description: 'Other modules and external libraries this module relies on',
    },
    domainConcepts: {
      type: 'array',
      description: 'Business/domain concepts inferred from this module (feeds the reverse-PRD)',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'description'],
        properties: { name: { type: 'string' }, description: { type: 'string' } },
      },
    },
    dataModel: {
      type: 'array',
      description: 'DB/persistence entities defined in this module (tables/ORM models). Empty array if the module has no persistence.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'source', 'fields', 'relations'],
        properties: {
          name: { type: 'string', description: 'table / model / entity name' },
          source: { type: 'string', description: 'file that defines it' },
          fields: {
            type: 'array',
            items: { type: 'string' },
            description: 'key fields with type/markers, e.g. "id: uuid PK", "user_id: FK->users", "email: string unique"',
          },
          relations: {
            type: 'array',
            items: { type: 'string' },
            description: 'relations to other entities, e.g. "belongs_to user", "has_many orders"',
          },
        },
      },
    },
    externalIntegrations: {
      type: 'array',
      description: 'Third-party/external systems this module talks to (payment, CRM, email, storage, auth, analytics, queues, other). Empty array if none.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['system', 'purpose', 'direction', 'evidence'],
        properties: {
          system: { type: 'string', description: 'e.g. Stripe, HubSpot, SendGrid, S3, Auth0' },
          purpose: { type: 'string', description: 'what it is used for, e.g. payments, CRM sync, transactional email' },
          direction: { type: 'string', description: 'outbound | inbound | bidirectional' },
          evidence: { type: 'string', description: 'how detected: SDK/client, env var, endpoint, webhook handler + file' },
        },
      },
    },
    serviceInterface: {
      type: 'object',
      additionalProperties: false,
      required: ['isService', 'communicates'],
      properties: {
        isService: {
          type: 'boolean',
          description: 'true if this module is an independently deployable service (its own manifest / Dockerfile / entrypoint)',
        },
        communicates: {
          type: 'array',
          items: { type: 'string' },
          description: 'how it talks to OTHER internal services, e.g. "HTTP->auth-service", "consumes orders queue (RabbitMQ)", "gRPC<-gateway". Empty for a monolith module.',
        },
      },
    },
  },
}

// Docs / ADRs (the "why" code cannot show) — one agent over the discovered doc files.
const DOCS_ANALYSIS = {
  type: 'object',
  additionalProperties: false,
  required: ['documentedDecisions', 'documentedPatterns', 'whyContext'],
  properties: {
    documentedDecisions: {
      type: 'array',
      description: 'Architecture decisions / ADRs found in docs',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'rationale', 'source'],
        properties: {
          title: { type: 'string' },
          rationale: { type: 'string', description: 'why chosen; note alternatives & consequences if stated' },
          source: { type: 'string', description: 'file path' },
        },
      },
    },
    documentedPatterns: {
      type: 'array',
      description: 'Conventions/standards a contributor must follow, from CONTRIBUTING/design docs',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'description', 'source'],
        properties: { name: { type: 'string' }, description: { type: 'string' }, source: { type: 'string' } },
      },
    },
    whyContext: {
      type: 'string',
      description: 'Product/business intent and rationale gleaned from README/docs — the "why" code cannot show; feeds the reverse-PRD',
    },
  },
}

// Infrastructure-as-code / CI — one agent over the discovered infra files.
const INFRA_ANALYSIS = {
  type: 'object',
  additionalProperties: false,
  required: ['hosting', 'environments', 'deployables', 'externalServices', 'infraNotes'],
  properties: {
    hosting: { type: 'string', description: 'where/how it runs: cloud provider, k8s, serverless, VMs' },
    environments: { type: 'array', items: { type: 'string' }, description: 'envs defined (dev/staging/prod...)' },
    deployables: { type: 'array', items: { type: 'string' }, description: 'deployable units from IaC (services, functions, containers)' },
    externalServices: {
      type: 'array',
      description: 'managed/external services from IaC: DBs, queues, caches, buckets, third parties',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['system', 'purpose'],
        properties: { system: { type: 'string' }, purpose: { type: 'string' } },
      },
    },
    infraNotes: { type: 'array', items: { type: 'string' }, description: 'CI/CD, networking, scaling, secrets management — non-obvious infra facts' },
  },
}

const modules = Array.isArray(args && args.modules) ? args.modules : []
const docFiles = Array.isArray(args && args.docFiles) ? args.docFiles : []
const infraFiles = Array.isArray(args && args.infraFiles) ? args.infraFiles : []
const today = (args && args.today) || 'unknown-date'
const projectName = (args && args.projectName) || 'this project'
// Grounding context (UA practice): inject README head + detected entry point into
// every analyzer so module summaries align with the project's own narrative.
const readmeHead = (args && args.readmeHead) || ''
const entryPoint = (args && args.entryPoint) || ''

if (modules.length === 0) {
  return {
    architectureBody: '',
    prdBody: '',
    dataModelBody: '',
    hasDataModel: false,
    docsAnalysis: null,
    infraAnalysis: null,
    unanalyzed: [],
    analyzed: 0,
    total: 0,
    error: 'No modules passed in args.modules — run the /setup:map-codebase Phase-0 scan + Checkpoint 1 first.',
  }
}

// ---- Phase 1: fan-out analysis (distilled summaries only, never raw code) ----
phase('Analyze')
log(`Analyzing ${modules.length} module(s) — only ~1-2k summaries reach the aggregator, never source`)

const analyzerPrompt = (m) =>
  `You are a module-analyzer. Analyze EXACTLY this one module and return ONLY the structured summary — never raw source code.

Project: ${projectName}${entryPoint ? ` (entry point: ${entryPoint})` : ''}
${readmeHead ? `Project README (head, for grounding — align your summary with how the project describes itself):\n"""\n${readmeHead}\n"""\n` : ''}
Module: ${m.name}
Dependency context (coupling signal — use it to describe this module's ROLE in the system, do NOT read these neighbors' files):
- this module imports: ${(m.imports && m.imports.length) ? m.imports.join(', ') : '(none detected)'}
- imported by: ${(m.importedBy && m.importedBy.length) ? m.importedBy.join(', ') : '(none detected)'}${m.isCore ? '\n- NOTE: high in-degree — this is a CORE/hub module; describe its public contract carefully.' : ''}

Files to read (read ONLY these — they are already filtered to high-signal files):
${(m.files || []).map((f) => `- ${f}`).join('\n')}

Extract:
- purpose: what this module is responsible for (1-3 sentences)
- keyFiles: the most important files, each with a one-line role
- publicAPI: exported functions/classes/endpoints other modules consume
- deps: other modules and external libraries this module relies on
- domainConcepts: business/domain concepts you can infer (name + short description) — these feed a reconstructed PRD
- dataModel: if this module defines DB tables / ORM models / a schema, list each entity with its source file, key fields (note types, PK, FK, unique), and relations. READ consolidated schema/model files (e.g. \`schema.prisma\`, \`db/schema.rb\`, Django/SQLAlchemy/TypeORM/Ent models) — do NOT trawl migration history. Return an empty array if the module has no persistence.
- externalIntegrations: third-party systems this module connects to (payment, CRM, email, storage, auth, analytics, queues, etc.) — detect via SDK/client imports, env vars (API keys/URLs), endpoint calls, webhook handlers. Give system, purpose, direction, and the evidence (+ file). Empty array if none.
- serviceInterface: set isService=true if this module is an independently deployable service (own manifest/Dockerfile/entrypoint), and in 'communicates' list how it talks to OTHER internal services (protocol + target, e.g. "HTTP->auth-service", "consumes orders queue"). For a plain monolith module, isService=false and communicates=[].

If the module has more files than is reasonable to read, read the highest-signal ones (entry points, configs, route/controller/model definitions, files with the most imports) and note the remainder as not-read. Keep the whole summary compact (~1-2k). Do NOT include source code in the output.`

const summaries = await parallel(
  modules.map((m) => () =>
    agent(analyzerPrompt(m), { label: `analyze:${m.name}`, phase: 'Analyze', schema: MODULE_SUMMARY }),
  ),
)

const ok = summaries.filter(Boolean)
const unanalyzed = modules.filter((_m, i) => !summaries[i]).map((m) => m.name)
if (unanalyzed.length) log(`⚠️ ${unanalyzed.length} module(s) returned no summary: ${unanalyzed.join(', ')}`)
log(`Got ${ok.length}/${modules.length} module summaries`)

// Docs/ADRs (the "why") + infrastructure-as-code, in parallel — bounded file sets, one agent each.
const docsPromptText =
  `You are a docs-analyzer. Read ONLY these documentation files and extract:
(1) documentedDecisions — architecture decisions / ADRs (title; rationale incl. alternatives & consequences if stated; source file);
(2) documentedPatterns — conventions/standards a contributor must follow (name, description, source);
(3) whyContext — the product/business intent and rationale (the "why") that code cannot reveal.
Use ONLY these files; do not read source.

Files:
${docFiles.map((f) => `- ${f}`).join('\n')}`

const infraPromptText =
  `You are an infra-analyzer. Read ONLY these infrastructure-as-code / CI files and extract: hosting (where/how it runs), environments, deployables, externalServices (managed DBs/queues/caches/buckets/third parties), and infraNotes (CI/CD, networking, scaling, secrets). Use ONLY these files; do not read source.

Files:
${infraFiles.map((f) => `- ${f}`).join('\n')}`

const [docsAnalysis, infraAnalysis] = await parallel([
  () => (docFiles.length ? agent(docsPromptText, { label: 'analyze:docs', phase: 'Analyze', schema: DOCS_ANALYSIS }) : Promise.resolve(null)),
  () => (infraFiles.length ? agent(infraPromptText, { label: 'analyze:infra', phase: 'Analyze', schema: INFRA_ANALYSIS }) : Promise.resolve(null)),
])
if (docsAnalysis) log(`docs: ${docsAnalysis.documentedDecisions.length} decisions, ${docsAnalysis.documentedPatterns.length} patterns`)
if (infraAnalysis) log(`infra: ${infraAnalysis.deployables.length} deployables, ${infraAnalysis.externalServices.length} external services`)

// ---- Phase 2: synthesis — works ONLY from the summaries, never re-reads source ----
phase('Synthesize')

const summariesJson = JSON.stringify(ok, null, 2)
const infraJson = infraAnalysis ? JSON.stringify(infraAnalysis, null, 2) : 'none detected'
const whyContext = docsAnalysis && docsAnalysis.whyContext ? docsAnalysis.whyContext : ''

const architecturePrompt =
  `You are an architecture-synthesizer. Below are distilled per-module summaries of a codebase (JSON). Using ONLY these summaries — do NOT read any source files — write the BODY of an \`architecture.md\` memory file.

Output EXACTLY these sections, matching the project's convention:

## Source layout
\`\`\`
<directory tree assembled from the module paths, 1-2 levels deep>
\`\`\`

## Module roles
| Path | Responsibility |
|------|---------------|
<one row per module, derived from its purpose>

## Topology
<Classify the deployment shape — Monolith / Modular monolith / Microservices / Hybrid — based on how many modules have serviceInterface.isService=true and on separate manifests/entrypoints. State the reasoning and list the deployable units. Mark as inferred.>

## Service & Integration Map
<A Mermaid \`flowchart LR\` showing internal services (serviceInterface) as nodes with their communication edges (from \`communicates\`, labelled with the protocol), and external systems (from externalIntegrations) as distinct nodes with directed edges labelled by purpose. For a monolith, show the app as one node plus its external integrations. Mark the diagram "inferred from code — verify".>

\`\`\`mermaid
flowchart LR
  <nodes and edges>
\`\`\`

**External integrations**
| System | Purpose | Direction | Wired in |
|--------|---------|-----------|----------|
<one row per distinct external system, deduplicated across modules; from externalIntegrations>

## Infrastructure
<From the infrastructure analysis below (if present): hosting/platform, environments, deployable units, managed/external services (DBs, queues, caches, buckets), and notable CI/CD or networking facts. Fold IaC-confirmed external services into the Service & Integration Map above. If no infrastructure analysis is present, write "No infrastructure-as-code detected in the repository.">

## Naming rules
- <file / symbol / test naming conventions inferred across modules>

## Critical conventions
- <non-obvious rules that affect WHERE new code goes, inferred from deps / publicAPI / layering>

Detect architectural layers (API / service / data / UI / util) from the dependency relationships and reflect them in Module roles. If there are no external integrations and no internal services (plain monolith, no third parties), keep the Map section but say so explicitly rather than inventing edges. Be concrete; never fabricate a service or integration not present in the summaries. Output ONLY the markdown body — no frontmatter (the command adds it). Start your response IMMEDIATELY with the \`## Source layout\` heading — no preamble, no "I'll synthesize…" or "Let me…" sentence before it.

Infrastructure analysis (for Topology / Map / Infrastructure sections):
${infraJson}

Module summaries:
${summariesJson}`

const prdPrompt =
  `You are a reverse-prd-writer. Below are distilled per-module summaries (JSON); focus on their domainConcepts. Reconstruct a Product Requirements Document for "${projectName}" purely by INFERENCE from the code — code shows WHAT exists, not WHY. Do NOT read source files.

Begin the document with this EXACT banner line:

> **Reconstructed from code on ${today} — REQUIRES HUMAN VALIDATION.** Inferred from implementation, not from product intent. Verify every section before relying on it.

Then write a PRD with these sections; after each section heading append a confidence tag \`(confidence: high|medium|low)\`:
- Product Overview
- Target Users (inferred)
- Core Features / Capabilities (from domain concepts + public APIs)
- Domain Model (key entities and relationships)
- Main Flows (inferred end-to-end flows)
- Out of Scope / Unknowns (what code cannot reveal — the "why", priorities, non-functional intent)

Be explicit about uncertainty; prefer "appears to / likely" over assertions. Output ONLY the markdown body. Start your response IMMEDIATELY with the exact banner line above — no preamble, no "I'll…" or "Let me…" sentence before it.

Documented intent (the "why" extracted from the repo's docs/ADRs — use it to RAISE confidence and fill the "why" the code cannot show; if empty, rely on inference):
${whyContext || 'none found'}

Module summaries:
${summariesJson}`

const hasDataModel = ok.some((s) => Array.isArray(s.dataModel) && s.dataModel.length > 0)

const dataModelPrompt =
  `You are a data-model synthesizer. Below are per-module summaries (JSON); use their \`dataModel\` arrays. Consolidate them into the BODY of a \`.agents/memory/domain/data-model.md\` file describing the project's persistence layer. Use ONLY the summaries — do NOT read source.

Output EXACTLY these sections:

## Entities
| Entity | Source | Key fields | Relations |
|--------|--------|-----------|-----------|
<one row per table/model, DEDUPLICATED across modules>

## Relationships
- <foreign keys / associations between entities, in plain text>

## Notes
- <ORM/DB technology if evident; conventions (naming, soft-delete, timestamps, multi-tenancy); anything non-obvious about the schema>

Deduplicate entities that appear in multiple modules. Output ONLY the markdown body — no frontmatter (the command adds it). Start your response IMMEDIATELY with the \`## Entities\` heading — no preamble, no "I'll…" or "Let me…" sentence before it.

Module summaries:
${summariesJson}`

const [architectureBody, prdBody, dataModelBody] = await parallel([
  () => agent(architecturePrompt, { label: 'synthesize:architecture', phase: 'Synthesize' }),
  () => agent(prdPrompt, { label: 'synthesize:reverse-prd', phase: 'Synthesize' }),
  () => (hasDataModel ? agent(dataModelPrompt, { label: 'synthesize:data-model', phase: 'Synthesize' }) : Promise.resolve('')),
])

return {
  architectureBody: architectureBody || '',
  prdBody: prdBody || '',
  dataModelBody: dataModelBody || '',
  hasDataModel,
  docsAnalysis: docsAnalysis || null,
  infraAnalysis: infraAnalysis || null,
  unanalyzed,
  analyzed: ok.length,
  total: modules.length,
}
