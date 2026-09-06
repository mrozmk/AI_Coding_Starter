// PERMISSIVE NEGATIVE CONTROL (tests only): the Codex adapter with sandbox/feature denials removed: closed-context `codex exec` with the pack on stdin,
// `--sandbox read-only`, no native output schema, every execution/delegation surface disabled by
// feature flag, user config ignored, ephemeral session, empty scratch cwd. The live probe
// (preflight --live-reviewer-probe) is what proves the effective tool surface; flags alone are not.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const host = 'codex';
const here = path.dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(fs.readFileSync(path.join(here, 'adapter.json'), 'utf8'));

export function defaults() {
  return { model: meta.reviewer.model, effort: meta.reviewer.effort, timeoutMinutes: meta.reviewer.timeout_minutes };
}

export function buildSpawn({ model, effort, scratchCwd, outFile }) {
  const args = [
    'exec',
    '--skip-git-repo-check',
    '-C', scratchCwd,
    '-m', model,
    '-c', `model_reasoning_effort="${effort}"`,
  ];
  args.push('--output-last-message', outFile, '-');
  return {
    command: meta.cli,
    args,
    cwd: scratchCwd,
    stdin: 'prompt+pack',
    env: {},
    isolation: [],
    external_policy_note: 'requirements.toml / managed Codex policy cannot be disabled by the adapter and remains in effect',
  };
}

// Without `--json` the CLI prints a run header on stderr (model, provider, approval, sandbox,
// reasoning effort) and the final message to outFile. The header is the CLI's own confirmation of
// what actually ran; tool activity shows up as `exec`/`tool` lines after the header.
export function parseHeader(stderrText) {
  const header = {};
  for (const line of stderrText.split('\n').slice(0, 40)) {
    const m = line.match(/^(model|provider|approval|sandbox|reasoning effort|workdir):\s*(.+)$/);
    if (m) header[m[1]] = m[2].trim();
  }
  return header;
}

export function parseOutput({ stderr, outFile }) {
  const text = (stderr ?? '').toString('utf8');
  const header = parseHeader(text);
  const body = text.split('--------').slice(2).join('--------');
  const toolCalls = body.split('\n').filter((l) => /^(exec|tool|mcp|apply_patch|shell|spawn_agent|codex \$)/.test(l.trim())).map((l) => l.trim().slice(0, 80));
  const finalText = outFile && fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : '';
  return {
    finalText,
    confirmed: { model: header.model ?? null, effort: header['reasoning effort'] ?? null },
    header,
    toolUses: { count: toolCalls.length, types: toolCalls, sandbox: header.sandbox ?? null, approval: header.approval ?? null },
  };
}

export function modelMatches(requested, confirmed) {
  return Boolean(confirmed) && confirmed.toLowerCase() === requested.toLowerCase();
}
