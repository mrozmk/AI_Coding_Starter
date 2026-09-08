// Codex executor adapter: the worker child spawned by scripts/executor-orchestrator.mjs for a
// Claude author. The opposite of the reviewer on one axis only — it keeps its shell, so it can read
// files, run git and (in write mode) apply patches; delegation and every side channel stay off.
// There is no native output schema here either: `--schema` is validated by the orchestrator after
// the run, so the sandbox is never traded away for structured output.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { modelMatches, parseHeader } from './review.mjs';

export const host = 'codex';
const here = path.dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(fs.readFileSync(path.join(here, 'adapter.json'), 'utf8'));

export { modelMatches, parseHeader };

export function defaults() {
  return { model: meta.executor.model, effortDefault: meta.executor.effort_default, timeoutMinutes: meta.executor.timeout_minutes_default };
}

export function modeSpec(mode) {
  const spec = meta.executor.modes[mode];
  if (!spec) throw new Error(`executor mode must be read or write, got ${JSON.stringify(mode)}`);
  return spec;
}

export function buildSpawn({ mode, model, effort, repoRoot, outFile }) {
  const spec = modeSpec(mode);
  const args = [
    'exec',
    '--skip-git-repo-check',
    '-C', repoRoot,
    '--sandbox', spec.sandbox,
    '--ephemeral',
    '--ignore-user-config',
    '--ignore-rules',
    '-m', model,
    '-c', `model_reasoning_effort="${effort}"`,
  ];
  for (const override of meta.executor.config_overrides) args.push('-c', override);
  for (const feature of spec.disable_features) args.push('--disable', feature);
  args.push('--output-last-message', outFile, '-');
  return {
    command: meta.cli,
    args,
    cwd: repoRoot,
    stdin: 'prompt',
    env: {},
    isolation: [`--sandbox ${spec.sandbox}`, '--ephemeral', '--ignore-user-config', '--ignore-rules', ...spec.disable_features.map((f) => `--disable ${f}`)],
    external_policy_note: 'requirements.toml / managed Codex policy cannot be disabled by the adapter and remains in effect',
  };
}

// A worker is expected to use tools, so unlike the reviewer adapter this one makes no judgement
// about observed tool activity — the tamper check on the working tree is what bounds it.
export function parseOutput({ stderr, outFile }) {
  const text = (stderr ?? '').toString('utf8');
  const header = parseHeader(text);
  return {
    finalText: outFile && fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : '',
    confirmed: { model: header.model ?? null, effort: header['reasoning effort'] ?? null },
    header,
  };
}
