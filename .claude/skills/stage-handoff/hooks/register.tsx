import type { EngineInterface, Register } from 'claude-code'

// Contract: a pipeline command (e.g. /orchestrate) ends a stage by writing this file and
// ending its turn. The marker is consumed (renamed to <marker>.last.json) before anything
// else runs, so a failed compaction never loops.
//   { "stage": "brainstorm",                      // name shown in toasts and the summary
//     "resume": "/orchestrate --resume",          // prompt submitted after compaction
//     "keep": ["spec: .agents/specs/x.md", ...],  // lines the summary must keep verbatim
//     "focus": "free text for the summarizer" }   // optional
export type Marker = { stage: string; resume: string; keep?: string[]; focus?: string }

const COMMAND = 'stage-handoff'
const RETRY_MS = 2_000
const RETRIES = 15

export const parseMarker = (text: string): Marker | string => {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return 'marker is not valid JSON'
  }
  if (typeof raw !== 'object' || raw === null) return 'marker is not an object'
  const m = raw as Record<string, unknown>
  if (typeof m.stage !== 'string' || m.stage.trim() === '') return 'marker.stage missing'
  if (typeof m.resume !== 'string' || m.resume.trim() === '') return 'marker.resume missing'
  const keep = Array.isArray(m.keep) ? m.keep.filter((k): k is string => typeof k === 'string') : []
  const focus = typeof m.focus === 'string' ? m.focus : undefined
  return { stage: m.stage.trim(), resume: m.resume.trim(), keep, focus }
}

// Steers the engine's summary. CLAUDE.md, rules/ and MEMORY.md reload from disk afterwards.
export const compactInstructions = (m: Marker): string => `This summary replaces the conversation \
at a pipeline stage boundary. The stage "${m.stage}" just finished; the next prompt will be \
"${m.resume}" and must be able to continue from this summary plus the files on disk.

Preserve exactly, with IDs, paths and SHAs verbatim:
1. The pipeline state: which stages are done, which comes next, the run file and every artifact \
path (spec, plan, run-log, handoff) written or read so far.
2. Owner decisions and answered questions: quote them, do not paraphrase. Assumptions the \
pipeline made on the owner's behalf, one line each.
3. Running or scheduled work: background tasks, Codex runs, wakeups, subagents — what each one \
waits for.
4. Tickets, branch, commits (SHA), PRs in play.
5. Files that mattered and are NOT auto-loaded: paths only, one line each on why.
6. The exact next step.
${m.keep && m.keep.length > 0 ? `\nKeep these lines verbatim:\n${m.keep.map((k) => `- ${k}`).join('\n')}\n` : ''}${m.focus ? `\nFocus of the next stage: ${m.focus}\n` : ''}
Drop: tool output, file contents that can be re-read, exploration that led nowhere, narration. \
Prefer bullets; keep it under ~2k words.`

let markerPath = '.claude/stage-handoff.json'
let resumeDelayMs = 1_000
let inFlight = false
// Bumped by the session.compact hook whenever a main-loop compaction completes — whoever
// triggered it. The handoff waits on this counter, not only on its own compact() promise:
// a compaction of a very large context can outlive that promise (the first real run lost
// its resume that way), and the counter still sees the compaction finish.
let compactions = 0

const COMPACT_WAIT_MS = 10 * 60_000
const SUBMIT_RETRIES = 10
const LOG_LINES = 300

async function log($: EngineInterface, line: string): Promise<void> {
  const path = markerPath.replace(/\.json$/, '') + '.log'
  try {
    const prev = (await $.fs.exists(path)) ? await $.fs.read(path) : ''
    const lines = prev.split('\n').filter((l) => l !== '')
    lines.push(`${new Date(await $.clock.now()).toISOString()} ${line}`)
    await $.fs.write(path, lines.slice(-LOG_LINES).join('\n') + '\n')
  } catch {
    // logging must never break the handoff
  }
}

const errText = (err: unknown): string => (err instanceof Error ? err.message : String(err)).slice(0, 300)

async function consume($: EngineInterface): Promise<Marker | undefined> {
  if (!(await $.fs.exists(markerPath))) return undefined
  const text = await $.fs.read(markerPath)
  // Rename first: whatever happens next, the marker fires once.
  const last = markerPath.replace(/\.json$/, '') + '.last.json'
  const mv = await $.process.run(['mv', '-f', markerPath, last])
  if (mv.exitCode !== 0) {
    $.ui.toast(`stage-handoff: cannot consume ${markerPath} (${mv.stderr.trim()})`)
    await log($, `consume: mv failed: ${mv.stderr.trim()}`)
    return undefined
  }
  const parsed = parseMarker(text)
  if (typeof parsed === 'string') {
    $.ui.toast(`stage-handoff: ${parsed} — nothing done, see ${last}`)
    await log($, `consume: ${parsed}`)
    return undefined
  }
  await log($, `consume: stage="${parsed.stage}" resume="${parsed.resume}"`)
  return parsed
}

