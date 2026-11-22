export const meta = {
  name: 'map-codebase',
  description: 'Fan-out comprehension of a codebase into an architecture map + a reconstructed PRD draft',
  phases: [
    { title: 'Analyze', detail: 'one module-analyzer sub-agent per module, in parallel — returns distilled summaries with conventions, helpers and problem shapes' },
    { title: 'Synthesize', detail: 'architecture map + reverse-PRD from the summaries; one standards synthesizer drafts docs/coding-standards.md, checked against its observations' },
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
//     toolScan:    object,     // `standards-tools.mjs scan` JSON over the approved file list (optional)
//     root:        string,     // absolute analyzed checkout when it is not the session's cwd (optional);
//                              // file lists stay repo-relative, analyzers cite relative path:line
//   }
// Returns: { architectureBody, prdBody, dataModelBody, hasDataModel, docsAnalysis,
//            infraAnalysis, unanalyzed, analyzed, total, standardsDraft, rejected,
//            writtenNotFollowed, toolsNamedNotPresent, standardsSkipped, standardsInputChars }
//   *Body fields are markdown BODIES — the command persists them (the script has no FS access).
//   docsAnalysis/infraAnalysis are the raw structured objects (or null) — the command routes
//   them to decisions.md / patterns.md / architecture.md.
//   standardsDraft is the checked draft (every kept item carries support [{ module, ref }]) the
//   command hands to coding-standards-render.mjs, or null; rejected lists what the check removed.
// ---------------------------------------------------------------------------

const PROBLEMS = ['config/feature flag', 'error handling and error bodies', 'logging', 'date/time', 'async/cancellation', 'data access', 'retry', 'loading state']
const EVIDENCE = { type: 'array', minItems: 1, items: { type: 'string' }, description: 'repo-relative "path:line" refs from files you read' }
const CONSISTENCY = { type: 'string', enum: ['consistent', 'mixed'] }
const obj = (properties) => ({ type: 'object', additionalProperties: false, required: Object.keys(properties), properties })
const str = { type: 'string' }
const VARIANTS = { type: 'array', description: 'each competing way with one path:line (empty when consistent)', items: obj({ shape: str, evidence: str }) }

const MODULE_SUMMARY = {
  type: 'object',
  additionalProperties: false,
  required: ['module', 'purpose', 'keyFiles', 'publicAPI', 'deps', 'domainConcepts', 'dataModel', 'externalIntegrations', 'serviceInterface', 'conventions', 'helpersDefined', 'helpersUsed', 'problemShapes'],
  properties: {
    conventions: { type: 'array', maxItems: 8, description: 'rules this module\'s code follows', items: obj({ rule: str, appliesTo: str, consistency: CONSISTENCY, evidence: EVIDENCE, variants: VARIANTS }) },
    helpersDefined: { type: 'array', maxItems: 8, description: 'helpers defined here that other modules use or should use', items: obj({ need: str, symbol: str, at: str }) },
    helpersUsed: { type: 'array', maxItems: 8, description: 'helpers of OTHER modules called here', items: obj({ symbol: str, definedIn: str, at: str }) },
    problemShapes: { type: 'array', maxItems: 8, description: 'the shape used for each of the fixed problems that occur here',
      items: obj({ problem: { type: 'string', enum: PROBLEMS }, shape: str, consistency: CONSISTENCY, evidence: EVIDENCE, variants: VARIANTS }) },
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
  required: ['documentedDecisions', 'documentedPatterns', 'whyContext', 'namedTools'],
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
        required: ['name', 'description', 'source', 'kind'],
        properties: {
          name: { type: 'string' },
          description: { type: 'string' },
          source: { type: 'string' },
          kind: { type: 'string', enum: ['rule', 'trap', 'note'], description: 'rule = a reviewer may reject a change for it; trap/note = helps writing, no ground for rejection' },
        },
      },
    },
    whyContext: {
      type: 'string',
      description: 'Product/business intent and rationale gleaned from README/docs — the "why" code cannot show; feeds the reverse-PRD',
    },
    namedTools: { type: 'array', description: 'every lint/format/analyzer tool a doc names', items: obj({ tool: str, source: str }) },
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

// `args` has been observed arriving as a JSON *string* (verified on a 150-byte payload, so not a
// size limit). Parse ONLY in that case; a genuine syntax error still throws instead of degrading
// to `{}`. If the harness delivers a structured value this is a no-op.
const rawArgs = typeof args === 'string' ? JSON.parse(args) : args

const modules = Array.isArray(rawArgs && rawArgs.modules) ? rawArgs.modules : []
const docFiles = Array.isArray(rawArgs && rawArgs.docFiles) ? rawArgs.docFiles : []
const infraFiles = Array.isArray(rawArgs && rawArgs.infraFiles) ? rawArgs.infraFiles : []
const today = (rawArgs && rawArgs.today) || 'unknown-date'
const projectName = (rawArgs && rawArgs.projectName) || 'this project'
// Grounding context (UA practice): inject README head + detected entry point into
// every analyzer so module summaries align with the project's own narrative.
const readmeHead = (rawArgs && rawArgs.readmeHead) || ''
const entryPoint = (rawArgs && rawArgs.entryPoint) || ''
const hasToolScan = !!(rawArgs && rawArgs.toolScan)
const toolScan = hasToolScan ? rawArgs.toolScan : { tools: [], unparsed: [], unattributed: [], ignored: [] }
const root = (rawArgs && rawArgs.root) || ''
const citeNote = root
  ? `Files are relative to \`${root}\`: read \`${root}/<path>\`, cite \`<path>:<line>\` (relative, never absolute).`
  : 'Cite repo-relative `path:line` (never absolute).'

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
    standardsDraft: null,
    rejected: [],
    writtenNotFollowed: [],
    toolsNamedNotPresent: [],
    standardsSkipped: '',
    standardsInputChars: 0,
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
${citeNote}

Extract:
- purpose: what this module is responsible for (1-3 sentences)
- keyFiles: the most important files, each with a one-line role
- publicAPI: exported functions/classes/endpoints other modules consume
- deps: other modules and external libraries this module relies on
- domainConcepts: business/domain concepts you can infer (name + short description) — these feed a reconstructed PRD
- dataModel: if this module defines DB tables / ORM models / a schema, list each entity with its source file, key fields (note types, PK, FK, unique), and relations. READ consolidated schema/model files (e.g. \`schema.prisma\`, \`db/schema.rb\`, Django/SQLAlchemy/TypeORM/Ent models) — do NOT trawl migration history. Return an empty array if the module has no persistence.
- externalIntegrations: third-party systems this module connects to (payment, CRM, email, storage, auth, analytics, queues, etc.) — detect via SDK/client imports, env vars (API keys/URLs), endpoint calls, webhook handlers. Give system, purpose, direction, and the evidence (+ file). Empty array if none.
- serviceInterface: set isService=true if this module is an independently deployable service (own manifest/Dockerfile/entrypoint), and in 'communicates' list how it talks to OTHER internal services (protocol + target, e.g. "HTTP->auth-service", "consumes orders queue"). For a plain monolith module, isService=false and communicates=[].
- conventions (max 8): rules this module's code follows — \`consistent\` when every place follows it, \`mixed\` when it follows competing ways (list each variant with one path:line). Evidence is \`path:line\` from files you read, line numbers as the Read tool shows them; name a code shape by its identifier in backticks.
- helpersDefined (max 8): helpers defined here that other modules use or should use — need, symbol, at (path:line of the definition).
- helpersUsed (max 8): helpers of OTHER modules this module calls — symbol, definedIn (the defining file, repo-relative), at (the call site in this module).
- problemShapes (max 8): only those of these problems that occur here — ${PROBLEMS.join('; ')} — with the shape used (its code identifier in backticks), consistency, evidence and variants as for conventions.

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
(2) documentedPatterns — conventions/standards a contributor must follow (name, description, source, kind): kind \`rule\` when a reviewer may reject a change for it, \`trap\` or \`note\` when it helps writing code but is no ground for rejection;
(3) whyContext — the product/business intent and rationale (the "why") that code cannot reveal;
(4) namedTools — every lint/format/analyzer tool a doc names (tool, source).
Use ONLY these files; do not read source. ${citeNote}

Files:
${docFiles.map((f) => `- ${f}`).join('\n')}`

const infraPromptText =
  `You are an infra-analyzer. Read ONLY these infrastructure-as-code / CI files and extract: hosting (where/how it runs), environments, deployables, externalServices (managed DBs/queues/caches/buckets/third parties), and infraNotes (CI/CD, networking, scaling, secrets). Use ONLY these files; do not read source. ${citeNote}

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

// Observation ids feed the standards synthesizer only; the three old synthesizers get base summaries.
const NEW_KEYS = { conventions: 'c', helpersDefined: 'hd', helpersUsed: 'hu', problemShapes: 's' }
const obs = new Map()
const standardsInput = []
summaries.forEach((s, i) => {
  if (!s) return
  const m = modules[i]
  const entry = { module: m.name, importedBy: m.importedBy || [] }
  for (const [k, tag] of Object.entries(NEW_KEYS)) {
    entry[k] = (Array.isArray(s[k]) ? s[k] : []).map((item, n) => {
      const id = `${m.name}#${tag}${n + 1}`
      obs.set(id, { id, module: m.name, kind: k, item })
      return { id, ...item }
    })
  }
  standardsInput.push(entry)
})
const baseSummaries = ok.map((s) => Object.fromEntries(Object.entries(s).filter(([k]) => !(k in NEW_KEYS))))
const summariesJson = JSON.stringify(baseSummaries, null, 2)

