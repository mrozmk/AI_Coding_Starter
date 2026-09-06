// track-memory-read (T10): local read telemetry per memory file, ported from
// .claude/hooks/track-memory-read.sh. Reads (Read tool, shell reads) bump the sidecar; writes do
// not; archive is excluded; unexpanded globs are never keys; a malformed sidecar self-heals. The
// sidecar path keeps feeding the legacy cleanup reader while .claude/ exists. Missing telemetry is
// unknown usage — never evidence that a file is unused.
import fs from 'node:fs';
import path from 'node:path';
import { bumpMemoryReads } from '../../scripts/lib/telemetry.mjs';

export const id = 'track-memory-read';
export const strength = 'telemetry';

export function memoryKeys(projectRoot, reads) {
  const keys = [];
  for (const p of reads ?? []) {
    if (!/\.agents\/memory\/.*\.md$/.test(p) || /\.agents\/memory\/archive\//.test(p)) continue;
    if (/[*?{]/.test(p)) continue;
    const abs = path.isAbsolute(p) ? p : path.join(projectRoot, p);
    if (!fs.existsSync(abs)) continue;
    const key = p.slice(p.lastIndexOf('.agents/memory/') + '.agents/memory/'.length);
    if (!keys.includes(key)) keys.push(key);
  }
  return keys;
}

export async function run(event, ctx) {
  if (event.tool === 'file-edit') return { decision: 'none', state: 'active', reason: 'writes are maintenance, not consultation' };
  if (event.tool !== 'file-read' && event.tool !== 'shell') return { decision: 'none', state: event.host === 'codex' ? 'unsupported' : 'active', reason: event.host === 'codex' ? 'Codex exposes no structured read event; only shell reads are observed' : undefined };
  const keys = memoryKeys(ctx.projectRoot, event.reads);
  if (!keys.length) return { decision: 'none', state: 'active' };
  const db = bumpMemoryReads(ctx.state.memoryUsage, keys, { today: ctx.now.toISOString().slice(0, 10) });
  return { decision: 'none', state: 'active', recorded: keys, sidecar: ctx.state.memoryUsage, db };
}
