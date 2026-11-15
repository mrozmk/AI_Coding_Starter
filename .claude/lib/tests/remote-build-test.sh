#!/usr/bin/env bash
# Offline test of the remote build check (.claude/lib/remote-build/): the trunk-pinned config and node
# script, the incremental bundle, the throwaway worktree, exit codes, cleanup, injection-free argv and
# the fixed ssh options. No real ssh: an `ssh` stub runs the "remote" side locally in a fixture node
# home and records its argv; origin is a local bare repo; HOME is a fixture.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "remote-build-test: FAIL — $*"; exit 1; }
N=0

H="$T/home"; NODE="$T/node"; STUB="$T/stub"; CTL="$T/ctl"
mkdir -p "$H" "$NODE" "$STUB" "$CTL"
: > "$T/ssh-calls"
cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/ssh-calls"
while [ \$# -gt 0 ]; do case "\$1" in --) shift; break ;; -o) shift 2 ;; *) echo "stub: option before -- : \$1" >&2; exit 254 ;; esac; done
host=\$1; shift
[ -e "$T/down" ] && exit 255
cd "$NODE" && HOME="$NODE" exec sh -c "\$*"
EOF
chmod +x "$STUB/ssh"
P="$STUB:/usr/bin:/bin"
g() { env -i PATH="$P" HOME="$H" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$H/.gitconfig"
cp "$H/.gitconfig" "$NODE/.gitconfig"
g init -q "$NODE/remote-repo"

g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/w" 2>/dev/null
W="$T/w"
mkdir -p "$W/.claude/lib/remote-build" "$W/.claude/lib/trunk-trust" "$W/sub"
cp "$ST/.claude/lib/branch-model.sh" "$W/.claude/lib/"
cp "$ST/.claude/lib/trunk-trust/trunk_trust.py" "$W/.claude/lib/trunk-trust/"
cp "$ST/.claude/lib/remote-build/"{remote-build-check.sh,remote_build.py,remote-build-node.sh} "$W/.claude/lib/remote-build/"
printf '# P\n\n### Branch model\n\n**Preset:** trunk · **Trunk:** `main` · **Integration:** `main`\n' > "$W/CLAUDE.md"
printf '{"workflow": {"remote_build": true}}\n' > "$W/.claude/project-profile.json"
# The command under test: reports argv, cwd and env; rc and sleep come from control files.
cat > "$W/sub/check.sh" <<'EOF'
#!/usr/bin/env bash
: > "$CTL/ran"
printf 'argv:'; for a in "$@"; do printf '[%s]' "$a"; done; echo
echo "cwd:$(pwd)"
echo "env:${TOOL_FLAG-unset}"
[ -s "$CTL/sleep" ] && sleep "$(cat "$CTL/sleep")"
[ -e "$CTL/bg" ] && { sleep 30 & }  # a child left behind, holding the output pipe
exit "$(cat "$CTL/rc" 2>/dev/null || echo 0)"
EOF
config() {  # config <host> [timeout] — the config text
  printf '{"v": 1, "host": "%s", "repo": "remote-repo", "runs": "runs", "cwd": "sub", "nice": true, "timeout_s": %s,\n' "$1" "${2:-60}"
  printf ' "command": ["bash", "check.sh", "a b; touch %s/INJECT", "$(touch %s/INJECT2)"],\n' "$CTL" "$CTL"
  printf ' "env": {"CTL": "%s", "TOOL_FLAG": "on"}}\n' "$CTL"
}
config build-node > "$W/.claude/remote-build.json"
(cd "$W" && g add -A && g commit -qm init && g push -q origin main 2>/dev/null)
# The main checkout ($HARNESS_MAIN): the kit runs from there and reads switch, config and node script
# there; the team clone W only supplies HEAD and objects.
M="$T/main"; g clone -q "$T/origin.git" "$M" 2>/dev/null
publish() { (cd "$M" && g commit -qam "$1" && g push -q origin main 2>/dev/null); }

run() {  # run <expect rc> <label> [args…] → OUT
  local want="$1" label="$2"; shift 2
  set +e
  OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" HARNESS_MAIN="$M" \
    bash -c 'exec bash "$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh" "$@"' _ "$@" 2>&1)
  RC=$?; set -e; N=$((N + 1))
  [ "$RC" = "$want" ] || fail "$label: rc $RC (want $want): $OUT"
}
has() { case "$OUT" in *"$1"*) ;; *) fail "$2: no '$1' in: $OUT" ;; esac; }
clean_node() {  # nothing of a run may stay: no worktree, no bundle, no timeout marker, no temp ref
  [ -z "$(ls -A "$NODE/runs" 2>/dev/null)" ] || fail "$1: node runs dir not empty: $(ls -A "$NODE/runs")"
  [ "$(g -C "$NODE/remote-repo" worktree list | wc -l | tr -d ' ')" = 1 ] || fail "$1: node worktree left"
  [ -z "$(g -C "$W" for-each-ref refs/mc)" ] || fail "$1: local refs/mc left"
  N=$((N + 1))
}
SHA=$(g -C "$W" rev-parse HEAD)

