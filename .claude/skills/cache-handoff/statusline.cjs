#!/usr/bin/env node
'use strict';

/**
 * Claude Code status line (cache-handoff mod): context-window usage and prompt-cache warmth.
 *
 * Wired by `.claude/settings.json → statusLine`; CommonJS on purpose (`.cjs`), so it runs the
 * same under a project whose package.json says `"type": "module"`.
 *
 * Reads the status-line JSON payload from stdin, finds the session transcript,
 * and reports how full the context window is right now — i.e. the token count
 * fed into the most recent assistant turn (input + cached context). This mirrors
 * what `/context` shows; it is a live snapshot, not a session-cumulative sum, so
 * it goes up and down and resets after `/clear` or context compaction.
 *
 * The headline figure is highlighted in bold gold.
 *
 * The transcript repeats each assistant message across several JSONL lines
 * (one per streamed content block); usage is de-duplicated by message.id, and
 * the last unique message determines the current context size.
 */

const fs = require('fs');

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

let payload = {};
try {
  payload = JSON.parse(readStdin());
} catch {
  // No / malformed payload — fall back to defaults below.
}

const model = payload.model || {};
const modelName = model.display_name || 'Claude';

const transcriptPath = payload.transcript_path;

let context = 0; // tokens loaded into the most recent turn

// Context loaded for a turn = fresh input + cached context read/created.
function lastContext(text) {
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"usage"')) continue;
    try {
      const usage = JSON.parse(lines[i])?.message?.usage;
      if (usage) {
        return (
          (usage.input_tokens || 0) +
          (usage.cache_read_input_tokens || 0) +
          (usage.cache_creation_input_tokens || 0)
        );
      }
    } catch {
      // The first line of a tail chunk is usually cut; skip it.
    }
  }
  return null;
}

// Long sessions reach gigabytes: read only the tail, growing it until a usage line appears.
if (transcriptPath) {
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const { size } = fs.fstatSync(fd);
    for (let chunk = 256 * 1024; ; chunk *= 4) {
      const length = Math.min(chunk, size);
      const buffer = Buffer.alloc(length);
      fs.readSync(fd, buffer, 0, length, size - length);
      const found = lastContext(buffer.toString('utf8'));
      if (found !== null) {
        context = found;
        break;
      }
      if (length === size) break;
    }
  } catch {
    // Transcript not readable yet (very start of a session) — show zero.
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

const compact = (n) => {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2).replace(/\.?0+$/, '') + 'M';
  if (n >= 1_000) return Math.round(n / 1_000) + 'k';
  return String(n);
};

const GOLD = '\x1b[1;38;2;255;215;0m'; // < 300k — bold gold (RGB 255,215,0)
const ORANGE = '\x1b[1;38;2;255;140;0m'; // ≥ 300k — bold orange
const RED = '\x1b[1;38;2;255;64;64m'; // ≥ 500k — bold red
const DIM = '\x1b[2m';
const RESET = '\x1b[0m';

// Headline colour escalates as the context window fills up.
let color = GOLD;
if (context >= 500_000) color = RED;
else if (context >= 300_000) color = ORANGE;

// Prompt-cache warmth, from the payload's prompt_cache (Claude Code ≥ 2.1.251): warm with
// minutes left, cooling in the last sixth of its TTL, cold once expired. Absent before the
// first response, so the segment is left out until then.
const CACHE_WARM = '\x1b[38;2;80;200;120m'; // green
const CACHE_COOLING = '\x1b[38;2;255;140;0m'; // orange
const CACHE_COLD = '\x1b[38;2;90;160;255m'; // blue

function cacheSegment(cache) {
  if (!cache || !cache.caching_observed) return '';
  const ttlSeconds = cache.ttl === '5m' ? 300 : 3600;
  const left = cache.expires_at ? cache.expires_at - Date.now() / 1000 : 0;
  if (!cache.warm || left <= 0) return `${CACHE_COLD}▱▱▱ cold${RESET}`;
  const minutes = Math.ceil(left / 60);
  const isCooling = left <= ttlSeconds / 6;
  const bar = isCooling ? '▰▱▱' : '▰▰▰';
  return `${isCooling ? CACHE_COOLING : CACHE_WARM}${bar} ${minutes} min${RESET}`;
}

const cache = cacheSegment(payload.prompt_cache);

process.stdout.write(
  `${color}${compact(context)} tokens${RESET}` +
    (cache ? `${DIM} · ${RESET}${cache}` : '') +
    `${DIM} · ${modelName}${RESET}`,
);
