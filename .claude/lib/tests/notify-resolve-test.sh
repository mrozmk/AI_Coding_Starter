#!/usr/bin/env bash
# Offline test of notify.sh resolve (#97): the Operator answered elsewhere, so no further delivery
# (a held overnight iMessage included, a delivered one untouched), a Herdr resolve marker in the
# spool, idempotent and project-prefix free; operator-record.sh close resolves its record; the
# harness-notify mod's scan order under node. Fixture HOME and an osascript stub only — nothing
# reaches a person, no real ~/.agent-comms.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
N="$ROOT/.claude/lib/notify.sh"; OR="$ROOT/.claude/lib/operator-record.sh"
MOD="$ROOT/.claude/team/herdr-mod/harness-notify"
command -v jq >/dev/null 2>&1 || { echo "notify-resolve-test: FAIL — jq missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/notify resolve.XXXXXX") || { echo "notify-resolve-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "notify-resolve-test: FAIL — fixture setup: $1"; exit 1; }
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin" || die "dirs"
OB="$HOME/.agent-comms/outbox"; HN="$OB/herdr/new"; HD="$OB/herdr/done"
cat > "$T/osa" <<EOF || die "osa"
#!/usr/bin/env bash
printf '%s\n' "\$4" >> "$T/osa.texts"
EOF
chmod +x "$T/osa" || die "chmod"
export NOTIFY_OSASCRIPT_BIN="$T/osa" NOTIFY_SYSTEM_TZ=Europe/Warsaw
at() { TZ=Europe/Warsaw date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null || TZ=Europe/Warsaw date -d "$1" +%s; }
NOON="$(at '2026-11-15 12:00')"; NIGHT="$(at '2026-11-15 23:00')"; MORNING="$(at '2026-11-16 07:00')"
export NOTIFY_NOW="$NOON"
MH="$T/main"; mkdir -p "$MH/.agents/team/registry" && git -C "$MH" init -q || die "main"
reg() { printf '%s\n' "$2" > "$MH/.agents/team/registry/$1.json"; }
reg acme-alfa-lead '{"backend": "herdr", "handle": "t3k9", "name": "acme-alfa-lead"}'
reg acme-beta-lead '{"backend": "tmux", "handle": "acme-beta-lead"}'
reg Supervisor '{"backend": "herdr", "handle": "t7"}'
n=0; fail=0
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; printf '%s\n' "$OUT" | sed 's/^/    /'; fail=1; fi; }
nt() { OUT=$(bash "$N" "$@" 2>&1); RC=$?; }
dec() {  # dec <decision> [answer] [project] — a human_decision of team alfa, run r1
  nt human_decision --project "${3:-acme}" --team alfa --ticket AB-1 --run r1 --decision "$1" \
    --summary "Restart the app?" --answer "${2:-acme-alfa-lead}" --main "$MH"
}
res() { nt resolve --team alfa --run r1 --decision "$@"; }
st() { cut -d' ' -f1-2 "$OB/state/$1.$2" 2>/dev/null; }
osa() { [ -f "$T/osa.texts" ] && grep -c . "$T/osa.texts" || echo 0; }

# ---- usage, and nothing to resolve on a machine that never sent -------------------------------------
res d-1
ok '[ "$RC" = 0 ] && [ "$OUT" = unknown ] && [ ! -e "$HOME/.agent-comms" ]' "resolve before any event: unknown, exit 0, no outbox made"
nt resolve --team alfa --run r1; ok '[ "$RC" = 2 ]' "resolve without --decision is usage"
nt resolve --key k1 --team alfa; ok '[ "$RC" = 2 ]' "--key with --team is usage"
nt resolve --key 'a b'; ok '[ "$RC" = 2 ]' "a bad --key is usage"

mkdir -p "$HOME/.agent-comms" && printf '%s\n' '{"version": 1, "herdr": {"enabled": true}, "imessage": {"enabled": true,
  "recipient": "+48 600 000 000", "quiet": {"start": "22:00", "end": "07:00", "tz": "Europe/Warsaw"}}}' \
  > "$HOME/.agent-comms/notify.json" || die "conf"

# ---- a delivered herdr event: resolved, marker in the spool, the sent message untouched -------------
dec h-1; ok '[ "$RC" = 0 ] && [ "$(st acme_alfa_r1_h-1 herdr)" = "spooled -" ] && [ "$(st acme_alfa_r1_h-1 imessage)" = "submitted -" ]' \
  "a herdr event is spooled and sent by iMessage"
