// policy.mjs — the pure destination classifier. Every connection the browser makes (each redirect
// hop, subresource and CONNECT tunnel) is decided here by the proxy.
import { privateAddressClass, resolveAddresses } from '../../../audit-security/scripts/lib/smoke.mjs';
import { Refusal } from './paths.mjs';

export { privateAddressClass, resolveAddresses };

const ALWAYS_BLOCKED = new Set(['link-local', 'unspecified', 'multicast', 'reserved', 'not-an-ip']);
const PRIVATE = new Set(['private', 'unique-local', 'shared-address-space']);

export function addressClass(address) {
  const c = privateAddressClass(address);
  if (c === null) return 'public';
  if (PRIVATE.has(c)) return 'private';
  return c;
}

function defaultPort(protocol) {
  return protocol === 'https:' ? '443' : '80';
}

export function originOf(url) {
  const u = url instanceof URL ? url : new URL(url);
  // An IPv6 literal keeps its brackets in URL.hostname; origins are compared bracket-free.
  return `${u.protocol}//${u.hostname.toLowerCase().replace(/^\[|\]$/g, '')}:${u.port || defaultPort(u.protocol)}`;
}

export function parseTarget(text) {
  let u;
  try { u = new URL(text); } catch { throw new Refusal('bad-url', `not a URL: ${String(text).slice(0, 80)}`); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Refusal('unsupported-scheme', `only http and https URLs can be scanned (${u.protocol})`);
  if (u.username || u.password) throw new Refusal('credentials-in-url', 'a URL with user:password@ is refused — v1 has no authentication');
  return u;
}

// The run class from the resolved addresses of every given URL: one class per run.
export function targetClass(targets) {
  const classes = new Set();
  for (const t of targets) {
    for (const a of t.addresses) {
      const c = addressClass(a);
      if (ALWAYS_BLOCKED.has(c)) throw new Refusal('destination-blocked', `${t.url.hostname} resolves to a ${c} address`);
      classes.add(c);
    }
  }
  if (classes.size > 1) throw new Refusal('mixed-target-class', 'all URLs must be public, all loopback, or all private — scan them in separate runs');
  return [...classes][0] ?? 'public';
}

export function givenOrigins(urls) {
  return new Set(urls.map((u) => originOf(u)));
}

// decide({scheme, host, port, addresses, runClass, origins}) → {allow, reason}. Any blocked address
// blocks the whole destination.
export function decide({ scheme = 'http', host, port, addresses, runClass, origins }) {
  if (!addresses || !addresses.length) return { allow: false, reason: 'dns-failed' };
  const given = origins.has(`${scheme}://${String(host).toLowerCase().replace(/^\[|\]$/g, '')}:${port}`);
  for (const a of addresses) {
    const c = addressClass(a);
    if (ALWAYS_BLOCKED.has(c)) return { allow: false, reason: c };
    if (c === 'public') continue;
    if (c !== runClass) return { allow: false, reason: `${c}-outside-run-class` };
    if (!given) return { allow: false, reason: `${c}-not-a-given-origin` };
  }
  return { allow: true, reason: 'ok' };
}