# ---- 1/4. happy path, streamed output, one argv element per config element ------------------------
run 0 "happy path"
has "remote-build: commit $SHA -> build-node" "header"
has "argv:[a b; touch $CTL/INJECT][\$(touch $CTL/INJECT2)]" "argv intact"
has "cwd:$NODE/runs/mc-" "worktree cwd"
has "env:on" "env"
has "remote-build: node exit 0" "exit line"
[ -e "$CTL/INJECT" ] || [ -e "$CTL/INJECT2" ] && fail "a config element was run by a shell"
clean_node "after success"
echo 7 > "$CTL/rc"; run 7 "rc passes through"; rm "$CTL/rc"
clean_node "after a failing command"

# ---- 2. incremental bundle: the node kept a ref to the last commit, so it has it ---------------------
run 0 "node has the commit"; has "(bundle 0 bytes)" "empty bundle"

# ---- 2b. a child the command left behind is stopped, not waited for ---------------------------------
: > "$CTL/bg"; t0=$(date +%s)
run 0 "leftover child"
[ $(( $(date +%s) - t0 )) -lt 20 ] || fail "the run waited for a child the command left behind"
rm "$CTL/bg"; clean_node "after a leftover child"

# ---- 3. unreachable node: 75, no command ------------------------------------------------------------
rm -f "$CTL/ran"; : > "$T/ssh-calls"; : > "$T/down"
run 75 "node unreachable"; has "unreachable" "unreachable message"
[ "$(wc -l < "$T/ssh-calls" | tr -d ' ')" = 1 ] || fail "more than the preflight ran: $(cat "$T/ssh-calls")"
[ -e "$CTL/ran" ] && fail "the command ran with the node down"
rm -f "$T/down"

# ---- 5. refusals: arguments, switch, trunk rule, invalid config -------------------------------------
: > "$T/ssh-calls"
run 64 "arguments" extra
set +e; OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" bash .claude/lib/remote-build/remote-build-check.sh 2>&1); RC=$?; set -e
N=$((N + 1)); [ "$RC" = 78 ] || fail "kit inside the checked repo: rc $RC: $OUT"
has "run it from the main checkout" "self-location message"
# HARNESS_MAIN naming the checked repo another way: a symlink to it, or (case-insensitive file
# systems only) the same path in another case — both still the kit of the commit under test.
ln -s "$W" "$T/wlink"
WCASE=$(printf '%s' "$W" | sed 's|/w$|/W|')
for alias in "$T/wlink" $( [ -d "$WCASE/.claude" ] && echo "$WCASE" ); do
  set +e; OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" HARNESS_MAIN="$alias" \
    bash -c 'exec bash "$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh"' 2>&1); RC=$?; set -e
  N=$((N + 1)); [ "$RC" = 78 ] || fail "kit reached through $alias: rc $RC: $OUT"
  has "run it from the main checkout" "self-location through $alias"
done
cp "$M/.claude/project-profile.json" "$T/profile.bak"
printf '{"workflow": {}}\n' > "$M/.claude/project-profile.json"
run 78 "switch off in the main checkout"; has "workflow.remote_build" "off message"
cp "$T/profile.bak" "$M/.claude/project-profile.json"
config prod-node > "$M/.claude/remote-build.json"
run 78 "main checkout config differs from trunk"; has "differs from origin/main" "host message"
[ -s "$T/ssh-calls" ] && fail "ssh was called for an unapproved host: $(cat "$T/ssh-calls")"
(cd "$M" && g checkout -q -- .claude/remote-build.json)
sed -i.x '2i\
echo WIDENED' "$M/.claude/lib/remote-build/remote-build-node.sh"; rm -f "$M/.claude/lib/remote-build/remote-build-node.sh.x"
run 78 "main checkout node script differs from trunk"; has "remote-build-node.sh differs" "node script message"
(cd "$M" && g checkout -q -- .claude/lib/remote-build/remote-build-node.sh)
[ -s "$T/ssh-calls" ] && fail "ssh was called on a refusal"

