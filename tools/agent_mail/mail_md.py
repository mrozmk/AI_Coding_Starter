# Vendored from mrozmk/jarvis@c9c407c (tools/agent_mail/) — MIT, same terms and holder as LICENSE.
# Local delta and the re-sync procedure: tools/agent_mail/README.md → "Vendored copy".
"""
`mail.md` <-> mailbox bridge: parse the historical markdown board into rows the
store can `send()`, and render stored rows back into the same markdown shape.

The markdown board was hand-written by two models over two days, so the parser is
deliberately tolerant on the shapes that actually occur (counted on the live file):

  * arrow is `→` (U+2192) or `->`;
  * recipients can be a list: `Reviewer i Advisor`, `Reviewer + Advisor`, `Reviewer, Advisor`;
  * message numbers can carry a letter suffix (`MSG-143A`) and can repeat
    (`MSG-143` twice with different bodies);
  * the time field has four spellings (`2026-09-17`, `+ HH:MM`, `+ UTC`,
    `+ (zegar systemowy)`), sometimes with a trailing space.

Two invariants make the round trip safe, and both are easy to break later:

  1. **Body is never synthesised.** Everything the exporter needs to restore a row
     (`legacy_id`, `kind`, `awaiting`, `legacy_awaiting`) travels in ONE HTML
     comment under the header, which the parser consumes and removes. So
     `render_md -> parse_mail_md` returns byte-identical bodies, and therefore an
     identical `dedup_key` — re-importing an export is a no-op.
  2. **The time field round-trips verbatim.** For imported rows the header carries
     `legacy_ts` exactly as it was written (no ` UTC` suffix added, no rewriting);
     `ts_utc` is derived from it, never the other way round.

Python 3.9 / stdlib only.
"""

import hashlib
import json
import os
import re
from collections import namedtuple
from typing import Any, List, Optional

import agent_mail_store as store

# `MSG-143A` is a real header: the number is the sort key, the suffix is part of
# the label (and of the dedup key), so both are kept as one string.
HEADER_RE = re.compile(
    r"^## MSG-(\d+[A-Za-z]?)\s*\|\s*(.+?)\s*(?:→|->)\s*(.+?)\s*\|\s*(.+?)\s*$")
# Independent count: EVERY line that looks like a header must also parse, otherwise
# the import refuses to run (a silently dropped message is worse than no import).
ANY_HEADER_RE = re.compile(r"^## MSG-\d+")

TS_RE = re.compile(r"(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?")
END_TURN_RE = re.compile(r"^---\s*KONIEC TURY MSG-[0-9A-Za-z]+\s*·\s*(.*?)\s*---\s*$")
ORIGIN_RE = re.compile(r"^<!--\s*agent-mail\s+(.*?)\s*-->\s*$")
_ATTR_RE = re.compile(r'([A-Za-z_]+)=(?:"((?:[^"\\]|\\.)*)"|(\S+))')

_RECIPIENT_SPLIT_RE = re.compile(r"\s+i\s+|\s+oraz\s+|\s*,\s*|\s*/\s*|\s*\+\s*")
_AWAITING_PREFIX = "czekam na "

ParsedMsg = namedtuple(
    "ParsedMsg",
    "legacy_id legacy_ts legacy_awaiting sender recipients kind awaiting ts_utc body"
    " dedup_key note")


# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

def count_headers(text: str) -> int:
    """How many lines LOOK like a message header (the gate's expected count)."""
    return sum(1 for line in text.splitlines() if ANY_HEADER_RE.match(line))


def unparsed_headers(text: str) -> List[str]:
    """Header-looking lines the strict regex could not read — the gate's evidence."""
    return [line for line in text.splitlines()
            if ANY_HEADER_RE.match(line) and not HEADER_RE.match(line)]


def split_recipients(raw: str) -> List[str]:
    """`Reviewer i Advisor` / `Reviewer, Advisor` / `Reviewer + Advisor` -> ['Reviewer', 'Advisor']."""
    parts = [p.strip() for p in _RECIPIENT_SPLIT_RE.split(raw)]
    out = []  # type: List[str]
    for part in parts:
        if part and part not in out:
            out.append(part)
    return out


