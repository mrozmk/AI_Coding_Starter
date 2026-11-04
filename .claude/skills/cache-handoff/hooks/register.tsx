import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const COMMAND = 'hc'
const TICK_MS = 30_000

// When the main thread last got a response: the moment its prompt cache was last refreshed.
const lastResponseAt = atom({ plugin: 'cache-handoff', key: 'lastResponseAt' } as const, null)
const isBusy = atom({ plugin: 'cache-handoff', key: 'isBusy' } as const, false)

type Cache = { icon: string; label: string; isWarm: boolean; minutesLeft: number }

export const formatTokens = (n: number): string => {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2).replace(/\.?0+$/, '') + 'M'
  if (n >= 1_000) return Math.round(n / 1_000) + 'k'
  return String(n)
}

export const cacheState = (now: number, last: number | null, ttlMs: number): Cache => {
  if (last === null) return { icon: '', label: 'cache: no data yet', isWarm: false, minutesLeft: 0 }
  const leftMs = last + ttlMs - now
  const minutesLeft = Math.ceil(leftMs / 60_000)
  if (leftMs <= 0) {
    const coldFor = Math.floor(-leftMs / 60_000)
    return { icon: '❄', label: `cache cold for ${coldFor} min`, isWarm: false, minutesLeft: 0 }
  }
  // The last sixth of the TTL: 10 min of 1h, under a minute of 5m.
  if (leftMs <= ttlMs / 6) {
    return { icon: '🌤', label: `cache cooling · ${minutesLeft} min`, isWarm: true, minutesLeft }
  }
  return { icon: '☀', label: `cache warm · expires in ${minutesLeft} min`, isWarm: true, minutesLeft }
}

// Steers the engine's own summary; CLAUDE.md, rules/ and MEMORY.md reload from disk after it.
export const COMPACT_INSTRUCTIONS = (focus: string) => `This summary replaces the conversation. \
CLAUDE.md, rules/ and the auto-memory index MEMORY.md are reloaded from disk after compaction; do \
not restate them.

Preserve exactly, with IDs, paths and SHAs verbatim:
1. Running or scheduled work: background tasks, Monitors, cron jobs (id + schedule), \
wakeups/loops, background subagents, team sessions, Codex runs. What each one waits for, and \
what to do when it reports.
2. Owner decisions: the numbered list still waiting for the owner, and decisions already made \
(quote them, do not paraphrase).
3. Tickets in play: tracker keys and their status, branch, commits (SHA), PRs.
4. Production state: release freeze, open ops windows, what was verified and what was not (say \
"unverified" explicitly).
5. Files that mattered this session and are NOT auto-loaded: paths only (.agents/memory/*, \
specs, plans, reference docs, mod sources), one line each on why.
6. The exact next step.${focus ? `\n\nThe next part of the session will focus on: ${focus}` : ''}

Drop: tool output, file contents that can be re-read, exploration that led nowhere, narration. \
Prefer bullets; keep it under ~2k words.`

// The newest main-thread response with usage among transcript lines, as epoch ms.
export const lastResponseIn = (lines: string): number | null => {
  for (const line of lines.split('\n').reverse()) {
    if (!line.includes('"assistant"')) continue
    try {
      const entry = JSON.parse(line)
      if (entry.type === 'assistant' && !entry.isSidechain && entry.message?.usage) {
        const at = Date.parse(entry.timestamp)
        if (!Number.isNaN(at)) return at
      }
    } catch {
      // A line cut by tail or written mid-flush: skip it.
    }
  }
  return null
}

// Seeds the cache clock from the transcript, so a reload or a resumed session does not
// start blind. The transcript can outgrow $.fs.read's 4 MiB, hence tail. The transcript lives
// under $HOME, which the mod does not know (it ships inside the project), so the shell resolves it.
async function seedFromTranscript($: EngineInterface): Promise<void> {
  if ((await read($, lastResponseAt)) !== null) return
  const [root, id] = await Promise.all([$.session.root(), $.session.id()])
  const project = root.replace(/[^A-Za-z0-9]/g, '-')
  const tail = await $.process.run(['sh', '-c', 'tail -n 400 -- "$HOME/.claude/projects/$1/$2.jsonl"', 'sh', project, id])
  if (tail.exitCode !== 0) return
  const at = lastResponseIn(tail.stdout)
  if (at !== null) await update($, lastResponseAt, () => at)
}

// Set from the options each time the module (re)loads.
let ttlMs = 60 * 60_000
let bandAt = 500_000
let autoMinutes = 5
let forceMinutes = 2

// Main and subagent turns in flight; the auto /hc must not compact under a running turn.
const runningTurns = new Set<string>()
// The response whose cache the auto /hc already acted on, so one lapse fires it once.
let autoFiredFor: number | null = null

