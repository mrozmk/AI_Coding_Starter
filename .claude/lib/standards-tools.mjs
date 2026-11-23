// Deterministic scan of lint / format / analyzer / compiler configs and of the script, hook and CI
// runs that check them — the evidence behind every `Enforced by: tool` rule that /setup:map-codebase
// and /setup:create-CLAUDE_MD render into docs/coding-standards.md. It opens only recognised config
// and wiring files from the given list, and never a path that resolves outside the repo.
// Node builtins only (+ yaml-subset.mjs) — ships to every downstream.
//
//   node .claude/lib/standards-tools.mjs scan --repo <dir> [--files-from <file>]
//   stdout: JSON { tools, observed, unparsed, unattributed, notLoaded, scopeUnknown, ignored } · exit 2 = usage

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseYaml } from './yaml-subset.mjs';

const T = (tool, display, cls, o = {}) => ({
  tool, display, class: cls, aliases: [], configs: [], runs: null, bin: null, sub: [], selectFlags: [],
  excludeFlags: [], strictFlags: [], valueFlags: [], strictRe: null, requireStrict: false, stopAt: null,
  observe: new RegExp(`\\b${tool}\\b`, 'i'), appliesTo: '**/*', ...o,
});
const PY = '**/*.py';
const PHP = '**/*.php';
const GO = '**/*.go';
const RS = '**/*.rs';
const CS = '**/*.cs';

