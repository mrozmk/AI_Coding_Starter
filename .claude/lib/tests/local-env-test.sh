#!/usr/bin/env bash
# Offline black-box test of the local env runner (.claude/lib/local-env/): the switch and the trunk
# rule, the registry and argument rules, the docker-is-local preflight before the file is opened,
# the file checks, the clean child env, masking, the pass-line policy, the results scrub, signals,
# a hung origin. Never runs a real tool: PATH is a stub dir (docker, ssh) + /usr/bin:/bin, HOME is a
# fixture, origin is a local bare repo reached through the ssh stub. A sentinel value stands in for
# the secret and must never appear in any output, argv or message.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "local-env-test: FAIL — $*"; exit 1; }
N=0

# Sentinel built at runtime: XML-special and quote bytes exercise every masked form.
M='Sx7#q2"Zx'; M="${M}&p<9'w"
H="$T/home"; STUB="$T/stub"; TMP="$T/tmp"; mkdir -p "$H" "$STUB" "$TMP"
: > "$T/all"; : > "$T/docker-calls"; : > "$T/dmode"
P="$STUB:/usr/bin:/bin"

cat > "$STUB/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$T/docker-calls"
mode=\$(cat "$T/dmode")
case "\$*" in
  "context show") echo default ;;
  *"context inspect"*) case "\$mode" in *remote-ctx*) echo tcp://10.0.0.5:2376 ;; *) echo unix:///var/run/docker.sock ;; esac ;;
  *" ps --format json db") case "\$mode" in *down*) echo '{"Name":"app-db-1","Service":"db","State":"exited"}' ;;
                            *) echo '{"Name":"app-db-1","Service":"db","State":"running"}' ;; esac ;;
  *" port app-db-1 5432/tcp") case "\$mode" in *remote-port*) echo 10.1.2.3:5432 ;; *) echo 0.0.0.0:5432; echo '[::]:5432' ;; esac ;;
  *) exit 1 ;;
esac
EOF
# ssh stub: the transport to the local bare origin; a flag file makes it hang like a dead host.
cat > "$STUB/ssh" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in -o|-p) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
[ -e "$T/hang" ] && exec sleep 60
exec sh -c "\$*"
EOF
chmod +x "$STUB/docker" "$STUB/ssh"
g() { env -i PATH="$P" HOME="$H" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$H/.gitconfig"

g init -q --bare "$T/origin.git"
g clone -q "ssh://stub.example.invalid$T/origin.git" "$T/w" 2>/dev/null
W="$T/w"
mkdir -p "$W/.claude/lib/local-env" "$W/.claude/lib/trunk-trust" "$W/scripts" "$W/docker"
cp "$ST/.claude/lib/branch-model.sh" "$W/.claude/lib/"
cp "$ST/.claude/lib/trunk-trust/trunk_trust.py" "$W/.claude/lib/trunk-trust/"
cp "$ST/.claude/lib/local-env/"{with-local-env.sh,local-env-init.sh,local_env.py} "$W/.claude/lib/local-env/"
printf '# P\n\n### Branch model\n\n**Preset:** trunk · **Trunk:** `main` · **Integration:** `main`\n' > "$W/CLAUDE.md"
printf '{"workflow": {"local_env": true}}\n' > "$W/.claude/project-profile.json"
: > "$W/docker/compose.yml"
# The stub runner prints what it got; it never knows the sentinel, it echoes its env.
cat > "$W/scripts/it.sh" <<'EOF'
#!/usr/bin/env bash
mode=$(cat "$STUBMODE_FILE" 2>/dev/null || true)
has() { case " $mode " in *" $1 "*) return 0 ;; esac; return 1; }
echo "argv:$*"
echo "host:${DB_HOST-unset} tool:${TOOL_ROOT-unset} foo:${FOO-unset} dh:${DOCKER_HOST-unset} so:${SHELLOPTS}"
xml=$(printf '%s' "$DB_SECRET" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g")
echo "raw:${DB_SECRET}|xml:$xml|glued:x${DB_SECRET}${DB_SECRET}y"
echo "raw:${DB_SECRET}" >&2
if has results; then
  d=$(mktemp -d "$TMPDIR/it.XXXXXX"); printf 'secret=%s\n' "$DB_SECRET" > "$d/out.trx"
  echo "it: results in $d"; echo "$d" > "$RESULTS_FILE"
fi
if has trap; then
  # The background sleep ignores TERM: when the group TERM also killed it, bash 3.2 sometimes
  # returned from `wait` on the child's death and dropped its own trap (about 1 run in 6).
  # The child writes the ready marker only after its own trap, so no TERM can land before it.
  trap 'echo got-term > "$TERM_FILE"; kill -KILL $! 2>/dev/null; exit 143' TERM
  ( trap '' TERM; : > "$READY_FILE"; exec sleep 30 ) & wait
fi
for w in $mode; do case "$w" in rc=*) exit "${w#rc=}" ;; esac; done
exit 0
EOF
cat > "$W/scripts/probe.sh" <<'EOF'
#!/usr/bin/env bash
mode=$(cat "$STUBMODE_FILE" 2>/dev/null || true)
case " $mode " in *" skipped "*) echo "SKIPPED: stub" ;; *) echo "probe: PASS" ;; esac
EOF
cat > "$W/.claude/local-env.json" <<'EOF'
{"v": 1, "dir": "fixture-app", "key": "FIXTURE_DB_SECRET",
 "docker": {"compose_file": "docker/compose.yml", "service": "db", "port": 5432},
 "pass_env": ["TOOL_ROOT", "STUBMODE_FILE", "RESULTS_FILE", "TERM_FILE", "READY_FILE"],
 "runners": {
  "it": {"script": "scripts/it.sh", "secret_env": "DB_SECRET", "env": {"DB_HOST": "localhost"},
         "args": {"--no-build": null, "--filter": "[A-Za-z0-9_.~]{1,50}"},
         "results_line": "it: results in (/[^\\r\\n]+)"},
  "probe": {"script": "scripts/probe.sh", "secret_env": "DB_SECRET", "pass_line": "probe: PASS"}}}