def parse_ts(raw: str) -> Optional[str]:
    """`2026-09-17 11:32 (zegar systemowy)` -> `2026-09-17T11:32:00Z`; None if absent.

    Local time vs UTC is NOT distinguished — the handwritten stamps drifted by
    hours anyway, so the raw text is preserved in `legacy_ts` and this value is
    only an ordering hint.
    """
    match = TS_RE.search(raw or "")
    if match is None:
        return None
    day, hour, minute, second = match.group(1), match.group(2), match.group(3), match.group(4)
    return "%sT%s:%s:%sZ" % (day, hour or "00", minute or "00", second or "00")


def _parse_origin(line: str) -> Optional[dict]:
    """Read the `<!-- agent-mail ... -->` provenance comment written by `render_md`."""
    match = ORIGIN_RE.match(line)
    if match is None:
        return None
    attrs = {}
    for key, quoted, bare in _ATTR_RE.findall(match.group(1)):
        attrs[key] = json.loads('"%s"' % quoted) if bare == "" else bare
    return attrs


def _awaiting_from_body(body: str):
    """Last `--- KONIEC TURY ... · czekam na X ---` marker -> (awaiting, legacy_awaiting).

    `awaiting` reaches the wake-up signal, so it is only set when the text is a
    plain identifier; free prose (`Advisor / raport P07`) is kept as `legacy_awaiting`
    and `awaiting` stays NULL.
    """
    raw = None
    for line in body.splitlines():
        match = END_TURN_RE.match(line)
        if match is not None:
            raw = match.group(1)
    if raw is None:
        return None, None
    raw = raw.strip()
    if raw.startswith(_AWAITING_PREFIX):
        raw = raw[len(_AWAITING_PREFIX):].strip()
    if not raw:
        return None, None
    if store.IDENT_RE.match(raw):
        return raw, None
    return None, raw


def normalize_legacy_id(raw: str) -> str:
    """`001` / `1` / `143A` -> `1` / `1` / `143A`.

    The board zero-pads to three digits but `messages.legacy_id` has INTEGER
    affinity, so SQLite stores `'001'` as `1` and reads it back unpadded. Without
    this normalisation the dedup key of a re-imported export would differ from the
    original one and the import would duplicate every message numbered below 100.
    """
    raw = str(raw).strip()
    digits = raw.rstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    return "%d%s" % (int(digits), raw[len(digits):])


def format_legacy_label(legacy_id) -> str:
    """Back to the board spelling: `1` -> `MSG-001`, `143A` -> `MSG-143A`."""
    raw = str(legacy_id).strip()
    digits = raw.rstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    return "%03d%s" % (int(digits), raw[len(digits):])


def dedup_key_for(legacy_id, body: str) -> str:
    """Stable per (message number, body): a repeated number with a different body
    is a distinct message, a re-import of the same text is not."""
    digest = hashlib.sha1(body.encode("utf-8")).hexdigest()[:12]
    return "mailmd:%s:%s" % (legacy_id, digest)


