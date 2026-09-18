// smoke.mjs — the passive exposure smoke behind `audit-runner.mjs smoke` (command: Phase 7).
// Deterministic SSRF / DNS-rebinding containment: every address a hostname resolves to is
// classified, a private class refuses the target, the connection is PINNED to one validated address
// through the socket `lookup` option (a second resolution can never redirect the connect), redirects
// are never followed automatically — each Location is re-validated with the same rules and must be
// same-origin. HEAD then GET of the base path only; no query, no body, no other path.
// node: builtins only — ships byte-identical to every downstream, like the runner.
import dns from 'node:dns';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';

const MAX_HOPS = 5;
const TIMEOUT_MS = 15_000;
const SECURITY_HEADERS = ['strict-transport-security', 'content-security-policy', 'x-content-type-options', 'x-frame-options', 'referrer-policy', 'permissions-policy'];
const BANNER_HEADERS = ['server', 'x-powered-by', 'x-aspnet-version', 'x-generator'];

// The class name when the address must not be contacted, null when it is a public unicast address.
export function privateAddressClass(ip) {
  const version = net.isIP(ip);
  if (version === 4) return v4Class(ip.split('.').map(Number));
  if (version !== 6) return 'not-an-ip';
  const h = ipv6Hextets(ip);
  const embedded = (hi, lo) => v4Class([hi >> 8, hi & 0xff, lo >> 8, lo & 0xff]);
  // Every IPv6 form that carries an IPv4 is judged as that IPv4: mapped ::ffff:0:0/96, NAT64
  // 64:ff9b::/96, 6to4 2002::/16. The WHATWG parser serialises `[::ffff:127.0.0.1]` as
  // `[::ffff:7f00:1]`, so the dotted form alone would let a loopback target through.
  if (h[0] === 0 && h[1] === 0 && h[2] === 0 && h[3] === 0 && h[4] === 0 && h[5] === 0xffff) return embedded(h[6], h[7]);
  if (h[0] === 0x64 && h[1] === 0xff9b && h[2] === 0 && h[3] === 0 && h[4] === 0 && h[5] === 0) return embedded(h[6], h[7]);
  if (h[0] === 0x2002) return embedded(h[1], h[2]);
  if (h.every((x) => x === 0)) return 'unspecified';
  if (h.slice(0, 7).every((x) => x === 0) && h[7] === 1) return 'loopback';
  if ((h[0] & 0xfe00) === 0xfc00) return 'unique-local';
  if ((h[0] & 0xffc0) === 0xfe80) return 'link-local';
  if ((h[0] & 0xff00) === 0xff00) return 'multicast';
  return null;
}

