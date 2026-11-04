import { expect, mock, test } from 'claude-code/testing'

import { cacheState, lastResponseIn, shouldAutoHc } from '../hooks/register'

const HOUR = 60 * 60_000

test('cache reads warm, cooling and cold against the TTL', async () => {
  expect(cacheState(0, null, HOUR).label).toBe('cache: no data yet')
  expect(cacheState(18 * 60_000, 0, HOUR)).toMatchObject({ icon: '☀', minutesLeft: 42, isWarm: true })
  expect(cacheState(55 * 60_000, 0, HOUR)).toMatchObject({ icon: '🌤', minutesLeft: 5 })
  expect(cacheState(HOUR + 3 * 60_000, 0, HOUR)).toMatchObject({ icon: '❄', isWarm: false })
})

test('/hc compacts with the state-keeping instructions and no handoff file', async ($, on) => {
  const clock = mock.clock(on, { now: Date.UTC(2026, 9, 12, 12, 0) })
  const compacts: (string | undefined)[] = []
  let wrote = false

  on('ui.toast', () => ({ value: undefined }))
  on('fs.write', () => {
    wrote = true
    return { value: undefined }
  })
  on('session.compact', (_$, e) => {
    compacts.push(e.instructions)
    return { messages: [{ role: 'user', text: 'summary', toolUses: [] }] }
  })

  const { text } = await $.command.run({
    command: 'hc',
    args: 'release checklist',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })
  expect(compacts).toHaveLength(0)
  await clock.advance(1)

  expect(compacts).toHaveLength(1)
  expect(compacts[0]).toContain('Monitors, cron jobs')
  expect(compacts[0]).toContain('focus on: release checklist')
  expect(wrote).toBe(false)
  expect(text).toContain('Compacting')
})

test('the cache clock is seeded from the newest main-thread response', async () => {
  const lines = [
    '{"type":"assistant","timestamp":"2026-10-10T15:00:00.000Z","message":{"usage":{}}}',
    '{"type":"assistant","isSidechain":true,"timestamp":"2026-10-10T15:09:00.000Z","message":{"usage":{}}}',
    '{"type":"assistant","timestamp":"2026-10-10T15:05:00.000Z","message":{"usage":{}}}',
    '{"type":"user","timestamp":"2026-10-10T15:06:00.000Z"}',
    '{"type":"assist',
  ].join('\n')
  expect(lastResponseIn(lines)).toBe(Date.parse('2026-10-10T15:05:00.000Z'))
  expect(lastResponseIn('')).toBe(null)
})

test('auto /hc fires only idle, warm, near expiry and over the token threshold', async () => {
  const near = cacheState(56 * 60_000, 0, HOUR)
  const opts = { minutesBefore: 5, forceMinutes: 0, atTokens: 500_000, isIdle: true }
  expect(shouldAutoHc(near, 600_000, opts)).toBe(true)
  expect(shouldAutoHc(cacheState(50 * 60_000, 0, HOUR), 600_000, opts)).toBe(false)
  expect(shouldAutoHc(cacheState(HOUR + 1, 0, HOUR), 600_000, opts)).toBe(false)
  expect(shouldAutoHc(near, 100_000, opts)).toBe(false)
  expect(shouldAutoHc(near, 600_000, { ...opts, isIdle: false })).toBe(false)
  expect(shouldAutoHc(near, 600_000, { ...opts, minutesBefore: 0 })).toBe(false)
})

test('auto /hc fires regardless of tokens in the last force minutes', async () => {
  const opts = { minutesBefore: 5, forceMinutes: 2, atTokens: 500_000, isIdle: true }
  const last2 = cacheState(58 * 60_000, 0, HOUR)
  expect(shouldAutoHc(last2, 1_000, opts)).toBe(true)
  expect(shouldAutoHc(cacheState(56 * 60_000, 0, HOUR), 1_000, opts)).toBe(false)
  expect(shouldAutoHc(last2, 1_000, { ...opts, isIdle: false })).toBe(false)
  expect(shouldAutoHc(cacheState(HOUR + 1, 0, HOUR), 1_000, opts)).toBe(false)
  expect(shouldAutoHc(last2, 1_000, { ...opts, forceMinutes: 0 })).toBe(false)
})