def _build(header, lines) -> ParsedMsg:
    legacy_id = normalize_legacy_id(header.group(1))
    sender = header.group(2).strip()
    recipients = split_recipients(header.group(3))
    legacy_ts = header.group(4).strip()

    origin = None
    for index, line in enumerate(lines):
        if line.strip() == "":
            continue
        origin = _parse_origin(line)
        if origin is not None:
            lines = lines[:index] + lines[index + 1:]
        break

    body = "\n".join(lines).strip("\n")
    kind = "report" if sender.startswith("Wykonawca") else "turn"
    if origin is None:
        awaiting, legacy_awaiting = _awaiting_from_body(body)
    else:
        # Provenance present: trust it verbatim, do NOT re-derive from the body —
        # re-normalising here would make the second render/parse cycle differ.
        legacy_id = normalize_legacy_id(origin.get("legacy_id", legacy_id))
        kind = origin.get("kind", kind)
        awaiting = origin.get("awaiting")
        legacy_awaiting = origin.get("legacy_awaiting")

    # The sender sometimes addresses the whole board including itself; `send()`
    # rejects a self-send, and the message is not for the sender anyway.
    recipients = [r for r in recipients if r != sender]

    ts_utc = parse_ts(legacy_ts)
    return ParsedMsg(
        legacy_id=legacy_id,
        legacy_ts=legacy_ts,
        legacy_awaiting=legacy_awaiting,
        sender=sender,
        recipients=recipients,
        kind=kind,
        awaiting=awaiting,
        ts_utc=ts_utc,
        body=body,
        dedup_key=dedup_key_for(legacy_id, body),
        note=None if ts_utc else "ts-unparsed")


def parse_mail_md(text: str) -> List[ParsedMsg]:
    """Split the board into messages. Anything before the first header is dropped."""
    messages = []  # type: List[ParsedMsg]
    header = None
    buffer = []  # type: List[str]
    for line in text.splitlines():
        # Split on ANY header-looking line so a malformed one still terminates the
        # previous body (it is then reported by `unparsed_headers`).
        if ANY_HEADER_RE.match(line):
            if header is not None:
                messages.append(_build(header, buffer))
            header = HEADER_RE.match(line)
            buffer = []
            continue
        if header is not None:
            buffer.append(line)
    if header is not None:
        messages.append(_build(header, buffer))
    return messages


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

def _get(row, key, default=None) -> Any:
    """Field access that works for sqlite3.Row, dict and ParsedMsg alike."""
    if isinstance(row, dict):
        return row.get(key, default)
    try:
        value = row[key]
    except (IndexError, KeyError, TypeError):
        value = getattr(row, key, default)
    return default if value is None else value


def _origin_line(legacy_id, kind, awaiting, legacy_awaiting, sender) -> str:
    attrs = ["legacy_id=%s" % (legacy_id,)]
    if kind != ("report" if str(sender).startswith("Wykonawca") else "turn"):
        attrs.append("kind=%s" % (kind,))
    if awaiting:
        attrs.append("awaiting=%s" % (awaiting,))
    if legacy_awaiting:
        attrs.append("legacy_awaiting=%s" % (json.dumps(legacy_awaiting, ensure_ascii=False),))
    return "<!-- agent-mail %s -->" % (" ".join(attrs),)


def render_md(rows, box: Optional[str] = None, since: int = 0) -> str:
    """Render stored (or parsed) messages as the `mail.md` board.

    Imported rows keep their original number and time text; native rows use their
    row id and an ISO stamp with a ` UTC` suffix.
    """
    # Only the box FILE name: the export is a shareable document, the absolute
    # path of the mailbox is local detail that must not travel with it.
    out = ["# agent-mail export — box=%s since=%s generated=%s"
           % (os.path.basename(box) if box else "-", since, store.now_utc()), ""]
    for row in rows:
        legacy_id = _get(row, "legacy_id")
        recipients = _get(row, "recipients", [])
        if isinstance(recipients, str):
            recipients = json.loads(recipients)
        sender = _get(row, "sender", "?")
        if legacy_id is not None:
            label = format_legacy_label(legacy_id)
            ts_field = _get(row, "legacy_ts") or _get(row, "ts_utc", "")
        else:
            label = str(_get(row, "id", "?"))
            ts_field = "%s UTC" % (_get(row, "ts_utc", ""),)
        out.append("## MSG-%s | %s → %s | %s"
                   % (label, sender, " i ".join(recipients), ts_field))
        if legacy_id is not None:
            out.append(_origin_line(normalize_legacy_id(legacy_id), _get(row, "kind", "turn"), _get(row, "awaiting"),
                                    _get(row, "legacy_awaiting"), sender))
        out.append("")
        out.append(_get(row, "body", ""))
        out.append("")
    return "\n".join(out) + "\n"