EOF
(cd "$W" && g add -A && g commit -qm init && g push -q origin main 2>/dev/null)

CFG="$H/.config/fixture-app"
put() {  # put <file content> — the secret file, mode 600 in a 700 dir
  rm -rf "$CFG"; mkdir -p "$CFG"; chmod 700 "$CFG"
  printf '%s' "$1" > "$CFG/local.env"; chmod 600 "$CFG/local.env"
}
GOOD=$(printf '# c\nFIXTURE_DB_SECRET=%s\n' "$M")
put "$GOOD"

run() {  # run <expect rc> <label> [VAR=val...] -- <args…> → OUT (stdout, then stderr); all kept for the sentinel scan
  local want="$1" label="$2"; shift 2
  local extra=()
  while [ "$1" != -- ]; do extra+=("$1"); shift; done; shift
  set +e
  OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" TMPDIR="$TMP" STUBMODE_FILE="$T/mode" \
    RESULTS_FILE="$T/results" TERM_FILE="$T/term" READY_FILE="$T/ready" ${extra[@]+"${extra[@]}"} \
    bash .claude/lib/local-env/with-local-env.sh "$@" 2>"$T/err")
  RC=$?; set -e; N=$((N + 1))
  [ -s "$T/err" ] && OUT="$OUT"$'\n'"$(cat "$T/err")"  # stderr after stdout: no line splits another
  printf '%s\n' "$OUT" >> "$T/all"
  [ "$RC" = "$want" ] || fail "$label: rc $RC (want $want): $OUT"
}
has() { case "$OUT" in *"$1"*) ;; *) fail "$2: no '$1' in: $OUT" ;; esac; }

# ---- happy path, env and masking ------------------------------------------------------------------
: > "$T/mode"
run 0 "it runs" TOOL_ROOT=/opt/tool FOO=leak DOCKER_HOST=tcp://x:1 SHELLOPTS=xtrace DB_SECRET=caller -- it --no-build --filter A.B~c
has "argv:--no-build --filter A.B~c" "argv"
has "host:localhost tool:/opt/tool foo:unset dh:unset so:" "clean env"
has "raw:{hidden}|xml:{hidden}|glued:x{hidden}{hidden}y" "masked stdout"
case "$OUT" in *caller*|*xtrace*) fail "inherited value reached the child: $OUT" ;; esac
grep -q "port app-db-1 5432/tcp" "$T/docker-calls" || fail "docker preflight did not run"

