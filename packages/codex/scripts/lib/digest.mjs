// Content-identity digests shared by build, check, smoke and the installed locator.
// Record format (contract 13): UTF-8 POSIX path, NUL, u64 big-endian byte length, exact bytes;
// records sorted by UTF-8 path bytes; lowercase hex SHA-256 of the concatenation.
import { createHash } from 'node:crypto';

export function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function compareUtf8(a, b) {
  return Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

export function recordsDigest(records) {
  const hash = createHash('sha256');
  const sorted = [...records].sort((x, y) => compareUtf8(x.path, y.path));
  const seen = new Set();
  for (const rec of sorted) {
    if (seen.has(rec.path)) throw new Error(`duplicate digest record path: ${rec.path}`);
    seen.add(rec.path);
    const len = Buffer.alloc(8);
    len.writeBigUInt64BE(BigInt(rec.bytes.length));
    hash.update(Buffer.from(rec.path, 'utf8'));
    hash.update(Buffer.from([0]));
    hash.update(len);
    hash.update(rec.bytes);
  }
  return hash.digest('hex');
}

export function fileEntries(records) {
  return [...records]
    .sort((x, y) => compareUtf8(x.path, y.path))
    .map((rec) => ({ path: rec.path, sha256: sha256Hex(rec.bytes), bytes: rec.bytes.length }));
}