// One entry per tool, in render order. `runs` matches CHECKING invocations only (a violation fails
// the command); `reject` removes listing/fixing forms; `section` scopes a shared file (pyproject…).
export const TOOLS = [
  T('eslint', 'ESLint', 'lint', {
    configs: [/(^|\/)\.eslintrc(\.(json|ya?ml|js|cjs))?$/, /(^|\/)eslint\.config\.(js|mjs|cjs|ts)$/],
    runs: /(^|[\s/])(eslint|ng\s+lint|nx\s+(lint|run-many|affected)\b.*\blint)(\s|$)/, bin: /^(.*\/)?(eslint|ng|nx)$/,
    selectFlags: ['-c', '--config'], excludeFlags: ['--ignore-pattern'], strictFlags: ['--max-warnings'],
    valueFlags: ['--ext', '-f', '--format', '-o', '--output-file', '--rulesdir', '--cache-location', '--parser', '--rule', '--resolve-plugins-relative-to'],
    appliesTo: '**/*.{js,jsx,ts,tsx}',
  }),
  T('prettier', 'Prettier', 'format', {
    configs: [/(^|\/)\.prettierrc(\.(json|ya?ml|json5|js|cjs|mjs|toml))?$/, /(^|\/)prettier\.config\.(js|cjs|mjs)$/],
    runs: /\bprettier\b.*\s(--check|-c|--list-different|-l)(\s|$)|\bnx\s+format:check\b/, bin: /^(.*\/)?(prettier|nx)$/,
    selectFlags: ['--config'], excludeFlags: ['--ignore-path'], valueFlags: ['--log-level', '--parser'],
  }),
  T('stylelint', 'Stylelint', 'lint', {
    configs: [/(^|\/)\.stylelintrc(\.(json|ya?ml|js|cjs))?$/, /(^|\/)stylelint\.config\.(js|cjs|mjs)$/],
    runs: /\bstylelint\b/, bin: /^(.*\/)?stylelint$/, selectFlags: ['--config'], excludeFlags: ['--ignore-pattern'],
    strictFlags: ['--max-warnings'], valueFlags: ['-f', '--formatter', '--ignore-path', '--config-basedir', '--custom-syntax'], appliesTo: '**/*.{css,scss}',
  }),
  T('biome', 'Biome', 'lint', {
    configs: [/(^|\/)biome\.jsonc?$/], runs: /\bbiome\s+(check|ci|lint)\b/, bin: /^(.*\/)?biome$/,
    sub: ['check', 'ci', 'lint'], selectFlags: ['--config-path'], strictRe: /(^|\s)--error-on-warnings(\s|=|$)/,
  }),
  T('typescript', 'TypeScript compiler', 'compiler', {
    aliases: ['tsc'], configs: [/(^|\/)tsconfig(\.[\w-]+)?\.json$/], runs: /(^|[\s/])(tsc|vue-tsc)(\s|$)|\bng\s+build\b/,
    reject: /--(version|help|init)\b/, bin: /^(.*\/)?(tsc|vue-tsc|ng)$/, selectFlags: ['-p', '--project', '-b', '--build'],
    observe: /\b(typescript|tsc|vue-tsc)\b/i, appliesTo: '**/*.ts',
  }),
  T('editorconfig', 'EditorConfig', 'format', { configs: [/(^|\/)\.editorconfig$/] }),
  T('msbuild', 'MSBuild', 'compiler', {
    aliases: ['dotnet'], configs: [/(^|\/)Directory\.Build\.props$/, /\.csproj$/], runs: /\bdotnet\s+(build|test)\b|\bmsbuild\b/i,
    bin: /^(.*\/)?(dotnet|msbuild)(\.exe)?$/i, sub: ['build', 'test'], observe: /\b(msbuild|dotnet)\b/i, appliesTo: CS,
  }),
  T('stylecop', 'StyleCop', 'analyzer', { aliases: ['stylecop.analyzers'], configs: [/(^|\/)stylecop\.json$/], appliesTo: CS }),
  T('phpcs', 'PHP_CodeSniffer', 'lint', {
    aliases: ['php_codesniffer'], configs: [/(^|\/)\.?phpcs\.xml(\.dist)?$/], runs: /\bphpcs\b/, bin: /^(.*\/)?phpcs$/,
    selectFlags: ['--standard'], excludeFlags: ['--ignore'], valueFlags: ['--report', '--extensions'], appliesTo: PHP,
  }),
  T('phpstan', 'PHPStan', 'analyzer', {
    configs: [/(^|\/)phpstan\.neon(\.dist)?$/], runs: /\bphpstan\s+analy[sz]e\b/, bin: /^(.*\/)?phpstan$/,
    sub: ['analyse', 'analyze'], selectFlags: ['-c', '--configuration'], valueFlags: ['-l', '--level', '--memory-limit'], appliesTo: PHP,
  }),
  T('php-cs-fixer', 'PHP CS Fixer', 'format', {
    configs: [/(^|\/)\.php-cs-fixer(\.dist)?\.php$/, /(^|\/)\.php_cs(\.dist)?$/], runs: /php-cs-fixer\s+fix\b.*--dry-run/,
    bin: /^(.*\/)?php-cs-fixer$/, sub: ['fix'], selectFlags: ['--config'], appliesTo: PHP,
  }),
  T('psalm', 'Psalm', 'analyzer', { configs: [/(^|\/)psalm\.xml(\.dist)?$/], runs: /\bpsalm\b/, bin: /^(.*\/)?psalm$/, selectFlags: ['-c', '--config'], appliesTo: PHP }),
  T('ruff', 'Ruff', 'lint', {
    configs: [/(^|\/)\.?ruff\.toml$/, /(^|\/)pyproject\.toml$/], section: 'tool.ruff', runs: /\bruff\s+(check\b|format\b.*--check)/,
    bin: /^(.*\/)?ruff$/, sub: ['check', 'format'], selectFlags: ['--config'], excludeFlags: ['--exclude', '--extend-exclude'], appliesTo: PY,
  }),
  T('black', 'Black', 'format', {
    configs: [/(^|\/)pyproject\.toml$/], section: 'tool.black', runs: /\bblack\b.*--check/, bin: /^(.*\/)?black$/,
    selectFlags: ['--config'], excludeFlags: ['--exclude', '--extend-exclude'], appliesTo: PY,
  }),
  T('mypy', 'mypy', 'analyzer', {
    configs: [/(^|\/)\.?mypy\.ini$/, /(^|\/)pyproject\.toml$/, /(^|\/)setup\.cfg$/], section: 'mypy', runs: /\bmypy\b/,
    bin: /^(.*\/)?mypy$/, selectFlags: ['--config-file'], excludeFlags: ['--exclude'], appliesTo: PY,
  }),
  T('flake8', 'Flake8', 'lint', {
    configs: [/(^|\/)\.flake8$/, /(^|\/)setup\.cfg$/, /(^|\/)tox\.ini$/], section: 'flake8', runs: /\bflake8\b/,
    bin: /^(.*\/)?flake8$/, selectFlags: ['--config'], excludeFlags: ['--exclude', '--extend-exclude'], appliesTo: PY,
  }),
  T('golangci', 'golangci-lint', 'lint', {
    aliases: ['golangci-lint'], configs: [/(^|\/)\.golangci\.(ya?ml|toml)$/], runs: /golangci-lint\s+run\b/,
    bin: /^(.*\/)?golangci-lint$/, sub: ['run'], selectFlags: ['-c', '--config'], observe: /\bgolangci(-lint)?\b/i, appliesTo: GO,
  }),
  T('gofmt', 'gofmt', 'format', { runs: /test\s+-z\s+"?\$\(\s*gofmt\s+-l/, bin: /^(.*\/)?gofmt$/, observe: /\bgofmt\b|\bgo\s+fmt\b/, appliesTo: GO }),
  T('govet', 'go vet', 'analyzer', { aliases: ['go vet'], runs: /\bgo\s+vet\b/, bin: /^go$/, sub: ['vet'], observe: /\bgo\s+vet\b/, appliesTo: GO }),
  T('rustfmt', 'rustfmt', 'format', {
    configs: [/(^|\/)\.?rustfmt\.toml$/], runs: /\bcargo\s+fmt\b.*--check|\brustfmt\b.*--check/, bin: /^(.*\/)?(cargo|rustfmt)$/,
    sub: ['fmt'], stopAt: '--', observe: /\brustfmt\b|\bcargo\s+fmt\b/, appliesTo: RS,
  }),
  // Clippy's lint levels live on the command line, not in clippy.toml: only a run that denies warnings checks.
  T('clippy', 'Clippy', 'lint', {
    configs: [/(^|\/)\.?clippy\.toml$/], runs: /\bcargo\s+clippy\b/, bin: /^(.*\/)?cargo$/, sub: ['clippy'], stopAt: '--',
    strictRe: /(^|[\s=])(-D\s*warnings|--deny[=\s]+warnings)(\s|$)/, requireStrict: true, appliesTo: RS,
  }),
  T('rubocop', 'RuboCop', 'lint', { configs: [/(^|\/)\.rubocop\.ya?ml$/], runs: /\brubocop\b/, bin: /^(.*\/)?rubocop$/, selectFlags: ['-c', '--config'], appliesTo: '**/*.rb' }),
  T('dotnet-format', 'dotnet format', 'format', {
    aliases: ['dotnet format'], runs: /\bdotnet\s+format\b.*--verify-no-changes/, bin: /^(.*\/)?dotnet$/, sub: ['format'],
    observe: /\bdotnet\s+format\b/, appliesTo: CS,
  }),
];
const BY_ID = new Map(TOOLS.map((t) => [t.tool, t]));
const HARNESS = /^(\.claude|\.agents|\.codex)\//;
const WIRING = /(^|\/)(package\.json|composer\.json|Makefile|Jenkinsfile|\.gitlab-ci\.yml|bitbucket-pipelines\.yml|\.pre-commit-config\.yaml|\.lintstagedrc(\.\w+)?)$|^\.github\/workflows\/[^/]+\.ya?ml$|(^|\/)azure-pipelines[^/]*\.ya?ml$|^\.husky\/[^/]+$/;
const STRICT_PROPS = /^(TreatWarningsAsErrors|EnforceCodeStyleInBuild)$/;
// A segment that installs, removes or only names a tool — never a checking run (`pip install flake8`).
const NOT_A_RUN = /^\s*(?:\w+=\S*\s+)*(?:sudo\s+)?(?:(?:(?:(?:python3?|py)\s+-m\s+)?(?:pip3?|pipx|uv\s+pip|poetry|npm|yarn|pnpm|bun|gem|bundle|composer|go|cargo|brew|apt(?:-get)?|apk|choco|dotnet\s+tool)\s+(?:global\s+)?(?:install|i|add|require|uninstall|remove|rm|ls|list|why|view|info|show|outdated|update|upgrade|up|audit|explain)\b)|echo\b|printf\b|which\b|command\s+-v\b)/;
// An informational mode prints and exits 0 whatever the code holds (`eslint --version`, `tsc --showConfig`).
const INFO_ONLY = /(^|\s)--(version|help|init|showConfig|print-config)(\s|=|$)/;

const posix = (...p) => { const j = path.posix.normalize(path.posix.join(...p)); return j === '.' ? '' : j.replace(/\/$/, ''); };
const under = (a, b) => b === '' || a === b || a.startsWith(`${b}/`);
const dirOf = (p) => { const d = path.posix.dirname(p); return d === '.' ? '' : d; };
const uniq = (a) => [...new Set(a)];
const lineOf = (lines, needle, from = 0) => { for (let i = from; i < lines.length; i++) if (lines[i].includes(needle)) return i + 1; return 1; };

// realpath containment: a relative path with no `..` segment whose real file lies inside the repo.
function safeRead(repo, rel, realRepo) {
  if (path.isAbsolute(rel) || rel.split('/').includes('..')) return { outside: true };
  let real;
  try { real = fs.realpathSync(path.join(repo, rel)); } catch { return { error: true }; }
  if (real !== realRepo && !real.startsWith(realRepo + path.sep)) return { outside: true };
  try { if (!fs.statSync(real).isFile()) return { outside: true }; return { text: fs.readFileSync(real, 'utf8') }; } catch { return { error: true }; }
}

function stripJsonc(text) {
  let out = '';
  for (let i = 0, str = false; i < text.length; i++) {
    const c = text[i];
    if (str) { out += c; if (c === '\\') out += text[++i] ?? ''; else if (c === '"') str = false; continue; }
    if (c === '"') { str = true; out += c; } else if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; out += '\n'; } else if (c === '/' && text[i + 1] === '*') { const e = text.indexOf('*/', i + 2); const chunk = text.slice(i, e < 0 ? text.length : e + 2); out += chunk.replace(/[^\n]/g, ''); i = e < 0 ? text.length : e + 1; } else out += c;
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}

function kindOf(p) {
  const b = path.posix.basename(p);
  if (/\.(json|jsonc|json5)$/.test(b) || /^\.(eslintrc|stylelintrc|prettierrc)$/.test(b)) return 'json';
  if (/\.ya?ml$|\.neon(\.dist)?$/.test(b)) return 'yaml';
  if (/\.toml$/.test(b)) return 'toml';
  if (/\.(js|mjs|cjs|ts)$/.test(b)) return 'jsregex';
  if (/\.php$|^\.php_cs/.test(b)) return 'phpregex';
  if (/\.(xml|props|csproj)(\.dist)?$/.test(b)) return 'xml';
  return 'ini';
}

const SEVERITY_OFF = new Set(['off', '0', 'false', 'null']);
function fromObject(t, obj, lines, q) {
  const rules = [];
  const presets = [];
  const at = (k) => lineOf(lines, q(k));
  const addPresets = (v) => { for (const n of [].concat(v ?? [])) if (typeof n === 'string') presets.push({ name: n, line: at(n) }); };
  if (t.tool === 'eslint' || t.tool === 'stylelint') {
    for (const [k, v] of Object.entries(obj.rules || {})) {
      const sev = String(Array.isArray(v) ? v[0] : v);
      if (!SEVERITY_OFF.has(sev)) rules.push({ rule: k, setting: sev === '2' ? 'error' : sev === '1' ? 'warn' : sev, line: at(k) });
    }
    addPresets(obj.extends);
  } else if (t.tool === 'typescript') {
    for (const [k, v] of Object.entries(obj.compilerOptions || {})) {
      if (/^(strict\w*|noImplicit\w*|noUnused\w*|noFallthroughCasesInSwitch|exactOptionalPropertyTypes|noUncheckedIndexedAccess)$/.test(k) && v !== false) rules.push({ rule: k, setting: String(v), line: at(k) });
    }
    addPresets(obj.extends);
  } else {
    addPresets(t.tool === 'phpstan' || t.tool === 'rubocop' ? obj.includes ?? obj.inherit_from : obj.extends);
    const walk = (o) => {
      for (const [k, v] of Object.entries(o)) {
        if (['extends', 'includes', 'inherit_from', '$schema'].includes(k)) continue;
        if (Array.isArray(v)) { for (const s of v) if (typeof s !== 'object') rules.push({ rule: String(s), setting: k, line: lineOf(lines, String(s)) }); else if (s) walk(s); }
        // Biome's object form `"noVar": {"level": "warn", "options": {...}}` is one rule at that level.
        else if (v && typeof v === 'object' && t.tool === 'biome' && typeof v.level === 'string') rules.push({ rule: k, setting: v.level, line: at(k) });
        else if (v && typeof v === 'object') walk(v);
        else rules.push({ rule: k, setting: String(v), line: at(k) });
      }
    };
    walk(obj);
  }
  return { rules, presets };
}

function sectioned(text, t, file) {
  const lines = text.split(/\r?\n/);
  const shared = /(^|\/)(pyproject\.toml|setup\.cfg|tox\.ini)$/.test(file);
  const want = shared ? (t.section.startsWith('tool.') || file.endsWith('pyproject.toml') ? `tool.${t.tool}` : t.tool) : null;
  const rules = [];
  let sec = '';
  lines.forEach((l, i) => {
    const s = /^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$/.exec(l);
    if (s) { sec = s[1]; return; }
    const kv = /^\s*([\w.*@-]+)\s*[=:]\s*(.*)$/.exec(l);
    if (!kv || /^\s*[#;]/.test(l)) return;
    if (want && !(sec === want || sec.startsWith(`${want}.`) || sec.startsWith(`${want}:`))) return;
    rules.push({ rule: kv[1], setting: kv[2].trim(), line: i + 1 });
  });
  return { rules, presets: [], present: !want || rules.length > 0 || lines.some((l) => l.trim() === `[${want}]`) };
}

function extract(t, file, text) {
  const kind = kindOf(file);
  const lines = text.split(/\r?\n/);
  if (kind === 'json') {
    try { return fromObject(t, JSON.parse(stripJsonc(text)), lines, (k) => `"${k}"`); } catch (e) {
      if (/\.json5?$/.test(file)) throw e;
      return fromObject(t, parseYaml(text), lines, (k) => k);
    }
  }
  if (kind === 'yaml') {
    try { return fromObject(t, parseYaml(text), lines, (k) => k); } catch {
      const rules = [];
      lines.forEach((l, i) => { const m = /^\s*(?:-\s+)?([\w./@-]+)\s*(:|$)/.exec(l); if (m && !/^\s*#/.test(l)) rules.push({ rule: m[1], setting: '', line: i + 1 }); });
      return { rules, presets: [] };
    }
  }
  if (kind === 'toml' || kind === 'ini') return sectioned(text, t, file);
  const rules = [];
  const presets = [];
  const lineAt = (idx) => text.slice(0, idx).split('\n').length;
  if (kind === 'xml') {
    const re = t.tool === 'phpcs' ? /<rule\s+ref="([^"]+)"()/g : t.tool === 'psalm' ? /(errorLevel)="([^"]+)"/g
      : /<(Nullable|TreatWarningsAsErrors|WarningsAsErrors|AnalysisLevel|EnforceCodeStyleInBuild|CodeAnalysisTreatWarningsAsErrors)>([^<]*)</g;
    for (const m of text.matchAll(re)) rules.push({ rule: m[1], setting: m[2], line: lineAt(m.index) });
  } else if (kind === 'phpregex') {
    for (const m of text.matchAll(/'(@?[\w\\/-]+)'\s*=>\s*(true|\[)/g)) (m[1].startsWith('@') ? presets : rules).push(m[1].startsWith('@') ? { name: m[1], line: lineAt(m.index) } : { rule: m[1], setting: m[2], line: lineAt(m.index) });
  } else if (t.tool === 'eslint' || t.tool === 'stylelint') {
    const re = /(?:'([^'\n]+)'|"([^"\n]+)"|\b([A-Za-z_$][\w$/-]*))\s*:\s*\[?\s*(['"]?)(error|warn|off|0|1|2)\4(?=[\s,\]}])/g;
    for (const m of text.matchAll(re)) {
      const sev = m[5] === '2' ? 'error' : m[5] === '1' ? 'warn' : m[5];
      if (!SEVERITY_OFF.has(sev)) rules.push({ rule: m[1] ?? m[2] ?? m[3], setting: sev, line: lineAt(m.index) });
    }
    for (const m of text.matchAll(/\b([\w$]+\.configs(?:\.[\w$]+\b(?!\s*\()|\[\s*['"][^'"]+['"]\s*\])+)/g)) presets.push({ name: m[1], line: lineAt(m.index) });
    for (const m of text.matchAll(/extends\s*:\s*(\[[^\]]*\]|['"][^'"]+['"])/g)) for (const s of m[1].matchAll(/['"]([^'"]+)['"]/g)) presets.push({ name: s[1], line: lineAt(m.index) });
  } else {
    for (const m of text.matchAll(/^\s*['"]?([A-Za-z_$][\w$-]*)['"]?\s*:\s*([^,\n{[]+)/gm)) rules.push({ rule: m[1], setting: m[2].trim(), line: lineAt(m.index) });
  }
  return { rules, presets };
}

// One checking invocation parsed per tool: positional targets, excludes, an explicit selection and
// the strict flag. null when the text is not a checking invocation of that tool. `isPath` tells
// whether a token names a scanned path: a token right after an unknown flag is that flag's value
// unless it looks like a path or names one; the default treats every token as a path (a target).
const unquote = (s) => s.replace(/^["']|["']$/g, '');
export function parseRun(toolId, text, isPath = () => true) {
  const t = BY_ID.get(toolId);
  if (!t || !t.runs || !t.runs.test(text) || (t.reject && t.reject.test(text)) || NOT_A_RUN.test(text) || INFO_ONLY.test(text)) return null;
  const bare = text.replace(/["']/g, ' ');
  if (t.requireStrict && !t.strictRe.test(bare)) return null;
  const toks = text.trim().match(/"[^"]*"|'[^']*'|\S+/g) || [];
  let i = toks.findIndex((x) => t.bin.test(unquote(x)));
  const run = { targets: [], excludes: [], selected: null, strict: false, scopeUnknown: false };
  if (t.strictRe && t.strictRe.test(bare)) run.strict = true;
  // No binary token: a run only when the binary sits in a command substitution (`test -z "$(gofmt -l .)"`).
  if (i < 0) return toks.some((x) => { const m = /\$\(\s*([^\s)]+)/.exec(x); return m && t.bin.test(m[1]); }) ? run : null;
  if (/^(.*\/)?(ng|nx)$/.test(toks[i])) return run;
  i += 1;
  while (i < toks.length && t.sub.includes(toks[i])) i++;
  const flagVal = (tok, eq) => (eq >= 0 ? tok.slice(eq + 1) : toks[++i]);
  // pending: the previous token was a flag of none of the tool's lists, with no `=` (a bare `--` too).
  let pending = false;
  for (; i < toks.length; i++) {
    const tok = toks[i];
    if (/^\d*[<>]/.test(tok)) break;
    // `cargo clippy -- -D warnings`: what follows `--` goes to the linter (lint levels), never a target.
    if (t.stopAt && tok === t.stopAt) break;
    const after = pending;
    pending = false;
    if (tok.startsWith('-')) {
      const eq = tok.indexOf('=');
      const name = eq >= 0 ? tok.slice(0, eq) : tok;
      if (t.selectFlags.includes(name)) { const v = flagVal(tok, eq); run.selected = v == null ? null : unquote(v); }
      else if (t.excludeFlags.includes(name)) run.excludes.push(unquote(String(flagVal(tok, eq) ?? '')));
      else if (t.strictFlags.includes(name)) run.strict = String(flagVal(tok, eq)) === '0';
      else if (t.valueFlags.includes(name)) { if (eq < 0) i++; }
      else pending = eq < 0;
      continue;
    }
    if (/[$`(]/.test(tok)) { run.scopeUnknown = true; continue; }
    const target = unquote(tok).replace(/^\.\//, '').replace(/\/?\.\.\.$/, '').replace(/\/$/, '');
    // `--timeout 5m`, `--output-format github`: a bare word after an unknown flag that names no path is its value.
    if (after && !/[*?[{/]/.test(target) && !/\.[A-Za-z][A-Za-z0-9]{0,4}$/.test(target) && !isPath(target)) continue;
    if (target && target !== '.') run.targets.push(target);
  }
  return run;
}

// Every command a wiring file runs: { text, at, dir, key }.
function commands(file, text) {
  const lines = text.split(/\r?\n/);
  const base = path.posix.basename(file);
  const out = [];
  if (base === 'package.json' || base === 'composer.json') {
    let obj;
    try { obj = JSON.parse(text); } catch { return out; }
    for (const field of ['scripts', 'lint-staged']) {
      const from = lineOf(lines, `"${field}"`) - 1;
      for (const [key, v] of Object.entries(obj[field] || {})) {
        for (const cmd of [].concat(v)) if (typeof cmd === 'string') out.push({ text: cmd, at: `${file}:${lineOf(lines, `"${key}"`, from)}`, dir: dirOf(file), key });
      }
    }
    return out;
  }
  const ci = /\.ya?ml$/.test(file) || base === 'Jenkinsfile';
  const runDir = /^\.github\/|(^|\/)(\.gitlab-ci\.yml|bitbucket-pipelines\.yml|azure-pipelines|Jenkinsfile)|^\.husky\//.test(file) ? '' : dirOf(file);
  lines.forEach((raw, i) => {
    if (/^\s*#/.test(raw) || (ci && /^\s*-?\s*(name|uses|id|if|with|env|runs-on|image|stage|on|description)\s*:/.test(raw))) return;
    const txt = raw.replace(/^\s*-\s+/, '').replace(/^\s*(run|script|before_script|after_script|command|cmd|entry)\s*:\s*[|>]?-?\s*/, '').replace(/^\s*[@-]?/, '');
    if (!txt.trim()) return;
    let dir = runDir;
    if (ci) {
      const ind = (l) => l.length - l.trimStart().length;
      let s = i; while (s > 0 && !/^\s*-\s/.test(lines[s])) s--;
      let e = i + 1; while (e < lines.length && !(/^\s*-\s/.test(lines[e]) && ind(lines[e]) <= ind(lines[s]))) e++;
      const wd = lines.slice(s, e).map((l) => /working-directory\s*:\s*['"]?([^'"\s]+)/.exec(l)).find(Boolean);
      if (wd) dir = posix(wd[1]);
    }
    out.push({ text: txt, at: `${file}:${i + 1}`, dir, key: '' });
  });
  return out;
}

// isPath(dir, token): whether the token, resolved against the run directory, names a scanned path.
function runsOf(cmds, isPath) {
  const runs = [];
  const seen = new Set();
  for (const c of cmds) {
    let dir = c.dir;
    const parts = c.text.split(/(&&|\|\||;|\|)/);
    for (let k = 0; k < parts.length; k += 2) {
      const seg = parts[k];
      const cd = /^\s*cd\s+(\S+)\s*$/.exec(seg);
      if (cd) { dir = posix(dir, cd[1]); continue; }
      // `eslint src || true`: a failure the command swallows is observed, never a checking run.
      const masked = parts[k + 1] === '||' && /^\s*(true|:|exit\s+0|echo\b.*)\s*$/.test(parts[k + 2] || '');
      for (const t of TOOLS) {
        if (t.observe.test(seg)) seen.add(t.tool);
        if (masked || (/fix/i.test(c.key) && /--fix\b/.test(seg))) continue;
        const r = parseRun(t.tool, seg, (x) => isPath(dir, x));
        if (r) runs.push({ tool: t.tool, at: c.at, dir, command: seg.trim(), legacyFlag: /ESLINT_USE_FLAT_CONFIG=false/.test(seg), ...r });
      }
    }
  }
  return { runs, seen };
}

export function scan({ repo, files }) {
  const realRepo = fs.realpathSync(repo);
  const ignored = [];
  const unparsed = [];
  const cfgFiles = new Map();
  const wiring = [];
  for (const f of uniq(files.map((x) => x.split(path.sep).join('/'))).sort()) {
    const tools = TOOLS.filter((t) => t.configs.some((re) => re.test(f)));
    const wires = WIRING.test(f);
    if (!tools.length && !wires) continue;
    if (HARNESS.test(f)) { ignored.push({ path: f, reason: 'harness' }); continue; }
    const r = safeRead(repo, f, realRepo);
    if (r.outside) { ignored.push({ path: f, reason: 'outside' }); continue; }
    if (r.error) { unparsed.push(f); continue; }
    if (tools.length) cfgFiles.set(f, { tools, text: r.text });
    if (wires) wiring.push({ file: f, text: r.text });
  }
  const hasProject = files.some((f) => /\.(csproj|sln)$/.test(f) && !HARNESS.test(f));
  const fileSet = new Set(files);
  const isPath = (dir, x) => { const p = posix(dir, x); return p === '' || fileSet.has(p) || files.some((f) => f.startsWith(`${p}/`)); };
  const { runs, seen } = runsOf(wiring.flatMap((w) => commands(w.file, w.text)), isPath);
  const rootPkg = wiring.find((w) => w.file === 'package.json');
  let eslintMajor = 0;
  try { const p = JSON.parse(rootPkg.text); eslintMajor = Number(/\d+/.exec((p.devDependencies || {}).eslint || (p.dependencies || {}).eslint || '')?.[0] || 0); } catch { /* no root package.json */ }

  const configs = new Map(TOOLS.map((t) => [t.tool, []]));
  for (const [f, { tools, text }] of cfgFiles) {
    for (const t of tools) {
      let got;
      try { got = extract(t, f, text); } catch { got = null; }
      if (got && got.present === false) continue;
      if (t.tool === 'msbuild' && got && !got.rules.length) continue;
      if (!got && !unparsed.includes(f)) unparsed.push(f);
      configs.get(t.tool).push({ path: f, dir: dirOf(f), parsed: !!got, presets: got ? got.presets : [], rules: got ? got.rules : [], attributed: false, notEnforced: [] });
    }
  }

  const out = { tools: [], observed: [], unparsed, unattributed: [], notLoaded: [], scopeUnknown: [], ignored };
  const strictProp = (c) => c.rules.some((r) => (STRICT_PROPS.test(r.rule) && /^true$/i.test(r.setting)) || (r.rule === 'WarningsAsErrors' && r.setting.trim()));
  const msbuild = configs.get('msbuild');
  // EnforceCodeStyleInBuild acts only when a project is built: it needs a .csproj/.sln and a build run.
  const codeStyleInBuild = hasProject && runs.some((r) => r.tool === 'msbuild' && !r.scopeUnknown)
    && msbuild.some((c) => c.rules.some((r) => r.rule === 'EnforceCodeStyleInBuild' && /^true$/i.test(r.setting)));
  for (const t of TOOLS) {
    const cfgs = configs.get(t.tool).sort((a, b) => a.path.split('/').length - b.path.split('/').length || (a.path < b.path ? -1 : 1));
    const all = runs.filter((r) => r.tool === t.tool);
    if (!cfgs.length && !all.length) continue;
    const eff = all.filter((r) => !r.scopeUnknown);
    const selects = (r, c) => { const s = posix(r.dir, r.selected); return s === c.path || (s === c.dir && /(^|\/)tsconfig\.json$/.test(c.path)); };
    const external = eff.find((r) => r.selected && !cfgs.some((c) => selects(r, c)));
    const covers = (r, c) => {
      // `tsc a.ts` compiles the named files and ignores tsconfig.json; only a project build checks a config.
      if (t.tool === 'typescript') return r.selected ? selects(r, c) : !r.targets.some((x) => /\.[cm]?tsx?$/.test(x)) && c.dir === r.dir && /(^|\/)tsconfig\.json$/.test(c.path);
      if (t.tool === 'msbuild') return hasProject && strictProp(c);
      // `eslint -c <file>` loads that config only; a selection naming no config of this tool keeps directory coverage.
      if (r.selected && cfgs.some((o) => selects(r, o))) return selects(r, c);
      if (c.dir === r.dir) return true;
      return under(c.dir, r.dir) && (!r.targets.length || r.targets.some((x) => under(c.dir, posix(r.dir, x.split('*')[0]))));
    };
    const enforcing = new Set();
    for (const c of cfgs) {
      const cov = t.tool === 'editorconfig' ? [] : eff.filter((r) => covers(r, c));
      const legacy = t.tool === 'eslint' && !/eslint\.config\./.test(c.path);
      const loaded = !legacy || !(cfgs.some((o) => o.dir === c.dir && /eslint\.config\./.test(o.path)) || (eslintMajor >= 9 && !cov.some((r) => r.legacyFlag)));
      if (t.tool === 'editorconfig') {
        const errs = c.rules.filter((r) => /^dotnet_diagnostic\..*\.severity$/.test(r.rule) && r.setting === 'error');
        c.attributed = codeStyleInBuild && errs.length > 0;
        if (c.attributed) c.notEnforced = c.rules.filter((r) => !errs.includes(r)).map((r) => r.rule);
        continue;
      }
      c.attributed = cov.length > 0 && loaded;
      if (cov.length && !loaded) out.notLoaded.push(c.path);
      else if (!cov.length && eff.length && t.class !== 'compiler') out.unattributed.push(c.path);
      if (!c.attributed) continue;
      cov.forEach((r) => enforcing.add(r));
      if (cov.every((r) => r.selected && !selects(r, c)) && t.tool !== 'typescript') c.notEnforced = c.rules.map((r) => r.rule);
      // Biome: an `info` rule never fails a run and an `off` rule is disabled, strict or not.
      else if (t.tool === 'biome') c.notEnforced = c.rules.filter((r) => r.setting === 'info' || r.setting === 'off' || (r.setting === 'warn' && !cov.some((x) => x.strict))).map((r) => r.rule);
      else if ((t.tool === 'eslint' || t.tool === 'stylelint') && !cov.some((r) => r.strict)) c.notEnforced = c.rules.filter((r) => r.setting === 'warn').map((r) => r.rule);
    }
    if (external) enforcing.add(external);
    if (!cfgs.length) eff.forEach((r) => enforcing.add(r));
    const er = all.filter((r) => enforcing.has(r));
    let enforced;
    let by = null;
    if (t.tool === 'typescript' || t.tool === 'editorconfig') {
      enforced = cfgs.some((c) => c.attributed); by = 'build';
    } else if (t.tool === 'msbuild') {
      enforced = hasProject && eff.length > 0 && cfgs.some(strictProp); by = 'build';
      if (!enforced) cfgs.forEach((c) => { c.attributed = false; });
    } else if (cfgs.length) {
      enforced = cfgs.some((c) => c.attributed) || !!external; by = 'wired';
    } else {
      enforced = er.length > 0; by = 'ci';
    }
    if (!enforced) { by = null; if (all.some((r) => r.scopeUnknown)) out.scopeUnknown.push(t.tool); }
    // A compiler run checks the projects it builds: TypeScript's scope is each attributed config's directory.
    const applies = !enforced ? []
      : t.tool === 'typescript' ? uniq(cfgs.filter((c) => c.attributed).map((c) => (c.dir ? `${c.dir}/${t.appliesTo}` : t.appliesTo)))
        : uniq(er.flatMap((r) => (r.targets.length ? r.targets.map((x) => { const j = posix(r.dir, x); return /[*?]/.test(j) ? j : `${j}/**`; }) : [r.dir ? `${r.dir}/**` : t.appliesTo])));
    out.tools.push({
      tool: t.tool, display: t.display, class: t.class, aliases: t.aliases,
      configs: cfgs.map(({ dir, ...c }) => c),
      runs: all.map((r) => ({ at: r.at, targets: r.targets, excludes: r.excludes, selected: r.selected, strict: r.strict, scopeUnknown: r.scopeUnknown })),
      selected: external ? external.selected : null,
      wiredBy: cfgs.length && enforced ? uniq(er.map((r) => r.at)) : [],
      ciChecks: !cfgs.length && enforced ? er.map((r) => ({ command: r.command, at: r.at })) : [],
      enforced, enforcedBy: by,
      appliesTo: enforced && !applies.length ? [t.appliesTo] : applies,
      appliesExcept: enforced ? uniq(er.flatMap((r) => r.excludes.map((x) => posix(r.dir, x)))) : [],
    });
  }
  const obs = new Set();
  for (const t of TOOLS) if (seen.has(t.tool) || configs.get(t.tool).length) [t.tool, ...t.aliases].forEach((n) => obs.add(n.toLowerCase()));
  out.observed = [...obs].sort();
  return out;
}

function main(argv) {
  const usage = (msg) => { process.stderr.write(`standards-tools: ${msg}\n`); process.exit(2); };
  if (argv[0] !== 'scan') usage('usage: scan --repo <dir> [--files-from <file>]');
  const opt = {};
  for (let i = 1; i < argv.length; i += 2) {
    if (!['--repo', '--files-from'].includes(argv[i]) || argv[i + 1] === undefined) usage(`unknown or incomplete option ${argv[i]}`);
    opt[argv[i].slice(2)] = argv[i + 1];
  }
  if (!opt.repo || !fs.existsSync(opt.repo)) usage('--repo <dir> is required and must exist');
  let raw;
  try {
    raw = opt['files-from'] ? fs.readFileSync(opt['files-from'], 'utf8') : execFileSync('git', ['-C', opt.repo, 'ls-files', '-z', '-co', '--exclude-standard'], { encoding: 'utf8', maxBuffer: 1 << 28 });
  } catch (e) { usage(`cannot read the file list: ${e.message.split('\n')[0]}`); }
  const files = raw.split(/\0|\r?\n/).filter(Boolean);
  process.stdout.write(`${JSON.stringify(scan({ repo: opt.repo, files }), null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
