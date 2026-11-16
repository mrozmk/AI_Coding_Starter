import type { AgentSpawnInput, AgentSpawnResult, Register } from 'claude-code'

export type Alias = 'haiku' | 'sonnet' | 'opus'

// Built-ins whose definition resolves to inherit, read from engine 2.1.322; re-verify on an
// engine update — a later pin on one of these would be overridden (ordered rule 5).
export const INHERIT_BUILTINS: readonly string[] = ['general-purpose', 'claude', 'Explore', 'Plan']
export const DEFAULT_TABLE: Readonly<Record<string, Alias>> = { 'general-purpose': 'opus', claude: 'opus', Explore: 'opus' }
const ALIASES: readonly string[] = ['haiku', 'sonnet', 'opus']
const RANK = { haiku: 1, sonnet: 2, opus: 3, fable: 4, mythos: 4 } as const
const FAMILIES = ['mythos', 'fable', 'opus', 'sonnet', 'haiku'] as const

export type Family = keyof typeof RANK
export type Config = { table: Readonly<Record<string, Alias>> } | null
export type Env = {
  subagentModel?: string
  subagentModelForce?: string
  defaultHaiku?: string
  defaultSonnet?: string
  defaultOpus?: string
}
export type Decision = { model: Alias } | { pass: string }
export type SpawnFacts = Pick<
  AgentSpawnInput,
  'subagentType' | 'provider' | 'model' | 'parentModel' | 'fork' | 'isTeammate' | 'workflow' | 'resume'
>

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)

/** `null` means off: unreadable JSON, no opt-in, or a table that is not an object. */
export function parseConfig(text: string): Config {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObject(raw) || !isObject(raw.workflow)) return null
  const block = raw.workflow.subagent_model
  if (!isObject(block) || block.enabled !== true) return null
  if (!('table' in block)) return { table: DEFAULT_TABLE }
  if (!isObject(block.table)) return null
  const table: Record<string, Alias> = {}
  for (const [type, alias] of Object.entries(block.table)) {
    if (typeof alias === 'string' && ALIASES.includes(alias)) table[type] = alias as Alias
  }
  return { table }
}

export function family(model: string): Family | undefined {
  const m = model.toLowerCase()
  return FAMILIES.find((f) => m.includes(f))
}

export function decide(e: SpawnFacts, config: Config, env: Env): Decision {
  if (config === null) return { pass: 'off' }
  const subagentModel = (env.subagentModel ?? '').trim().toLowerCase()
  if (!['', 'inherit', 'default'].includes(subagentModel) || (env.subagentModelForce ?? '') !== '') {
    return { pass: 'env subagent model' }
  }
  if (e.fork || e.subagentType === 'fork') return { pass: 'fork' }
  if (e.resume) return { pass: 'resume' }
  if (e.isTeammate) return { pass: 'teammate' }
  if (e.workflow) return { pass: 'workflow' }
  if (e.model !== undefined && e.model !== 'inherit') return { pass: 'named model' }
  if (e.provider.plugin !== 'engine') return { pass: 'not engine' }
  if (!INHERIT_BUILTINS.includes(e.subagentType)) return { pass: 'pinned built-in' }
  const row = config.table[e.subagentType]
  if (row === undefined) return { pass: 'not in table' }
  const redirect = { haiku: env.defaultHaiku, sonnet: env.defaultSonnet, opus: env.defaultOpus }[row]
  if ((redirect ?? '') !== '') return { pass: 'alias redirected' }
  const parent = family(e.parentModel)
  if (parent === undefined) return { pass: 'unknown parent family' }
  if (RANK[row] >= RANK[parent]) return { pass: 'not cheaper' }
  return { model: row }
}

/** The session's start directory is not the repository root; git's top level is, worktrees included. */
export function resolveRoot(start: string, exitCode: number, stdout: string): string {
  const top = stdout.trim()
  return exitCode === 0 && top !== '' ? top : start
}

export type Deps = {
  root(): Promise<string>
  read(path: string): Promise<string>
  env(): Promise<Env>
  sessionId(): Promise<string>
  trace(argv: readonly string[], cwd: string): Promise<unknown>
}

export async function onSpawn(
  deps: Deps,
  e: AgentSpawnInput,
  next: (e: AgentSpawnInput) => Promise<AgentSpawnResult>,
): Promise<AgentSpawnResult> {
  let decision: Decision
  let root = ''
  try {
    root = await deps.root()
    const config = parseConfig(await deps.read(`${root}/.claude/project-profile.json`))
    decision = decide(e, config, await deps.env())
  } catch {
    decision = { pass: 'error' }
  }
  if ('pass' in decision) return next(e)
  const result = await next({ ...e, model: decision.model })
  if (result.deny === undefined && result.agentId !== undefined) {
    const model = result.model
    void (async () => {
      const sid = await deps.sessionId()
      await deps.trace(
        [
          'bash', `${root}/.claude/lib/costs/runtime-mark.sh`, 'subagent',
          '--session', sid, '--agent-type', e.subagentType,
          '--parent-model', e.parentModel, '--model', model,
        ],
        root,
      )
    })().catch(() => undefined)
  }
  return result
}

export const register: Register = (on) => {
  on('agent.spawn', ($, e, next) =>
    onSpawn(
      {
        root: async () => {
          const start = await $.session.root()
          const r = await $.process.run(['git', 'rev-parse', '--show-toplevel'], { cwd: start })
          return resolveRoot(start, r.exitCode, r.stdout)
        },
        read: (p) => $.fs.read(p),
        env: async () => {
          const [subagentModel, subagentModelForce, defaultHaiku, defaultSonnet, defaultOpus] = await Promise.all([
            $.env.get('CLAUDE_CODE_SUBAGENT_MODEL'),
            $.env.get('CLAUDE_CODE_SUBAGENT_MODEL_FORCE'),
            $.env.get('ANTHROPIC_DEFAULT_HAIKU_MODEL'),
            $.env.get('ANTHROPIC_DEFAULT_SONNET_MODEL'),
            $.env.get('ANTHROPIC_DEFAULT_OPUS_MODEL'),
          ])
          return { subagentModel, subagentModelForce, defaultHaiku, defaultSonnet, defaultOpus }
        },
        sessionId: () => $.session.id(),
        trace: (argv, cwd) => $.process.run(argv, { cwd }),
      },
      e,
      next,
    ),
  )
    // Replay-safe: after a dispatch `next(e)` returns that result; before it, it runs once.
    .catch((_$, e, next) => next(e))
}
