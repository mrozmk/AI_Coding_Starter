import { expect, test } from 'claude-code/testing'
import { compactInstructions, parseMarker } from '../hooks/register'

test('a marker needs stage and resume', async () => {
  expect(parseMarker('not json')).toBe('marker is not valid JSON')
  expect(parseMarker('{"resume":"/x"}')).toBe('marker.stage missing')
  expect(parseMarker('{"stage":"a"}')).toBe('marker.resume missing')
  const m = parseMarker('{"stage":"plan","resume":"/orchestrate --resume","keep":["plan: p.md", 3],"focus":"f"}')
  expect(typeof m).toBe('object')
  if (typeof m !== 'string') {
    expect(m.keep).toEqual(['plan: p.md'])
    expect(m.focus).toBe('f')
  }
})

test('instructions carry the stage, the resume command and the kept lines', async () => {
  const text = compactInstructions({ stage: 'plan', resume: '/orchestrate --resume', keep: ['plan: p.md'] })
  expect(text).toContain('"plan" just finished')
  expect(text).toContain('/orchestrate --resume')
  expect(text).toContain('- plan: p.md')
})
