// A deliberately small JSON-Schema subset validator: type, required, properties,
// additionalProperties, enum, const, items, minItems, minimum, pattern, oneOf/anyOf (by validity).
// Returns a list of `path: message` strings; empty means valid.

export function validate(schema, value, at = '$', root = schema) {
  if (schema.$ref) {
    if (!schema.$ref.startsWith('#/')) throw new Error(`only local $ref supported: ${schema.$ref}`);
    const target = schema.$ref.slice(2).split('/').reduce((o, k) => o?.[k], root);
    if (!target) throw new Error(`unresolved $ref ${schema.$ref}`);
    return validate(target, value, at, root);
  }
  const errors = [];
  const fail = (msg) => errors.push(`${at}: ${msg}`);
  if (schema.const !== undefined && value !== schema.const) fail(`must equal ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.includes(value)) fail(`must be one of ${schema.enum.join('|')}`);
  if (schema.type) {
    const types = [].concat(schema.type);
    if (!types.some((t) => matchesType(t, value))) {
      fail(`expected ${types.join('|')}, got ${describe(value)}`);
      return errors;
    }
  }
  if (typeof value === 'string' && schema.pattern && !new RegExp(schema.pattern).test(value)) {
    fail(`does not match ${schema.pattern}`);
  }
  if (typeof value === 'string' && schema.minLength !== undefined && value.length < schema.minLength) {
    fail(`shorter than ${schema.minLength}`);
  }
  if (typeof value === 'number' && schema.minimum !== undefined && value < schema.minimum) {
    fail(`below minimum ${schema.minimum}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) fail(`fewer than ${schema.minItems} items`);
    if (schema.items) value.forEach((v, i) => errors.push(...validate(schema.items, v, `${at}[${i}]`, root)));
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) fail(`missing required property "${key}"`);
    }
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(value)) {
      if (k in props) errors.push(...validate(props[k], v, `${at}.${k}`, root));
      else if (schema.additionalProperties === false) fail(`unexpected property "${k}"`);
      else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') {
        errors.push(...validate(schema.additionalProperties, v, `${at}.${k}`, root));
      }
    }
  }
  for (const combinator of ['oneOf', 'anyOf']) {
    if (!schema[combinator]) continue;
    const passes = schema[combinator].filter((s) => validate(s, value, at, root).length === 0).length;
    if (combinator === 'anyOf' && passes === 0) fail('matches none of anyOf');
    if (combinator === 'oneOf' && passes !== 1) fail(`matches ${passes} of oneOf, expected exactly 1`);
  }
  return errors;
}

function matchesType(t, v) {
  switch (t) {
    case 'string': return typeof v === 'string';
    case 'number': return typeof v === 'number' && Number.isFinite(v);
    case 'integer': return Number.isInteger(v);
    case 'boolean': return typeof v === 'boolean';
    case 'null': return v === null;
    case 'array': return Array.isArray(v);
    case 'object': return v !== null && typeof v === 'object' && !Array.isArray(v);
    default: return false;
  }
}

function describe(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  return typeof v;
}

export function assertValid(schema, value, label) {
  const errors = validate(schema, value);
  if (errors.length) throw new Error(`${label} invalid:\n  ${errors.join('\n  ')}`);
  return value;
}
