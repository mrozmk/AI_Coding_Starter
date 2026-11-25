// proxy.mjs — the in-process forward proxy (absolute-URI HTTP + CONNECT) on loopback. It resolves
// every destination itself, decides it with policy.mjs and connects only to a validated address, so
// Chrome never resolves and redirect hops cannot bypass the policy.
import http from 'node:http';
import net from 'node:net';
import { decide, resolveAddresses } from './policy.mjs';
import { redactUrl } from './redact.mjs';

function splitHostPort(text, defPort) {
  const m = /^\[([^\]]+)\](?::(\d+))?$/.exec(text) || /^([^:]+)(?::(\d+))?$/.exec(text);
  if (!m) return null;
  return { host: m[1], port: m[2] || String(defPort) };
}

function ordered(addresses) {
  return [...addresses].sort((a, b) => net.isIP(a) - net.isIP(b));
}

function connectFirst(addresses, port, cb) {
  const list = ordered(addresses);
  const attempt = (i, lastErr) => {
    if (i >= list.length) return cb(lastErr || new Error('connect failed'));
    const sock = net.connect({ host: list[i], port: Number(port) });
    sock.once('connect', () => { sock.removeAllListeners('error'); cb(null, sock, list[i]); });
    sock.once('error', (err) => attempt(i + 1, err));
  };
  attempt(0);
}

export async function startProxy({ runClass, origins, ledger, context = () => ({}), lookup }) {
  const sockets = new Set();
  const record = (kind, url, reason) => ledger.push({ kind, url: redactUrl(url), reason, ...context() });

  async function judge(scheme, host, port) {
    let addresses;
    try { addresses = await resolveAddresses(host, lookup); } catch { return { allow: false, reason: 'dns-failed', addresses: [] }; }
    return { ...decide({ scheme, host, port, addresses, runClass, origins }), addresses };
  }

  const server = http.createServer(async (req, res) => {
    let url;
    try { url = new URL(req.url); } catch { res.writeHead(400); res.end(); return; }
    if (url.protocol !== 'http:') { record('destination-blocked', req.url, 'unsupported-scheme'); res.writeHead(403); res.end(); return; }
    const port = url.port || '80';
    const verdict = await judge('http', url.hostname.replace(/^\[|\]$/g, ''), port);
    if (!verdict.allow) { record('destination-blocked', req.url, verdict.reason); res.writeHead(403, { 'content-type': 'text/plain', 'x-wcag-audit': 'blocked' }); res.end('blocked by wcag-audit'); return; }
    const headers = { ...req.headers };
    for (const h of Object.keys(headers)) if (h.startsWith('proxy-')) delete headers[h];
    const address = ordered(verdict.addresses)[0];
    const family = net.isIP(address);
    const up = http.request({
      host: url.hostname.replace(/^\[|\]$/g, ''), port, method: req.method, path: `${url.pathname}${url.search}`, headers, agent: false,
      lookup: (h, opts, cb) => (opts?.all ? cb(null, [{ address, family }]) : cb(null, address, family)),
    }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    up.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
    req.pipe(up);
  });

  server.on('connect', async (req, client) => {
    sockets.add(client);
    client.on('close', () => sockets.delete(client));
    client.on('error', () => {});
    const hp = splitHostPort(req.url, 443);
    if (!hp) { client.end('HTTP/1.1 400 Bad Request\r\n\r\n'); return; }
    const verdict = await judge('https', hp.host, hp.port);
    if (!verdict.allow) {
      record('destination-blocked', `https://${req.url}/`, verdict.reason);
      client.end('HTTP/1.1 403 Forbidden\r\n\r\n');
      return;
    }
    connectFirst(verdict.addresses, hp.port, (err, upstream) => {
      if (err) { client.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); return; }
      sockets.add(upstream);
      upstream.on('close', () => sockets.delete(upstream));
      upstream.on('error', () => client.destroy());
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      upstream.pipe(client);
      client.pipe(upstream);
    });
  });

  server.on('upgrade', (req, sock) => {
    record('websocket-blocked', req.url, 'websocket');
    sock.end('HTTP/1.1 403 Forbidden\r\n\r\n');
  });
  server.on('connection', (s) => { sockets.add(s); s.on('close', () => sockets.delete(s)); });

  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  const close = () => new Promise((resolve) => {
    for (const s of sockets) s.destroy();
    server.close(() => resolve());
  });

  // Startup self-check: a loopback origin outside the given origins must be refused.
  try {
    await selfCheck(port);
  } catch (err) {
    await close();
    err.code = 'proxy-self-check';
    throw err;
  }
  return { port, close };
}

async function selfCheck(proxyPort) {
  let hits = 0;
  const canary = http.createServer((q, s) => s.end('canary'));
  canary.on('connection', () => { hits += 1; });
  await new Promise((r) => canary.listen(0, '127.0.0.1', r));
  const cport = canary.address().port;
  const status = await new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port: proxyPort, method: 'GET', path: `http://127.0.0.1:${cport}/self-check`, headers: { host: `127.0.0.1:${cport}` }, agent: false }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', () => resolve(0));
    req.end();
  });
  await new Promise((r) => canary.close(r));
  if (status !== 403 || hits !== 0) throw new Error(`proxy self-check failed (status ${status}, canary hits ${hits})`);
}