const docRules = (docsAnalysis && Array.isArray(docsAnalysis.documentedPatterns) ? docsAnalysis.documentedPatterns : [])
  .filter((p) => p.kind === 'rule')
  .map((p, n) => ({ id: `doc#r${n + 1}`, rule: p.name, description: p.description, source: p.source }))
const toolFacts = (toolScan.tools || []).map((t) => ({
  tool: t.tool,
  enforced: !!t.enforced,
  appliesTo: t.appliesTo || [],
  rules: (t.configs || []).filter((c) => c.attributed).flatMap((c) => (c.rules || []).filter((r) => !(c.notEnforced || []).includes(r.rule)).map((r) => r.rule)),
}))

const STANDARDS_DRAFT = obj({
  rules: { type: 'array', items: obj({ rule: str, appliesTo: str, example: str, why: str, observations: { type: 'array', items: str }, documentedIds: { type: 'array', items: str } }) },
  helpers: { type: 'array', items: obj({ need: str, use: str, path: str, observations: { type: 'array', items: str } }) },
  shapes: { type: 'array', items: obj({ problem: str, shape: str, reference: str, observations: { type: 'array', items: str } }) },
  open: { type: 'array', items: obj({ topic: str, variants: { type: 'array', items: obj({ shape: str, evidence: str, observation: str }) } }) },
  writtenNotFollowed: { type: 'array', items: obj({ id: str, rule: str, source: str, reason: { type: 'string', enum: ['mixed', 'contrary', 'no evidence', 'not assessed'] }, evidence: str }) },
})

