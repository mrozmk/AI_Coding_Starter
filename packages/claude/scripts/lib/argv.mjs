// `--key value`, `--key=value`, `--flag`, and positionals. Repeated keys become arrays.
export function parseArgv(argv) {
  const opts = {};
  const positionals = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      positionals.push(a);
      continue;
    }
    let key = a.slice(2);
    let value = true;
    const eq = key.indexOf('=');
    if (eq !== -1) {
      value = key.slice(eq + 1);
      key = key.slice(0, eq);
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      value = argv[++i];
    }
    if (key in opts) opts[key] = [].concat(opts[key], value);
    else opts[key] = value;
  }
  return { opts, positionals };
}

export function requireOpt(opts, key, usage) {
  if (!(key in opts) || opts[key] === true) {
    throw new Error(`--${key} is required. ${usage ?? ''}`.trim());
  }
  return opts[key];
}