// Compaction rejects while a turn runs; the turn that wrote the marker may still be
// settling when the timer fires, so retry a few times before giving up. Resolves as soon
// as EITHER its own compact() call returns OR the session.compact hook saw a compaction
// complete (the counter) — the promise alone proved unreliable on a large context.
async function compactWithRetry($: EngineInterface, m: Marker): Promise<'done' | 'skipped' | 'failed'> {
  const before = compactions
  let settled: 'done' | 'skipped' | 'failed' | undefined
  const own = (async () => {
    for (let attempt = 0; attempt < RETRIES; attempt++) {
      try {
        const { skip } = await $.session.compact({ instructions: compactInstructions(m) })
        await log($, `compact: call resolved (attempt ${attempt + 1}, skip=${skip ?? 'no'})`)
        settled = skip === undefined ? 'done' : 'skipped'
        return
      } catch (err) {
        await log($, `compact: attempt ${attempt + 1} rejected: ${errText(err)}`)
        if (compactions > before) return
        await $.clock.sleep(RETRY_MS)
      }
    }
    settled = 'failed'
  })()
  const startedAt = await $.clock.now()
  for (;;) {
    if (settled !== undefined && settled !== 'failed') return settled
    if (compactions > before) {
      await log($, `compact: observed via session.compact hook (${compactions - before} compaction(s))`)
      return 'done'
    }
    if (settled === 'failed') return 'failed'
    if ((await $.clock.now()) - startedAt > COMPACT_WAIT_MS) {
      await log($, `compact: no compaction within ${COMPACT_WAIT_MS / 1000}s — giving up`)
      void own
      return 'failed'
    }
    await $.clock.sleep(RETRY_MS)
  }
}

async function submitWithRetry($: EngineInterface, text: string): Promise<boolean> {
  for (let attempt = 0; attempt < SUBMIT_RETRIES; attempt++) {
    try {
      await $.prompt.submit({ text })
      await log($, `submit: ok (attempt ${attempt + 1}): ${text}`)
      return true
    } catch (err) {
      await log($, `submit: attempt ${attempt + 1} rejected: ${errText(err)}`)
      await $.clock.sleep(RETRY_MS)
    }
  }
  return false
}

async function handoff($: EngineInterface, m: Marker): Promise<void> {
  if (inFlight) return
  inFlight = true
  try {
    $.ui.toast(`stage-handoff: "${m.stage}" done — compacting, then ${m.resume}`)
    await log($, `handoff: start stage="${m.stage}"`)
    const outcome = await compactWithRetry($, m)
    if (outcome === 'failed') {
      $.ui.toast(`stage-handoff: compaction did not run (a turn kept running) — type ${m.resume} yourself`)
      await log($, 'handoff: compaction failed — no resume submitted')
      return
    }
    if (outcome === 'skipped') $.ui.toast('stage-handoff: compaction vetoed by a hook — resuming uncompacted')
    await $.clock.sleep(resumeDelayMs)
    const ok = await submitWithRetry($, m.resume)
    if (!ok) $.ui.toast(`stage-handoff: could not submit ${m.resume} — type it yourself (see .claude/stage-handoff.log)`)
  } catch (err) {
    await log($, `handoff: threw: ${errText(err)}`)
    $.ui.toast(`stage-handoff: failed (${errText(err)}) — type ${m.resume} yourself`)
  } finally {
    inFlight = false
  }
}

export const register: Register = (on, options) => {
  markerPath = typeof options.markerPath === 'string' && options.markerPath !== '' ? options.markerPath : '.claude/stage-handoff.json'
  resumeDelayMs = typeof options.resumeDelayMs === 'number' ? options.resumeDelayMs : 1_000

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: 'Compact with stage-handoff instructions, then submit the given resume command; argument = resume command (default: the marker on disk)',
    })
    return next(e)
  })

  // Observe every main-loop compaction completing, whoever triggered it (see `compactions`).
  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && e.trigger !== 'precompute' && result.skip === undefined) {
      compactions++
      await log($, `session.compact: completed (trigger=${e.trigger}, before=${result.tokensBefore ?? '?'}, after=${result.tokensAfter ?? '?'})`)
    }
    return result
  })

  // Main-loop answers only: a subagent's end or an aborted turn never triggers a handoff.
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return done
    const m = await consume($).catch(() => undefined)
    if (m !== undefined) $.clock.after(500, () => void handoff($, m))
    return done
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim()
    const m = arg !== '' ? { stage: 'manual', resume: arg, keep: [] } : await consume($)
    if (m === undefined) return { text: `No resume command given and no marker at ${markerPath}.` }
    $.clock.after(0, () => void handoff($, m))
    return { text: `Compacting, then submitting: ${m.resume}` }
  }).catch(() => ({ text: 'stage-handoff failed; context unchanged.' }))
}