const standardsPrompt = (input) =>
  `You are a standards-synthesizer. From the per-module observations below (JSON, each with an id), the scanned tool facts and the documented rules, draft the content of \`docs/coding-standards.md\` for its four sections, in this order: \`## Rules\`, \`## Shared helpers\`, \`## One shape per problem\`, \`## Open — pick one\`. Use ONLY this input — do NOT read source.

- Rules: a convention \`consistent\` in at least two modules → a review rule (rule, appliesTo, example, why), unless an enforced scanned tool rule already covers it across its modules — then skip it (the tool rule is written separately). Never claim a tool and never write a "passes <tool>" rule. Never turn a size or length limit from CLAUDE.md's Code Structure & Modularity into a rule.
- Shared helpers: a helper used from at least two other modules → a row (need, use, path = its helpersDefined \`at\`).
- One shape per problem: one shape for a problem in at least two modules → a row (problem, shape, reference).
- Open — pick one: a convention or shape that is \`mixed\`, or differs between modules → an open item with each variant (shape, evidence, observation), never a rule.
- Every item lists the observation ids it rests on and cites a \`path:line\` taken from those observations' evidence.
- Documented rules: a rule you write that a documented rule states carries its id in documentedIds; a documented rule the observations contradict, show mixed or do not show → writtenNotFollowed (id, rule, source, reason, evidence — a path:line or "").
- Stay within ~200 rendered lines.

Documented rules:
${JSON.stringify(docRules, null, 2)}

Scanned tool facts:
${JSON.stringify(toolFacts, null, 2)}

Observations:
${JSON.stringify(input, null, 2)}`