o=$(osa); res h-1
ok '[ "$RC" = 0 ] && [ "$OUT" = "resolved acme:alfa:r1:h-1" ] && [ -f "$OB/state/acme_alfa_r1_h-1.resolved" ] && [ -f "$HN/acme_alfa_r1_h-1.resolve" ]' \
  "resolve: state marker and the spool's resolve marker"
ok '[ "$(st acme_alfa_r1_h-1 imessage)" = "submitted -" ] && [ "$(osa)" = "$o" ] && [ -f "$HN/acme_alfa_r1_h-1.json" ]' \
  "a delivered message and the spool entry are not touched"
snap() { (cd "$OB" && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
before=$(snap); res h-1
ok '[ "$RC" = 0 ] && [ "$OUT" = "already resolved acme:alfa:r1:h-1" ] && [ "$(snap)" = "$before" ]' \
  "a second resolve: already resolved, exit 0, nothing written"
mv "$HN/acme_alfa_r1_h-1.resolve" "$HD/" || die "mod move"; rm -f "$OB/state/acme_alfa_r1_h-1.resolved"; res h-1
ok '[ "$RC" = 0 ] && [ ! -e "$HN/acme_alfa_r1_h-1.resolve" ]' "a marker the mod already took is never published again"
nt list; ok '[ "$RC" = 0 ] && grep -qx "acme:alfa:r1:h-1 human_decision herdr=spooled imessage=submitted resolved" <<<"$OUT"' \
  "list says resolved"

# ---- a tmux-backend event: resolved, no spool marker -------------------------------------------------
dec h-2 acme-beta-lead; res h-2
ok '[ "$OUT" = "resolved acme:alfa:r1:h-2" ] && [ ! -e "$HN/acme_alfa_r1_h-2.resolve" ]' "a tmux event gets no spool marker"
nt list; ok 'grep -qx "acme:alfa:r1:h-2 human_decision herdr=skipped-tmux imessage=submitted resolved" <<<"$OUT"' \
  "list says resolved for a tmux event too"

# ---- held overnight (Q3): a resolved one leaves the morning batch -----------------------------------
NOTIFY_NOW="$NIGHT"; dec h-3; dec h-4; NOTIFY_NOW="$NOON"
ok '[ "$(st acme_alfa_r1_h-3 imessage)" = "held -" ] && [ "$(st acme_alfa_r1_h-4 imessage)" = "held -" ]' "two events held overnight"
res h-3; : > "$T/osa.texts"; nt flush --now "$MORNING"
ok '[ "$(st acme_alfa_r1_h-3 imessage)" = "skipped resolved" ] && [ "$(st acme_alfa_r1_h-4 imessage)" = "submitted -" ]' \
  "the resolved held event is skipped, the other sent"
ok '[ "$(osa)" -ge 1 ] && grep -q "1 held overnight" "$T/osa.texts" && grep -q "h-4" "$T/osa.texts" && ! grep -q "h-3" "$T/osa.texts"' \
  "the morning batch holds only the unresolved event"
nt list; ok 'grep -qx "acme:alfa:r1:h-4 human_decision herdr=spooled imessage=submitted" <<<"$OUT"' "list marks no unresolved event"

# ---- a delivery deferred by a busy outbox, resolved meanwhile: never spooled ------------------------
mkdir "$OB/.flush.lock" && echo $$ > "$OB/.flush.lock/pid" || die "lock"
NOTIFY_LOCK_WAIT=0 dec h-5
ok '[[ "$OUT" == *"delivery deferred"* ]] && [ "$(st acme_alfa_r1_h-5 herdr)" = "pending -" ]' "a busy outbox defers the delivery"
res h-5; rm -f "$OB/.flush.lock/pid"; rmdir "$OB/.flush.lock"; o=$(osa); nt flush
ok '[ "$(st acme_alfa_r1_h-5 herdr)" = "skipped resolved" ] && [ "$(st acme_alfa_r1_h-5 imessage)" = "skipped resolved" ] && [ ! -e "$HN/acme_alfa_r1_h-5.json" ] && [ "$(osa)" = "$o" ]' \
  "the flush after resolve spools and sends nothing"

# ---- --project narrows a same-run event of another project ------------------------------------------
dec h-6; dec h-6 acme-alfa-lead other
nt resolve --project acme --team alfa --run r1 --decision h-6
ok '[ "$OUT" = "resolved acme:alfa:r1:h-6" ] && [ ! -e "$OB/state/other_alfa_r1_h-6.resolved" ]' "--project leaves the other project's event"
res h-6; ok '[ "$OUT" = "already resolved acme:alfa:r1:h-6"$'"'"'\n'"'"'"resolved other:alfa:r1:h-6" ]' "without --project the fields match every project"

# ---- operator-record.sh close resolves the release step (--key) -------------------------------------
OUT=$(cd "$MH" && bash "$OR" release --summary "Tag v9.9.9 waits" 2>&1); id=$(sed -n 's/^recorded //p' <<<"$OUT")
F="$(ls "$OB/events" | grep -- "_release_$id.json$")"
ok '[ -n "$id" ] && [ -n "$F" ] && [ "$(st "${F%.json}" herdr)" = "spooled -" ]' "a release record raises a spooled event"
OUT=$(cd "$MH" && bash "$OR" close "$id" 2>&1); RC=$?
ok '[ "$RC" = 0 ] && [ "$OUT" = "closed $id" ] && [ -f "$OB/state/${F%.json}.resolved" ] && [ -f "$HN/${F%.json}.resolve" ]' \
  "close resolves the record's event"
before=$(snap); OUT=$(cd "$MH" && bash "$OR" close "$id" 2>&1); RC=$?
ok '[ "$RC" = 0 ] && [ "$OUT" = "closed $id" ] && [ "$(snap)" = "$before" ]' "a second close: exit 0, nothing more written"
nt resolve --key "$id"; ok '[[ "$OUT" == "already resolved "*":release:$id" ]]' \
  "resolve --key finds it again"

# ---- prune: a marker no strip took goes after a day ---------------------------------------------------
: > "$HN/zz-old.resolve" && touch -t 202601010000 "$HN/zz-old.resolve" && : > "$HN/zz-new.resolve" || die "markers"
nt flush; ok '[ ! -e "$HN/zz-old.resolve" ] && [ -e "$HN/zz-new.resolve" ]' "prune removes a day-old marker, keeps a fresh one"

# ---- the mod's scan order (spool.js) under node --------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  OUT=$(cd "$T" && node --input-type=module -e '
    import * as s from "'"$MOD"'/spool.js";
    const ok = (c, m) => { if (!c) { console.log("FAIL " + m); process.exit(1); } };
    ok(s.resolveOf("acme_alfa_r1_h-1.resolve") === "acme_alfa_r1_h-1", "resolveOf");
    for (const b of [".resolve", "..resolve", ".x.resolve", "a/b.resolve", "a b.resolve", "x.json", "x.resolve.tmp"])
      ok(s.resolveOf(b) === null, "resolveOf rejects " + b);
    ok(s.idOf("x.resolve") === null, "an entry id never takes a marker");
    const [c, a] = s.moveArgs("/H", "x", ".resolve");
    ok(c === "mv" && a.join(" ") === "-f /H/.agent-comms/outbox/herdr/new/x.resolve /H/.agent-comms/outbox/herdr/done/x.resolve", "moveArgs .resolve");
    ok(s.moveArgs("/H", "x")[1][1].endsWith("/new/x.json"), "moveArgs defaults to .json");
    let t = false; try { s.moveArgs("/H", "x", ".sh"); } catch { t = true; } ok(t, "moveArgs refuses another extension");
    const p = s.plan(["c.json", "b.resolve", "b.json", "a.resolve", ".tmp.1", "bad name.json"]);
    ok(p.resolved.join() === "a,b", "markers first: " + p.resolved.join());
    ok(p.entries.map((e) => e.id + ":" + e.quiet).join() === "b:true,c:false", "entries: " + JSON.stringify(p.entries));
    const item = (id) => ({ id, title: id, body: "", action: null, at: 0 });
    let l = [item("a"), item("z")];
    for (const id of p.resolved) l = s.ack(l, id);
    ok(l.map((i) => i.id).join() === "z", "a marker drops its item, an absent one is a no-op");
    console.log("spool OK");' 2>&1); RC=$?
  ok '[ "$RC" = 0 ] && [ "$OUT" = "spool OK" ]' "the mod logic under node"
  MJ="$MOD/main.js"
  ok 'grep -q "const p = spool.plan(names);" "$MJ" && grep -q "this.list = spool.ack(this.list, id);" "$MJ" && grep -q "!r.stale && !quiet" "$MJ" && [ "$(grep -c "exec(" "$MJ")" = 2 ]' \
    "main.js scans markers first, toasts no quiet entry, still two exec calls"
else
  echo "notify-resolve-test: mod logic skipped — no node"
fi

[ "$fail" -eq 0 ] || exit 1
echo "notify-resolve-test: OK ($n checks)"
