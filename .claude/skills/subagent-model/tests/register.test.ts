import { expect, test } from 'claude-code/testing'
import type { AgentSpawnInput, AgentSpawnResult } from 'claude-code'

import { DEFAULT_TABLE, type Deps, decide, family, findRoot, onSpawn, parseConfig, resolveRoot } from '../hooks/register'

const FABLE = 'claude-fable-5-2[1m]'
const ON = { table: DEFAULT_TABLE }
const SID = '0a1b2c3d-0000-4000-8000-000000000001'

const spawn = (over: Partial<AgentSpawnInput> = {}): AgentSpawnInput => ({
  tool_use_id: 't1',
  prompt: 'p',
  description: 'd',
  subagentType: 'general-purpose',
  provider: { plugin: 'engine', tier: 'core' },
  parentModel: FABLE,
  background: false,
  fork: false,
  ...over,
} as AgentSpawnInput)

const profile = (block: unknown) => JSON.stringify({ workflow: { subagent_model: block } })
// Lets the fire-and-forget trace chain settle; the engine types carry no timer globals.
const tick = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

test('parseConfig: off unless enabled is exactly true; a bad table row is dropped', async () => {
  expect(parseConfig('{not json')).toBe(null)
  expect(parseConfig('{}')).toBe(null)
  expect(parseConfig(JSON.stringify({ workflow: {} }))).toBe(null)
  expect(parseConfig(profile({ enabled: false }))).toBe(null)
  expect(parseConfig(profile({ enabled: 'true' }))).toBe(null)
  expect(parseConfig(profile({ enabled: true, table: 'opus' }))).toBe(null)
  expect(parseConfig(profile({ enabled: true }))).toEqual({ table: DEFAULT_TABLE })
  expect(parseConfig(profile({ enabled: true, table: { Explore: 'sonnet', 'general-purpose': 'claude-opus-4-1', claude: 3 } })))
    .toEqual({ table: { Explore: 'sonnet' } })
})

test('family reads the family from aliases, [1m] and provider ids', async () => {
  expect(family(FABLE)).toBe('fable')
  expect(family('claude-mythos-5-2')).toBe('mythos')
  expect(family('us.anthropic.claude-opus-4-1-v1:0')).toBe('opus')
  expect(family('sonnet')).toBe('sonnet')
  expect(family('gpt-x')).toBe(undefined)
})

test('default table on a Fable parent lowers general-purpose, claude and Explore to opus; Plan passes', async () => {
  for (const subagentType of ['general-purpose', 'claude', 'Explore']) {
    expect(decide(spawn({ subagentType }), ON, {})).toEqual({ model: 'opus' })
  }
  expect(decide(spawn({ subagentType: 'Plan' }), ON, {})).toEqual({ pass: 'not in table' })
})

test('a custom Explore → sonnet row lowers Explore on Opus and on Fable parents', async () => {
  const custom = { table: { Explore: 'sonnet' as const } }
  expect(decide(spawn({ subagentType: 'Explore', parentModel: 'claude-opus-5-5' }), custom, {})).toEqual({ model: 'sonnet' })
  expect(decide(spawn({ subagentType: 'Explore' }), custom, {})).toEqual({ model: 'sonnet' })
})

test('off config passes every spawn', async () => {
  expect(decide(spawn(), null, {})).toEqual({ pass: 'off' })
})

test('env: a subagent model or FORCE passes; inherit/default/empty do not; a redirected alias passes', async () => {
  expect(decide(spawn(), ON, { subagentModel: 'opus' })).toEqual({ pass: 'env subagent model' })
  for (const subagentModel of ['inherit', 'default', '', ' Inherit ']) {
    expect(decide(spawn(), ON, { subagentModel })).toEqual({ model: 'opus' })
  }
  expect(decide(spawn(), ON, { subagentModelForce: '1' })).toEqual({ pass: 'env subagent model' })
  expect(decide(spawn(), ON, { defaultOpus: 'x' })).toEqual({ pass: 'alias redirected' })
  expect(decide(spawn(), ON, { defaultSonnet: 'x' })).toEqual({ model: 'opus' })
})