# ---- the checked clone's own config, node script and origin have no say ----------------------------
config prod-node > "$W/.claude/remote-build.json"; printf '{"workflow": {}}\n' > "$W/.claude/project-profile.json"
sed -i.x '2i\
echo WIDENED' "$W/.claude/lib/remote-build/remote-build-node.sh"; rm -f "$W/.claude/lib/remote-build/remote-build-node.sh.x"
(cd "$W" && g commit -qam "branch widens" && g push -q origin HEAD:refs/heads/feat/x 2>/dev/null)
run 0 "clone-only host, switch and node script ignored"; has " -> build-node " "trunk host used"
case "$OUT" in *WIDENED*) fail "the clone's node script ran" ;; esac
g clone -q --bare "$T/origin.git" "$T/evil.git"
g clone -q "$T/evil.git" "$T/w2" 2>/dev/null
(cd "$T/w2" && config prod-node > .claude/remote-build.json && g commit -qam wide && g push -q origin main 2>/dev/null)
set +e; OUT=$(cd "$T/w2" && env -i PATH="$P" HOME="$H" HARNESS_MAIN="$M" \
  bash -c 'exec bash "$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh"' 2>&1); RC=$?; set -e
N=$((N + 1)); [ "$RC" = 0 ] || fail "clone with another origin: rc $RC: $OUT"
has " -> build-node " "another origin in the clone has no say"
(cd "$W" && g reset -q --hard HEAD~1)

# ---- unattended: a merge into trunk since the main checkout's last fetch is fetched, not refused ----
g clone -q "$T/origin.git" "$T/other" 2>/dev/null
(cd "$T/other" && echo x > other.txt && g add other.txt && g commit -qm other && g push -q origin main 2>/dev/null)
NEW=$(g -C "$T/other" rev-parse HEAD)
[ "$(g -C "$M" rev-parse refs/remotes/origin/main)" != "$NEW" ] || fail "fixture: main checkout not stale"
run 0 "stale origin/main in the main checkout is fetched"
[ "$(g -C "$M" rev-parse refs/remotes/origin/main)" = "$NEW" ] || fail "origin/main was not refreshed"
(cd "$M" && g merge -q --ff-only origin/main)
: > "$T/ssh-calls"
for bad in '-oProxyCommand=x' 'a b' 'h;x'; do
  config "$bad" > "$M/.claude/remote-build.json"; publish "bad host"
  run 78 "host '$bad'"; has "host must be one ssh alias" "host validation"
done
config build-node | sed 's/"runs": "runs"/"runs": "..\/up"/' > "$M/.claude/remote-build.json"
publish "dotdot"; run 78 "'..' in a path"
config build-node | sed 's/"command": \[/"command": "bash check.sh", "_x": [/' > "$M/.claude/remote-build.json"
publish "shell line"; run 78 "command as a shell line"; has "an argv" "command message"
[ -s "$T/ssh-calls" ] && fail "ssh was called on a refusal"
config build-node > "$M/.claude/remote-build.json"; publish "restore"

# ---- 7. ssh argv: fixed options, `--` before the alias ----------------------------------------------
: > "$T/ssh-calls"
run 0 "argv check run"
while read -r line; do
  case "$line" in *"-o BatchMode=yes"*"-- build-node "*) ;; *) fail "ssh argv: $line" ;; esac
  case "$line" in *StrictHostKeyChecking*|*UserKnownHostsFile*|*ProxyCommand*) fail "ssh option leak: $line" ;; esac
done < "$T/ssh-calls"
N=$((N + 1))

# ---- 8. timeout --------------------------------------------------------------------------------------
config build-node 1 > "$M/.claude/remote-build.json"; publish "short timeout"
echo 4 > "$CTL/sleep"
run 124 "command past timeout_s"; has "timed out after 1s" "timeout message"
rm "$CTL/sleep"
clean_node "after a timeout"

echo "remote-build-test: OK ($N checks)"