# ---- registry and arguments (refused before docker and the file) ----------------------------------
: > "$T/docker-calls"
run 64 "no id" -- ; has "usage:" "usage"
run 64 "unknown id" -- nope
run 64 "flag not listed" -- it --update
run 64 "flag twice" -- it --no-build --no-build
run 64 "value outside its regex" -- it --filter 'a;b'
run 64 "value missing" -- it --filter
run 64 "pass-line runner takes no args" -- probe --no-build
[ -s "$T/docker-calls" ] && fail "docker ran on an argument refusal"
run 64 "BASH_ENV" BASH_ENV=/dev/null -- it
run 64 "TMPDIR not a dir" TMPDIR="$T/none" -- it

# ---- switch and trunk rule ------------------------------------------------------------------------
cp "$W/.claude/project-profile.json" "$T/profile.bak"
printf '{"workflow": {}}\n' > "$W/.claude/project-profile.json"
run 78 "switch off" -- it; has "workflow.local_env" "off message"
cp "$T/profile.bak" "$W/.claude/project-profile.json"
cp "$W/.claude/local-env.json" "$T/cfg.bak"
sed -i.x 's/"--no-build": null/"--no-build": null, "--update": null/' "$W/.claude/local-env.json"; rm -f "$W/.claude/local-env.json.x"
run 78 "config widened in the working tree" -- it --update; has "differs from origin/main" "config message"
# A local replace ref swapping the trunk blob for the widened one must not count.
wide=$(cd "$W" && g hash-object -w .claude/local-env.json); orig=$(cd "$W" && g rev-parse origin/main:.claude/local-env.json)
(cd "$W" && g replace "$orig" "$wide")
run 78 "replace ref over the trunk blob" -- it --update; has "differs from origin/main" "replace message"
(cd "$W" && g replace -d "$orig" >/dev/null)
run 78 "GIT_DIR pointed elsewhere" GIT_DIR="$T/origin.git" -- it --update
cp "$T/cfg.bak" "$W/.claude/local-env.json"
echo 'echo widened' >> "$W/scripts/it.sh"
run 78 "runner script edited" -- it; has "differs from origin/main" "script message"
(cd "$W" && g checkout -q -- scripts/it.sh)
# The Trunk name comes from CLAUDE.md on origin's default branch, not the working tree.
(cd "$W" && g checkout -q -b feat/x \
  && sed -i.x 's/\*\*Trunk:\*\* `main`/**Trunk:** `feat\/x`/' CLAUDE.md && rm -f CLAUDE.md.x \
  && sed -i.x 's/"--no-build": null/"--no-build": null, "--update": null/' .claude/local-env.json \
  && rm -f .claude/local-env.json.x && g commit -qam declare && g push -q origin feat/x 2>/dev/null)
run 78 "working-tree CLAUDE.md declares a pushed branch Trunk" -- it --update; has "differs from origin/main" "declared-Trunk message"
(cd "$W" && g checkout -q main)

# ---- docker preflight comes before the file -------------------------------------------------------
rm -rf "$CFG"
echo remote-ctx > "$T/dmode"; run 68 "remote docker endpoint, file absent" -- it; has "not a local unix socket" "remote ctx"
echo remote-port > "$T/dmode"; run 68 "port on a non-local bind" -- it
echo down > "$T/dmode"; run 69 "service not running" -- it
: > "$T/dmode"
run 66 "file missing" -- it

# ---- the file -------------------------------------------------------------------------------------
put "$GOOD"; chmod 644 "$CFG/local.env"; run 77 "mode 644" -- it
put "$GOOD"; chmod 775 "$CFG"; run 77 "dir 775" -- it
put "$GOOD"; mv "$CFG/local.env" "$CFG/real"; ln -s real "$CFG/local.env"; run 77 "symlink" -- it
put "$GOOD"; rm "$CFG/local.env"; mkfifo -m 600 "$CFG/local.env"; run 77 "fifo, no hang" -- it
put "$(printf 'FIXTURE_DB_SECRET %s\n' "$M")"; run 65 "malformed" -- it
put "$(printf 'OTHER=%s\n' "$M")"; run 65 "unknown key" -- it
put "$(printf 'FIXTURE_DB_SECRET=%s\nFIXTURE_DB_SECRET=%s\n' "$M" "$M")"; run 65 "duplicate" -- it
put "$(printf 'FIXTURE_DB_SECRET=%s x\n' "$M")"; run 65 "space in value" -- it
put "$(printf 'FIXTURE_DB_SECRET=%s{\n' "$M")"; run 65 "brace in value" -- it
put "$(printf 'FIXTURE_DB_SECRET=%s\r\n' "$M")"; run 65 "CR" -- it
put "$GOOD"

