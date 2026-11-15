#!/usr/bin/env bash
# Offline test of the guarded az write wrapper (.claude/lib/guarded-writes/az-write.sh): the switch,
# the trunk-approved config, the option schema, the clean environment and the masked log. Never runs
# a real az: PATH is the stub dir + /usr/bin:/bin, HOME is a fixture, origin is a local bare repo.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "guarded-writes-az-test: FAIL — $*"; exit 1; }
N=0

H="$T/home"; STUB="$T/stub"; mkdir -p "$H/.azure-write" "$STUB"
: > "$H/.azure-write/azureProfile.json"; : > "$H/calls"
cat > "$STUB/az" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/calls"
printf 'cfg=%s pat=%s\n' "$AZURE_CONFIG_DIR" "${AZURE_DEVOPS_EXT_PAT:-}" >> "$HOME/env"
exit "$(cat "$HOME/stub-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$STUB/az"
P="$STUB:/usr/bin:/bin"
g() { env -i PATH="$P" HOME="$H" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$H/.gitconfig"

# A project: CLAUDE.md Branch model (Trunk main), the kit, the switch on, origin = bare repo.
g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/w" 2>/dev/null
W="$T/w"
mkdir -p "$W/.claude/lib/guarded-writes"
cp "$ST/.claude/lib/branch-model.sh" "$W/.claude/lib/"
cp "$ST/.claude/lib/guarded-writes/"{az-write.sh,guarded_write.py} "$W/.claude/lib/guarded-writes/"
printf '# P\n\n### Branch model\n\n**Preset:** trunk · **Trunk:** `main` · **Integration:** `main`\n' > "$W/CLAUDE.md"
printf '{"workflow": {"guarded_writes": true}}\n' > "$W/.claude/project-profile.json"
cat > "$W/.claude/guarded-writes.json" <<'EOF'
{"v": 1, "az": {"ops": {
  "webapp restart": {"options": ["--resource-group", "--name", "--slot"],
    "required": ["--resource-group", "--name", "--slot"], "pin": {"--slot": ["staging"]}},
  "webapp config appsettings set": {"options": ["--resource-group", "--name", "--settings"],
    "multi": ["--settings"], "required": ["--name"]},
  "sql db update": {"options": ["--resource-group", "--server", "--name", "--admin-password"],
    "aliases": {"-s": "--server", "-p": "--admin-password"}},
  "keyvault secret set": {"options": ["--vault-name", "--name", "--value"]}},
  "rest": [{"url_prefix": "https://management.example.invalid/sub/", "methods": ["patch"]}]}}
EOF
(cd "$W" && g add -A && g commit -qm init && g push -q origin main 2>/dev/null)

run() {  # run <expect rc> <label> <az args…> → OUT; asserts the rc, and no az call on a refusal
  local want="$1" label="$2" before; shift 2
  before=$(wc -l < "$H/calls" 2>/dev/null || echo 0)
  set +e
  OUT=$(cd "$W" && env -i PATH="$P" HOME="$H" AZURE_DEVOPS_EXT_PAT=leaked-pat \
    bash .claude/lib/guarded-writes/az-write.sh "$@" 2>&1)
  RC=$?; set -e; N=$((N + 1))
  [ "$RC" = "$want" ] || fail "$label: rc $RC (want $want): $OUT"
  if [ "$want" = 2 ]; then
    [ "$(wc -l < "$H/calls" 2>/dev/null || echo 0)" = "$before" ] || fail "$label: az was called on a refusal"
  fi
}
ok() { run 0 "$@"; }
no() { run 2 "$@"; case "$OUT" in *az-write:*) ;; *) fail "$1: no refusal message: $OUT" ;; esac; }

# ---- happy path: the write profile, a clean environment ------------------------------------------
ok "restart" webapp restart -g rg -n app --slot staging
[ "$(tail -1 "$H/calls")" = "webapp restart -g rg -n app --slot staging" ] || fail "argv not passed through"
[ "$(tail -1 "$H/env")" = "cfg=$H/.azure-write pat=" ] || fail "env: $(tail -1 "$H/env")"
echo 7 > "$H/stub-rc"; run 7 "az rc passes through" webapp restart -g rg -n app --slot staging; rm "$H/stub-rc"

# ---- switch and config acceptance ----------------------------------------------------------------
cp "$W/.claude/project-profile.json" "$T/profile.bak"
printf '{"workflow": {"guarded_writes": false}}\n' > "$W/.claude/project-profile.json"
no "switch off" webapp restart -g rg -n app --slot staging
cp "$T/profile.bak" "$W/.claude/project-profile.json"

cp "$W/.claude/guarded-writes.json" "$T/cfg.bak"
printf '\n' >> "$W/.claude/guarded-writes.json"
no "working-tree edit" webapp restart -g rg -n app --slot staging
case "$OUT" in *"differs from origin/main"*) ;; *) fail "working-tree edit message: $OUT" ;; esac
(cd "$W" && g commit -qam widen)
no "committed, not pushed" webapp restart -g rg -n app --slot staging
OLD=$(cd "$W" && g rev-parse origin/main)
(cd "$W" && g update-ref refs/remotes/origin/main HEAD)
no "local origin ref rewritten" webapp restart -g rg -n app --slot staging
case "$OUT" in *"does not match what origin has"*) ;; *) fail "rewritten ref message: $OUT" ;; esac
(cd "$W" && g update-ref refs/remotes/origin/main "$OLD" && g branch -q origin/main HEAD)
no "local branch shadowing origin/main" webapp restart -g rg -n app --slot staging
(cd "$W" && g branch -q -D origin/main && g reset -q --hard "$OLD")
ok "back on trunk" webapp restart -g rg -n app --slot staging