export const shouldAutoHc = (
  cache: Cache,
  tokens: number,
  opts: { minutesBefore: number; forceMinutes: number; atTokens: number; isIdle: boolean },
): boolean =>
  opts.minutesBefore > 0 &&
  opts.isIdle &&
  cache.isWarm &&
  // Near the end the size no longer matters: the state is kept before the cache goes cold,
  // however small the context.
  (cache.minutesLeft <= opts.forceMinutes ||
    (cache.minutesLeft <= opts.minutesBefore && tokens >= opts.atTokens))

// The band's minutes and tokens move without any state write; redraw it.
async function refresh($: EngineInterface): Promise<void> {
  $.ui.invalidate('ui.render')
}

async function runCompact($: EngineInterface, focus: string): Promise<void> {
  try {
    const compacted = await $.session.compact({ instructions: COMPACT_INSTRUCTIONS(focus) })
    if (compacted.skip !== undefined) {
      $.ui.toast(`Compact vetoed: ${compacted.skip}`)
      return
    }
    // The compacted prefix is new: nothing of it is cached until the next response.
    await update($, lastResponseAt, () => null)
    $.ui.toast('Compact done.')
  } finally {
    await update($, isBusy, () => false)
    await refresh($)
  }
}

// Compaction cannot run under the command that asked for it, so it runs from a timer
// once that command has returned.
async function compactSoon($: EngineInterface, focus: string): Promise<string> {
  if (await read($, isBusy)) return 'A compact is already running.'
  await update($, isBusy, () => true)
  await refresh($)
  $.clock.after(0, () => void runCompact($, focus))
  return 'Compacting with the /hc instructions (background work, decisions, tickets, production state, files).'
}

async function maybeAutoHc($: EngineInterface): Promise<void> {
  const [usage, now, last, busy] = await Promise.all([
    $.session.usage(),
    $.clock.now(),
    read($, lastResponseAt),
    read($, isBusy),
  ])
  if (busy || last === null || last === autoFiredFor) return
  const tokens = usage.context.tokens ?? 0
  const opts = {
    minutesBefore: autoMinutes,
    forceMinutes,
    atTokens: bandAt,
    isIdle: runningTurns.size === 0,
  }
  const cache = cacheState(now, last, ttlMs)
  if (!shouldAutoHc(cache, tokens, opts)) return
  autoFiredFor = last
  $.ui.toast(`Cache expires in ${cache.minutesLeft} min — automatic /hc (${formatTokens(tokens)})`)
  await compactSoon($, '')
}

export const register: Register = (on, options) => {
  ttlMs = options.cacheTtl === '5m' ? 5 * 60_000 : 60 * 60_000
  bandAt = typeof options.bandAtTokens === 'number' ? options.bandAtTokens : 500_000
  autoMinutes = typeof options.autoHcMinutes === 'number' ? options.autoHcMinutes : 5
  // On a 5m TTL this would compact three minutes after every response.
  const force = typeof options.autoHcForceMinutes === 'number' ? options.autoHcForceMinutes : 2
  forceMinutes = ttlMs > 10 * 60_000 ? force : 0

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: '/compact with state-keeping instructions (background work, decisions, tickets, production); argument = focus',
    })
    // The context/cache status line is the settings statusLine (statusline.cjs), not a pinned entry.
    $.ui.status(undefined)
    $.clock.every(TICK_MS, () => {
      void refresh($)
      void maybeAutoHc($).catch(() => undefined)
    })
    await seedFromTranscript($).catch(() => undefined)
    await refresh($)
    return next(e)
  })

  on('turn.start', async (_$, e, next) => {
    runningTurns.add(e.turnId)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    runningTurns.delete(e.turnId)
    const done = await next(e)
    if (e.agentId === undefined && e.usage !== undefined) {
      const now = await $.clock.now()
      await update($, lastResponseAt, () => now)
      await refresh($)
    }
    return done
  })

  on('command.run', { command: COMMAND }, async ($, e) => ({
    text: await compactSoon($, e.args.trim()),
  })).catch(() => ({ text: 'Compact failed; context unchanged.' }))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const [usage, now, last, busy] = await Promise.all([
      $.session.usage(),
      $.clock.now(),
      read($, lastResponseAt),
      read($, isBusy),
    ])
    const tokens = usage.context.tokens ?? 0
    if (!busy && tokens < bandAt) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    if (busy) return <Text dimColor>⏳ compact in progress…</Text>

    const cache = cacheState(now, last, ttlMs)
    // Cheapest moment: the cache is still warm but about to lapse.
    const isUrgent = cache.isWarm && cache.minutesLeft <= Math.ceil(ttlMs / 60_000 / 6)
    return (
      <Box>
        <Text dimColor>
          {formatTokens(tokens)} in context · {[cache.icon, cache.label].filter(Boolean).join(' ')}
          {isUrgent ? ' · do it now, while it is cheap ' : ' '}
        </Text>
        <Button
          key="compact"
          label="Compact (/hc)"
          variant={isUrgent ? 'primary' : undefined}
          onPress={() => void compactSoon($, '')}
        />
      </Box>
    )
  })
}