// The eight 16-bit groups of a valid IPv6 text: zone id dropped, `::` expanded, a dotted IPv4 tail
// folded into the last two groups.
function ipv6Hextets(ip) {
  let text = ip.toLowerCase().replace(/%.*$/, '');
  const dotted = /(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (dotted) {
    const [a, b, c, d] = dotted[1].split('.').map(Number);
    text = `${text.slice(0, -dotted[1].length)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const [head, tail] = text.split('::');
  const hi = head ? head.split(':') : [];
  const lo = tail ? tail.split(':') : [];
  const zeros = tail === undefined ? [] : new Array(8 - hi.length - lo.length).fill('0');
  return [...hi, ...zeros, ...lo].map((g) => parseInt(g, 16));
}

function v4Class([a, b]) {
  if (a === 0) return 'unspecified';
  if (a === 10) return 'private';
  if (a === 127) return 'loopback';
  if (a === 169 && b === 254) return 'link-local';
  if (a === 172 && b >= 16 && b <= 31) return 'private';
  if (a === 192 && b === 168) return 'private';
  if (a === 100 && b >= 64 && b <= 127) return 'shared-address-space';
  if (a >= 240) return 'reserved';
  if (a >= 224) return 'multicast';
  return null;
}

export async function resolveAddresses(hostname, lookup = dns.promises.lookup) {
  const host = hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host)) return [host];
  const entries = await lookup(host, { all: true });
  const addresses = [...new Set((entries ?? []).map((e) => e.address).filter((a) => typeof a === 'string'))].sort();
  if (!addresses.length) throw new Error('no address');
  return addresses;
}

// The one gate a URL passes before it may be contacted — the base and every redirect hop alike.
// `pinned` is the single address the connection is bound to.
export async function validateTarget(urlText, { allowPrivate = false, lookup } = {}) {
  let url;
  try { url = new URL(urlText); } catch { return { ok: false, reason: 'invalid-url' }; }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return { ok: false, reason: `unsupported-scheme:${url.protocol.replace(/:$/, '')}` };
  if (url.username || url.password) return { ok: false, reason: 'credentials-in-url' };
  let addresses;
  try { addresses = await resolveAddresses(url.hostname, lookup); } catch (err) { return { ok: false, reason: `dns-failed:${err.code ?? err.message}` }; }
  const blocked = addresses.map((a) => [a, privateAddressClass(a)]).filter(([, c]) => c);
  if (blocked.length && !allowPrivate) return { ok: false, reason: `private-address:${blocked.map(([a, c]) => `${a}=${c}`).join(',')}` };
  return { ok: true, url, addresses, pinned: addresses[0] };
}

function certSummary(cert) {
  if (!cert || typeof cert !== 'object' || !cert.valid_to) return null;
  const to = new Date(cert.valid_to);
  return { subject: cert.subject?.CN ?? null, issuer: cert.issuer?.CN ?? null, valid_from: cert.valid_from ?? null, valid_to: cert.valid_to, days_left: Number.isNaN(to.getTime()) ? null : Math.floor((to.getTime() - Date.now()) / 86_400_000) };
}

// One request, connection pinned to `address`; the response body is discarded unread.
export function httpTransport({ url, method, address }) {
  return new Promise((resolve, reject) => {
    const mod = url.protocol === 'https:' ? https : http;
    const family = net.isIP(address);
    const req = mod.request(url, {
      method,
      agent: false,
      // net.connect asks with `all: true` when autoSelectFamily is on (Node 20+) and expects an array then.
      lookup: (host, opts, cb) => (opts?.all ? cb(null, [{ address, family }]) : cb(null, address, family)),
      headers: { 'user-agent': 'audit-security-smoke/1', accept: '*/*' },
      timeout: TIMEOUT_MS,
    }, (res) => {
      const sock = res.socket;
      const tls = typeof sock.getProtocol === 'function' ? { protocol: sock.getProtocol(), authorized: sock.authorized === true, certificate: certSummary(sock.getPeerCertificate()) } : null;
      const remote = { address: sock.remoteAddress ?? null, port: sock.remotePort ?? null };
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, tls, remote }));
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

function basePathOf(url) {
  return `${url.origin}${url.pathname}`;
}

// HEAD on the base, then GET following at most MAX_HOPS same-origin redirects, each hop re-validated.
export async function runSmoke({ url, outDir, allowPrivate = false, lookup, transport = httpTransport }) {
  const record = { schema_version: 1, base: String(url), allow_private: allowPrivate, started_utc: new Date().toISOString(), refused: null, contacted: [], hops: [] };
  const base = await validateTarget(url, { allowPrivate, lookup });
  if (!base.ok) {
    record.refused = base.reason;
    return persist(outDir, record);
  }
  const origin = base.url.origin;
  const basePath = basePathOf(base.url);
  record.base = basePath;
  const contact = async (method, target) => {
    const hop = { method, url: basePathOf(target.url), address: target.pinned, addresses: target.addresses };
    try {
      const res = await transport({ url: new URL(hop.url), method, address: target.pinned });
      Object.assign(hop, { status: res.status, headers: res.headers, tls: res.tls, remote: res.remote });
      record.contacted.push({ method, url: hop.url, pinned: target.pinned, remote: res.remote?.address ?? null });
    } catch (err) {
      hop.error = err.code ?? err.message;
    }
    record.hops.push(hop);
    return hop;
  };
  await contact('HEAD', base);
  let target = base;
  for (let n = 0; ; n += 1) {
    const hop = await contact('GET', target);
    const location = hop.status >= 300 && hop.status < 400 ? hop.headers?.location : null;
    if (!location) break;
    if (n >= MAX_HOPS) { record.hops.push({ method: 'GET', url: String(location), refused: 'too-many-redirects' }); break; }
    let next;
    try { next = new URL(location, hop.url); } catch { record.hops.push({ method: 'GET', url: String(location), refused: 'invalid-location' }); break; }
    if (next.origin !== origin) { record.hops.push({ method: 'GET', url: basePathOf(next), refused: 'cross-origin-redirect' }); break; }
    const v = await validateTarget(basePathOf(next), { allowPrivate, lookup });
    if (!v.ok) { record.hops.push({ method: 'GET', url: basePathOf(next), refused: v.reason }); break; }
    target = v;
  }
  return persist(outDir, record);
}

function persist(outDir, record) {
  record.finished_utc = new Date().toISOString();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'smoke.json'), `${JSON.stringify(record, null, 2)}\n`);
  fs.writeFileSync(path.join(outDir, 'smoke.md'), renderSmoke(record));
  return { ...record, outDir };
}

const clean = (v) => String(v ?? '').replace(/[\r\n\t]+/g, ' ').slice(0, 200);

export function renderSmoke(record) {
  const lines = [`- Base: \`${clean(record.base)}\` (passive: HEAD + GET of the base path, redirects recorded, never followed cross-origin)`];
  if (record.refused) {
    lines.push(`- **Refused before contact:** ${clean(record.refused)} — nothing was sent.`);
    return `${lines.join('\n')}\n`;
  }
  lines.push(`- Contacted: ${record.contacted.length ? record.contacted.map((c) => `${c.method} ${clean(c.url)} → ${c.remote ?? c.pinned}`).join('; ') : 'nothing (every request failed)'}`);
  const final = [...record.hops].reverse().find((h) => h.status) ?? null;
  const tls = final?.tls;
  lines.push(tls ? `- TLS: ${tls.protocol ?? '?'}, certificate ${tls.authorized ? 'valid' : 'NOT trusted'}${tls.certificate ? ` (CN ${clean(tls.certificate.subject)}, issuer ${clean(tls.certificate.issuer)}, expires ${clean(tls.certificate.valid_to)}, ${tls.certificate.days_left} days left)` : ''}` : '- TLS: not used (plain http)');
  if (final) {
    for (const h of SECURITY_HEADERS) lines.push(`- ${h}: ${final.headers[h] ? `\`${clean(final.headers[h])}\`` : '**missing**'}`);
    const cookies = [].concat(final.headers['set-cookie'] ?? []);
    for (const c of cookies) {
      const name = clean(c.split('=')[0]);
      const flags = ['Secure', 'HttpOnly', 'SameSite'].map((f) => `${f}=${new RegExp(`;\\s*${f}`, 'i').test(c) ? 'yes' : 'no'}`).join(' ');
      lines.push(`- cookie \`${name}\`: ${flags}`);
    }
    const banner = BANNER_HEADERS.filter((h) => final.headers[h]).map((h) => `${h}: \`${clean(final.headers[h])}\``);
    lines.push(`- Server banner: ${banner.length ? banner.join(', ') : 'none'}`);
  }
  const chain = record.hops.filter((h) => h.method === 'GET').map((h) => h.refused ? `${clean(h.url)} (refused: ${clean(h.refused)})` : h.error ? `${clean(h.url)} (error: ${clean(h.error)})` : `${clean(h.url)} → ${h.status}${h.headers?.location ? ` Location ${clean(h.headers.location)}` : ''}`);
  lines.push(`- Redirect chain: ${chain.join(' ⇒ ')}`);
  for (const h of record.hops.filter((h) => h.error)) lines.push(`- ${h.method} ${clean(h.url)} failed: ${clean(h.error)}`);
  return `${lines.join('\n')}\n`;
}