const STANDARDS_INPUT_BUDGET = 200000
const sizeOf = (input) => JSON.stringify(input).length + JSON.stringify(toolFacts).length + JSON.stringify(docRules).length
let synthInput = standardsInput
let standardsInputChars = sizeOf(synthInput)
if (standardsInputChars > STANDARDS_INPUT_BUDGET) {
  // Deterministic first cut: a defined helper no other module uses cannot become a helper row.
  const usedElsewhere = (e, h) => standardsInput.some((o) => o.module !== e.module && o.helpersUsed.some((u) => u.symbol === h.symbol))
  synthInput = standardsInput.map((e) => ({ ...e, helpersDefined: e.helpersDefined.filter((h) => usedElsewhere(e, h)) }))
  for (const e of standardsInput) for (const h of e.helpersDefined) if (!usedElsewhere(e, h)) obs.delete(h.id)
  standardsInputChars = sizeOf(synthInput)
}
const overBudget = standardsInputChars > STANDARDS_INPUT_BUDGET
const runStandards = obs.size > 0 && !overBudget
if (overBudget) log(`standards synthesis skipped: input ${standardsInputChars} chars over ${STANDARDS_INPUT_BUDGET}`)

const fileOfRef = (ref) => String(ref).replace(/:\d+(-\d+)?$/, '')
const identifiers = (s) => new Set([...String(s || '').matchAll(/`([^`]+)`/g)].map((m) => (/^[A-Za-z_$][\w$.]*/.exec(m[1].trim()) || [''])[0]).filter(Boolean))
const list = (a) => (Array.isArray(a) ? a : [])

// Every kept item must rest on observations: module binding, two modules, the cited ref among their
// evidence; support [{ module, ref }] is what the renderer re-checks on disk.
function checkDraft(draft, obsMap, mods) {
  const filesOf = new Map(mods.map((m) => [m.name, new Set(m.files || [])]))
  const refsOf = (o) => (o.kind === 'helpersDefined' || o.kind === 'helpersUsed' ? [o.item.at] : [...list(o.item.evidence), ...list(o.item.variants).map((v) => v.evidence)])
  const counting = (o) => refsOf(o).filter((r) => typeof r === 'string' && (filesOf.get(o.module) || new Set()).has(fileOfRef(r)))
  const support = (os) => os.flatMap((o) => counting(o).map((ref) => ({ module: o.module, ref })))
  const modulesOf = (os) => new Set(os.map((o) => o.module)).size
  const rejected = []
  const kept = { rules: [], helpers: [], shapes: [], open: [] }
  const reject = (section, item, reason) => rejected.push({ section, item: item.rule || item.need || item.problem || item.topic || '', reason })
  const cited = (item, section) => {
    const ids = list(item.observations)
    const unknown = ids.filter((id) => !obsMap.has(id))
    if (!ids.length || unknown.length) { reject(section, item, `unknown observations: ${unknown.join(', ') || 'none cited'}`); return null }
    return { ids, usable: ids.map((id) => obsMap.get(id)).filter((o) => counting(o).length) }
  }
  for (const r of list(draft.rules)) {
    const c = cited(r, 'rules')
    if (!c) continue
    if (c.usable.some((o) => o.kind !== 'conventions' || o.item.consistency !== 'consistent')) reject('rules', r, 'not a consistent convention')
    else if (modulesOf(c.usable) < 2) reject('rules', r, 'fewer than two modules')
    else if (!c.usable.some((o) => counting(o).includes(r.example))) reject('rules', r, 'example not in its observations')
    else kept.rules.push({ ...r, support: support(c.usable) })
  }
  for (const x of list(draft.shapes)) {
    const c = cited(x, 'shapes')
    if (!c) continue
    const problems = new Set(c.ids.map((id) => obsMap.get(id)).filter((o) => o.kind === 'problemShapes').map((o) => o.item.problem))
    const dissent = [...obsMap.values()].filter((o) => o.kind === 'problemShapes' && problems.has(o.item.problem) && (!c.ids.includes(o.id) || o.item.consistency !== 'consistent')).map((o) => o.id)
    const common = c.usable.reduce((acc, o) => new Set([...acc].filter((n) => identifiers(o.item.shape).has(n))), identifiers(x.shape))
    if (c.usable.some((o) => o.kind !== 'problemShapes')) reject('shapes', x, 'not a shape observation')
    else if (dissent.length) reject('shapes', x, `dissent: ${dissent.join(', ')}`)
    else if (modulesOf(c.usable) < 2) reject('shapes', x, 'fewer than two modules')
    else if (!c.usable.some((o) => counting(o).includes(x.reference))) reject('shapes', x, 'reference not in its observations')
    else if (!common.size) reject('shapes', x, 'shapes disagree')
    else kept.shapes.push({ ...x, support: support(c.usable) })
  }
  for (const h of list(draft.helpers)) {
    const c = cited(h, 'helpers')
    if (!c) continue
    const def = c.usable.find((o) => o.kind === 'helpersDefined' && o.item.at === h.path)
    const users = def ? c.usable.filter((o) => o.kind === 'helpersUsed' && o.module !== def.module && o.item.symbol === def.item.symbol && o.item.definedIn === fileOfRef(def.item.at)) : []
    if (!def) reject('helpers', h, 'no definition at its path')
    else if (modulesOf(users) < 2) reject('helpers', h, 'used by fewer than two other modules')
    else kept.helpers.push({ ...h, support: [{ module: def.module, ref: def.item.at }, ...users.map((u) => ({ module: u.module, ref: u.item.at }))] })
  }
  for (const o of list(draft.open)) {
    const fine = list(o.variants).length >= 2 && list(o.variants).every((v) => obsMap.has(v.observation) && refsOf(obsMap.get(v.observation)).includes(v.evidence))
    if (fine) kept.open.push(o)
    else reject('open', o, 'a variant does not rest on its observation')
  }
  return { kept, rejected }
}
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

const [architectureBody, prdBody, dataModelBody, rawDraft] = await parallel([
  () => agent(architecturePrompt, { label: 'synthesize:architecture', phase: 'Synthesize' }),
  () => agent(prdPrompt, { label: 'synthesize:reverse-prd', phase: 'Synthesize' }),
  () => (hasDataModel ? agent(dataModelPrompt, { label: 'synthesize:data-model', phase: 'Synthesize' }) : Promise.resolve('')),
  () => (runStandards ? agent(standardsPrompt(synthInput), { label: 'synthesize:coding-standards', phase: 'Synthesize', schema: STANDARDS_DRAFT }) : Promise.resolve(null)),
])

let [standardsDraft, rejected, writtenNotFollowed] = [null, [], []]
let standardsSkipped = overBudget ? 'input over budget' : ''
const unassessed = (reason) => docRules.map((d) => ({ id: d.id, rule: d.rule, source: d.source, reason, evidence: '' }))
if (rawDraft && typeof rawDraft === 'object') {
  const checked = checkDraft(rawDraft, obs, modules)
  rejected = checked.rejected
  const named = new Set([...checked.kept.rules.flatMap((r) => list(r.documentedIds)), ...list(rawDraft.writtenNotFollowed).map((w) => w && w.id)])
  writtenNotFollowed = [...list(rawDraft.writtenNotFollowed).filter((w) => w && typeof w === 'object'), ...unassessed('not assessed').filter((d) => !named.has(d.id))]
  standardsDraft = { ...checked.kept, writtenNotFollowed }
} else if (runStandards) {
  standardsSkipped = 'synthesis returned nothing'
  writtenNotFollowed = unassessed('not assessed')
} else if (!overBudget) {
  writtenNotFollowed = unassessed('no evidence')
}
if (rejected.length) log(`standards draft: ${rejected.length} item(s) rejected by the observation check`)

const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '')
const present = new Set((toolScan.observed || []).map(norm))
const toolsNamedNotPresent = hasToolScan
  ? list(docsAnalysis && docsAnalysis.namedTools).filter((t) => t && !present.has(norm(t.tool))).map((t) => ({ tool: t.tool, source: t.source }))
  : []

return {
  standardsDraft,
  rejected,
  writtenNotFollowed,
  toolsNamedNotPresent,
  standardsSkipped,
  standardsInputChars,
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