# ---- pass line, rc, results scrub -----------------------------------------------------------------
run 0 "probe pass" -- probe
echo skipped > "$T/mode"; run 75 "probe skipped is not a pass" -- probe; has "not a pass" "75 note"
echo rc=7 > "$T/mode"; run 7 "child rc passes through" -- it
echo results > "$T/mode"; run 0 "results dir scrubbed" -- it
d=$(cat "$T/results"); grep -qF '{hidden}' "$d/out.trx" || fail "results file not scrubbed"
grep -qF -- "$M" "$d/out.trx" && fail "results file still holds the secret"
: > "$T/mode"

# ---- TERM is forwarded to the child group ---------------------------------------------------------
echo trap > "$T/mode"; rm -f "$T/ready" "$T/term"
(cd "$W" && exec env -i PATH="$P" HOME="$H" TMPDIR="$TMP" STUBMODE_FILE="$T/mode" TERM_FILE="$T/term" \
  READY_FILE="$T/ready" RESULTS_FILE="$T/results" bash .claude/lib/local-env/with-local-env.sh it \
  > "$T/sig.out" 2>&1) & pid=$!
for _ in $(seq 1 100); do [ -e "$T/ready" ] && break; sleep 0.1; done
[ -e "$T/ready" ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "TERM: the stub never got ready"; }
kill -TERM "$pid"; set +e; wait "$pid"; RC=$?; set -e; N=$((N + 1))
cat "$T/sig.out" >> "$T/all"
[ "$RC" = 130 ] || fail "TERM: rc $RC (want 130)"
[ "$(cat "$T/term" 2>/dev/null)" = got-term ] || fail "TERM did not reach the child"
: > "$T/mode"

# ---- a hung origin falls back to the offline rule, bounded ----------------------------------------
(cd "$W" && g symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true)
: > "$T/hang"
run 78 "hung origin, no local origin/HEAD" TRUNK_TRUST_LS_REMOTE_TIMEOUT=2 -- probe; has "git remote set-head origin" "set-head fix"
(cd "$W" && g remote set-head origin main)
# margin: the hung ls-remote is cut at TRUNK_TRUST_LS_REMOTE_TIMEOUT=2; the 20 s bound leaves 18 s of
# load and still fails a run that waits for the 60 s hang.
s=$(date +%s)
run 0 "hung ls-remote" TRUNK_TRUST_LS_REMOTE_TIMEOUT=2 -- probe
[ $(( $(date +%s) - s )) -lt 20 ] || fail "hung ls-remote was not bounded"
rm -f "$T/hang"

# ---- setup helpers --------------------------------------------------------------------------------
run 0 "setup info" -- --setup-info
[ "$OUT" = "$(printf 'dir=fixture-app\nkey=FIXTURE_DB_SECRET')" ] || fail "setup info: $OUT"
set +e
printf '%s' "$M" | (cd "$W" && env -i PATH="$P" HOME="$H" bash .claude/lib/local-env/with-local-env.sh --validate-stdin) >> "$T/all" 2>&1
[ $? = 0 ] || fail "validate-stdin rejected a good value"
printf 'bad value' | (cd "$W" && env -i PATH="$P" HOME="$H" bash .claude/lib/local-env/with-local-env.sh --validate-stdin) >> "$T/all" 2>&1
[ $? = 65 ] || fail "validate-stdin accepted a space"
(cd "$W" && env -i PATH="$P" HOME="$H" bash .claude/lib/local-env/local-env-init.sh < /dev/null) >> "$T/all" 2>&1
[ $? = 64 ] || fail "init ran without a TTY"
set -e; N=$((N + 3))

# ---- the sentinel never surfaced ------------------------------------------------------------------
grep -qF -- "$M" "$T/all" && fail "the secret appeared in wrapper output"
grep -qF -- "$M" "$T/docker-calls" && fail "the secret reached a docker call"
N=$((N + 1))
echo "local-env-test: OK ($N checks)"