(cd "$W" && g rm -q --cached .claude/guarded-writes.json && g commit -qm untrack)
no "untracked config" webapp restart -g rg -n app --slot staging
case "$OUT" in *"not tracked"*) ;; *) fail "untracked message: $OUT" ;; esac
(cd "$W" && g reset -q --hard "$OLD")

mv "$W/CLAUDE.md" "$T/claude.bak"
no "no Branch model" webapp restart -g rg -n app --slot staging
mv "$T/claude.bak" "$W/CLAUDE.md"

# a config that exists only locally (never on origin) in a fresh project
g init -q --bare "$T/o2.git"; g clone -q "$T/o2.git" "$T/w2" 2>/dev/null
cp -R "$W/.claude" "$W/CLAUDE.md" "$T/w2/"
(cd "$T/w2" && g add CLAUDE.md .claude/lib .claude/project-profile.json && g commit -qm a && g push -q origin main 2>/dev/null \
  && g add .claude/guarded-writes.json && g commit -qm cfg)
set +e; OUT=$(cd "$T/w2" && env -i PATH="$P" HOME="$H" bash .claude/lib/guarded-writes/az-write.sh webapp restart -g rg -n app --slot staging 2>&1); RC=$?; set -e
[ "$RC" = 2 ] && case "$OUT" in *"not on origin/main"*) true ;; *) false ;; esac || fail "config only local: $RC $OUT"
N=$((N + 1))

mv "$H/.azure-write" "$H/.azure-write.off"
no "no write profile" webapp restart -g rg -n app --slot staging
mv "$H/.azure-write.off" "$H/.azure-write"

# ---- the option schema ---------------------------------------------------------------------------
no "unknown operation" webapp delete -g rg -n app
no "abbreviation" webapp restart -g rg --nam app --slot staging
no "duplicate" webapp restart -g rg -n app -n app2 --slot staging
no "--ids" webapp restart --ids=/subscriptions/x --slot staging
no "attached short decoy" webapp restart -g rg -n=app --slot staging
no "positional" webapp restart -g rg -n app --slot staging extra
no "required missing (no slot → production)" webapp restart -g rg -n app
no "pin" webapp restart -g rg -n app --slot production
no "@file value" webapp restart -g rg -n @/etc/hosts --slot staging
no "profile override" webapp restart -g rg -n app --slot staging --query AZURE_CONFIG_DIR
ok "multi values" webapp config appsettings set -n app --settings A=1 B=2
ok "per-op alias" sql db update -g rg -s srv -n db
no "rest headers refused" rest --method patch --url https://management.example.invalid/sub/x --headers Authorization=Bearer
no "rest method" rest --method delete --url https://management.example.invalid/sub/x
no "rest dot segment" rest --method patch --url https://management.example.invalid/sub/../other/x
no "rest encoded dot segment" rest --method patch --url https://management.example.invalid/sub/%2e%2e/other/x
no "rest host" rest --method patch --url https://other.example.invalid/sub/x
ok "rest allowed" rest --method PATCH --uri https://management.example.invalid/sub/x --body '{"a":1}'

no "rest --output-file" rest --method patch --url https://management.example.invalid/sub/x --output-file x.json
ok "newline in a value" webapp restart -g "$(printf 'rg\n2026-01-01T00:00:00Z\trc=0')" -n app --slot staging
[ "$(grep -c $'^2026-01-01T00:00:00Z' "$H/.agent-ops/az-write.log" || true)" = 0 ] || fail "a value forged a log record"
ok "json value under a plain option" webapp restart -g '{"x":"jsonsecretvalue"}' -n app --slot staging

# ---- the log: masked, owner-only, with rc --------------------------------------------------------
ok "secret values" sql db update -g rg -s srv -n db --admin-password hunter2secret
ok "per-op alias secret" sql db update -g rg -s srv -n db -p aliasp4ss
ok "keyvault value" keyvault secret set --vault-name v --name n --value kv5ecret
ok "settings values" webapp config appsettings set -n app --settings API_KEY=s3cr3tvalue PLAIN=visiblevalue
LOGF="$H/.agent-ops/az-write.log"
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # GNU first: GNU `stat -f` prints fs info
[ "$(mode "$LOGF")" = 600 ] || fail "the log is not owner-only"
for s in hunter2secret aliasp4ss kv5ecret s3cr3tvalue visiblevalue '"a":1' jsonsecretvalue; do
  ! grep -qF "$s" "$LOGF" || fail "the log holds a secret value: $s"
done
grep -q 'API_KEY=<masked>' "$LOGF" && grep -q -- '--admin-password <masked>' "$LOGF" && grep -q $'\trc=0$' "$LOGF" \
  || fail "log shape"
N=$((N + 1))

echo "guarded-writes-az-test: OK ($N checks)"