test('forks, resumes, teammates and workflow agents pass', async () => {
  expect(decide(spawn({ fork: true }), ON, {})).toEqual({ pass: 'fork' })
  expect(decide(spawn({ subagentType: 'fork' }), ON, {})).toEqual({ pass: 'fork' })
  expect(decide(spawn({ resume: { agentId: 'a' } }), ON, {})).toEqual({ pass: 'resume' })
  expect(decide(spawn({ isTeammate: true }), ON, {})).toEqual({ pass: 'teammate' })
  expect(decide(spawn({ workflow: { runId: 'wf_1', agentIndex: 1 } }), ON, {})).toEqual({ pass: 'workflow' })
})

test('a named model passes; inherit is lowered', async () => {
  expect(decide(spawn({ model: 'haiku' }), ON, {})).toEqual({ pass: 'named model' })
  expect(decide(spawn({ model: 'inherit' }), ON, {})).toEqual({ model: 'opus' })
})

test('a non-engine agent under a built-in name and a pinned built-in pass', async () => {
  expect(decide(spawn({ subagentType: 'Explore', provider: { plugin: 'some-plugin', tier: 'user' } }), ON, {}))
    .toEqual({ pass: 'not engine' })
  const table = { table: { 'statusline-setup': 'haiku' as const } }
  expect(decide(spawn({ subagentType: 'statusline-setup' }), table, {})).toEqual({ pass: 'pinned built-in' })
})

test('only lowers: equal or cheaper parent and an unknown family pass', async () => {
  expect(decide(spawn({ parentModel: 'claude-opus-5-5' }), ON, {})).toEqual({ pass: 'not cheaper' })
  expect(decide(spawn({ parentModel: 'sonnet' }), ON, {})).toEqual({ pass: 'not cheaper' })
  expect(decide(spawn({ parentModel: 'my-custom-model' }), ON, {})).toEqual({ pass: 'unknown parent family' })
})

test('resolveRoot takes the git top level, else the start directory', async () => {
  expect(resolveRoot('/repo/src', 0, '/repo\n')).toBe('/repo')
  expect(resolveRoot('/wt/sub', 0, '/wt\n')).toBe('/wt')
  expect(resolveRoot('/x', 128, '')).toBe('/x')
  expect(resolveRoot('/x', 0, '  ')).toBe('/x')
})

test('findRoot: the start profile wins, else the git top level, else the start directory', async () => {
  const probed: string[] = []
  let gitCalls = 0
  const io = (hasProfile: boolean, git: () => Promise<{ exitCode: number; stdout: string }>) => ({
    exists: async (p: string) => { probed.push(p); return hasProfile },
    git: () => { gitCalls++; return git() },
  })
  expect(await findRoot('/mono/app', io(true, async () => ({ exitCode: 0, stdout: '/mono\n' })))).toBe('/mono/app')
  expect(gitCalls).toBe(0)
  expect(probed).toEqual(['/mono/app/.claude/project-profile.json'])
  expect(await findRoot('/repo/src', io(false, async () => ({ exitCode: 0, stdout: '/repo\n' })))).toBe('/repo')
  expect(await findRoot('/x', io(false, async () => ({ exitCode: 128, stdout: '' })))).toBe('/x')
  expect(await findRoot('/x', io(false, async () => { throw new Error('git: not found') }))).toBe('/x')
  expect(gitCalls).toBe(3)
})

type Call = { e: AgentSpawnInput }
function harness(over: Partial<Deps> = {}, result: AgentSpawnResult | Error = { model: 'claude-opus-5-5', agentId: 'a1' }) {
  const reads: string[] = []
  const traces: { argv: readonly string[]; cwd: string }[] = []
  const calls: Call[] = []
  const deps: Deps = {
    root: async () => '/proj',
    read: async (p) => {
      reads.push(p)
      return profile({ enabled: true })
    },
    env: async () => ({}),
    sessionId: async () => SID,
    trace: async (argv, cwd) => {
      traces.push({ argv, cwd })
    },
    ...over,
  }
  const next = async (e: AgentSpawnInput): Promise<AgentSpawnResult> => {
    calls.push({ e })
    if (result instanceof Error) throw result
    return result
  }
  return { deps, next, reads, traces, calls }
}

test('onSpawn reads the profile under root, dispatches once lowered, and traces core\'s model', async () => {
  const h = harness()
  const res = await onSpawn(h.deps, spawn(), h.next)
  await tick()
  expect(res).toEqual({ model: 'claude-opus-5-5', agentId: 'a1' })
  expect(h.reads).toEqual(['/proj/.claude/project-profile.json'])
  expect(h.calls).toHaveLength(1)
  expect(h.calls[0]?.e.model).toBe('opus')
  expect(h.traces).toEqual([{
    argv: ['bash', '/proj/.claude/lib/costs/runtime-mark.sh', 'subagent', '--session', SID,
      '--agent-type', 'general-purpose', '--parent-model', FABLE, '--model', 'claude-opus-5-5'],
    cwd: '/proj',
  }])
})

test('onSpawn: a throwing root() or a missing profile dispatches the original event once, no trace', async () => {
  for (const over of [
    { root: async () => { throw new Error('no root') } },
    { read: async () => { throw new Error('ENOENT') } },
  ] as Partial<Deps>[]) {
    const h = harness(over)
    const e = spawn()
    await onSpawn(h.deps, e, h.next)
    await tick()
    expect(h.calls).toHaveLength(1)
    expect(h.calls[0]?.e).toBe(e)
    expect(h.calls[0]?.e.model).toBe(undefined)
    expect(h.traces).toHaveLength(0)
  }
})

test('onSpawn: a trace that throws synchronously or rejects never touches the result', async () => {
  for (const trace of [
    (() => { throw new Error('sync') }) as Deps['trace'],
    (async () => { throw new Error('async') }) as Deps['trace'],
  ]) {
    const h = harness({ trace })
    const res = await onSpawn(h.deps, spawn(), h.next)
    await tick()
    expect(res).toEqual({ model: 'claude-opus-5-5', agentId: 'a1' })
    expect(h.calls).toHaveLength(1)
  }
  const h = harness({ sessionId: (() => { throw new Error('sync sid') }) as Deps['sessionId'] })
  expect(await onSpawn(h.deps, spawn(), h.next)).toEqual({ model: 'claude-opus-5-5', agentId: 'a1' })
})

test('onSpawn: a rejecting next propagates and is not called again', async () => {
  const boom = new Error('boom')
  const h = harness({}, boom)
  let caught: unknown
  try {
    await onSpawn(h.deps, spawn(), h.next)
  } catch (err) {
    caught = err
  }
  expect(caught).toBe(boom)
  expect(h.calls).toHaveLength(1)
})

test('onSpawn: a deny or a result without agentId writes no trace', async () => {
  for (const result of [{ deny: 'x' }, { model: 'claude-opus-5-5' }] as AgentSpawnResult[]) {
    const h = harness({}, result)
    expect(await onSpawn(h.deps, spawn(), h.next)).toEqual(result)
    await tick()
    expect(h.traces).toHaveLength(0)
  }
})

test('onSpawn: a pass returns whatever next gave, never a deny of its own', async () => {
  const h = harness({ read: async () => profile({ enabled: false }) }, { model: 'm', agentId: 'a2' })
  const e = spawn()
  expect(await onSpawn(h.deps, e, h.next)).toEqual({ model: 'm', agentId: 'a2' })
  expect(h.calls[0]?.e).toBe(e)
  await tick()
  expect(h.traces).toHaveLength(0)
})
