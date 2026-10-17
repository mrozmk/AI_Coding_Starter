#!/bin/bash
# Shared secret/credential patterns for guard-push.sh (commit range) and guard-commit.sh
# (staged set). Sourced, never executed: defines variables and functions only.
#
# Callers set LC_ALL=C (diffs carry arbitrary bytes). Every report built from these is
# PATHS and classes only — a matched line is never printed, or the secret re-leaks into
# stderr and the audit log.
#
# A6 (connection-string credential fields): `Password=`, `Pwd=`, `AccountKey=`,
# `SharedAccessKey=`, `AccessKey=` with a real value. Placeholders pass: empty, `<...>`,
# `{...}`, `${...}`, `$(...)`, `%VAR%`, placeholder words, `xxx`/`***`, and an
# `AccountKey=` inside the same literal as `AccountName=devstoreaccount1` (Azurite).

LEAK_ALLOW_MARK='guard-push:allow|pragma: ?allowlist secret|gitleaks:allow'

# A1+A2+A3: known-format secrets (zero-FP → hard block)
LEAK_HIGH_RE='-----BEGIN[A-Z ]*PRIVATE KEY-----'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|gh[pousr]_[0-9A-Za-z]{36}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|github_pat_[0-9A-Za-z_]{82}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|xox[baprs]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|glpat-[0-9A-Za-z_-]{20}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|AIza[0-9A-Za-z_-]{35}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|sk-ant-[0-9A-Za-z_-]{20,}|sk-proj-[0-9A-Za-z_-]{20,}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|(sk|rk)_live_[0-9A-Za-z]{20,}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|shp(at|ss)_[0-9a-fA-F]{32}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|SG\.[0-9A-Za-z_-]{22}\.[0-9A-Za-z_-]{43}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|ATATT[0-9A-Za-z_=.-]{20,}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|npm_[0-9A-Za-z]{36}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?|ftp)://[^:@/[:space:]]+:[^@/[:space:]]+@'
LEAK_HIGH_RE="$LEAK_HIGH_RE"'|SK[0-9a-f]{32}'

# A4: generic credential assignments (conservative → placeholder-filtered)
LEAK_A4_RE="(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}[\"']"
LEAK_A4_PLACEHOLDER='process\.env|os\.environ|getenv|System\.getenv|ENV\[|secrets\.|vault|\$\{|\$\(|<[A-Za-z0-9_]+>|x{3,}|changeme|change-me|your[_-]|example|placeholder|dummy|sample|redacted|fake|mock|null|none|undefined|\*{3,}|\.\.\.|%s|\{\{|0{6,}|123456'

# B1: credential files by name
LEAK_FILE_RE='(^|/)\.env($|\.)|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|key|p12|pfx|keystore|jks|ppk)$|(^|/)\.(npmrc|pypirc|netrc|htpasswd)$|(^|/)\.aws/credentials$|(^|/)kubeconfig$|\.(tfstate|tfvars)$|service[_-]?account.*\.json$|(^|/)local\.env$'

# stdin: a unified patch (`git log -p` or `git diff --cached`); stdout: `path<TAB>line` for
# every added line outside the allowlisted paths (examples, lockfiles, docs, pattern-bearing
# harness files, fixture dirs) — without the allowlist the gate self-triggers.
leak_added_lines() {
  awk '
    /^\+\+\+ / {
      p=$2; sub(/^b\//,"",p);
      skip = (p=="/dev/null") ||
        (p ~ /\.(example|sample|template|lock|md|snap|map)$/) ||
        (p ~ /(^|\/)\.agents\/reference\//) ||
        (p ~ /(^|\/)\.claude\/(settings\.json|memory-domains\.json)$/) ||
        (p ~ /(^|\/)\.claude\/hooks\/guard-push\.sh$/) ||
        (p ~ /(^|\/)\.claude\/hooks\/lib\/leak-patterns\.sh$/) ||
        (p ~ /(^|\/)(fixtures|__fixtures__|__mocks__|testdata)\//) ||
        (p ~ /(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/);
      next
    }
    /^--- / { next }
    /^\+/ { if (!skip) print p "\t" substr($0,2) }
  '
}

# stdin: `path<TAB>line`; stdout: each path (may repeat) whose line carries an A6 field
# with a real value.
leak_a6_paths() {
  awk '
    function is_placeholder(v,   lv) {
      lv = tolower(v)
      if (v == "") return 1
      if (v ~ /^<[^>]*>$/ || v ~ /^\{[^}]*\}$/) return 1
      if (v ~ /^\$\{[^}]*\}$/ || v ~ /^\$\([^)]*\)$/) return 1
      if (v ~ /^%[A-Za-z0-9_]+%$/) return 1
      if (lv ~ /^(placeholder|changeme|change-me|example|dummy|fake|redacted|none|null)$/) return 1
      if (lv ~ /^xxx+$/ || v ~ /^\*\*\*+$/) return 1
      return 0
    }
    # quoted value after its opening quote c: a doubled quote is a literal quote (ADO.NET escaping)
    function unquote(v, c,   out, i, ch) {
      out = ""
      for (i = 1; i <= length(v); i++) {
        ch = substr(v, i, 1)
        if (ch != c) { out = out ch; continue }
        if (substr(v, i + 1, 1) == c) { out = out c; i++; continue }
        break
      }
      return out
    }
    # the literal around position p, bounded by the nearest quote on each side; a wrong
    # boundary only shrinks the literal, so the emulator exemption fails safe (hit kept)
    function around(l, p,   a, b) {
      a = substr(l, 1, p - 1); while (match(a, /["\047\001]/)) a = substr(a, RSTART + 1)
      b = substr(l, p); if (match(b, /["\047\001]/)) b = substr(b, 1, RSTART - 1)
      return a b
    }
    BEGIN { FS = "\t"; Q = "\001" }
    {
      path = $1; line = substr($0, length($1) + 2); found = 0
      gsub(/\\"/, Q, line)
      rest = line; off = 0
      # key glued to `=`: connection strings write `Password=x`; C# `x.Password = y` stays out
      while (!found && match(tolower(rest), /(password|pwd|sharedaccesskey|accountkey|accesskey)=/)) {
        key = substr(tolower(rest), RSTART, RLENGTH); pre = substr(rest, RSTART - 1, 1)
        at = RSTART; pos = off + RSTART; v = substr(rest, RSTART + RLENGTH)
        off += RSTART + RLENGTH - 1; rest = v
        if (at > 1 && pre ~ /[A-Za-z0-9_]/) continue
        sub(/^[ \t]+/, "", v); c = substr(v, 1, 1)
        if (c == Q || c == "\"" || c == "\047") val = unquote(substr(v, 2), c)
        else val = (match(v, /[;"]/) ? substr(v, 1, RSTART - 1) : v)
        sub(/[ \t]+$/, "", val)
        if (is_placeholder(val)) continue
        if (key == "accountkey=" && tolower(around(line, pos)) ~ /(^|;)[ \t]*accountname[ \t]*=[ \t]*devstoreaccount1[ \t]*(;|$)/) continue
        found = 1
      }
      if (found) print path
    }
  '
}

# $1: the `path<TAB>line` stream. Sets LEAK_HITS_HIGH, LEAK_HITS_A4 (matched stream lines)
# and LEAK_HITS_A6 (unique paths). The allow marker is filtered before A6.
leak_scan() {
  LEAK_HITS_HIGH=$(printf '%s\n' "$1" | grep -E -- "$LEAK_HIGH_RE" | grep -viE -- "$LEAK_ALLOW_MARK")
  LEAK_HITS_A4=$(printf '%s\n' "$1" | grep -iE -- "$LEAK_A4_RE" | grep -viE -- "$LEAK_A4_PLACEHOLDER" | grep -viE -- "$LEAK_ALLOW_MARK")
  LEAK_HITS_A6=$(printf '%s\n' "$1" | grep -viE -- "$LEAK_ALLOW_MARK" | leak_a6_paths | sort -u)
}

# stdin: file names; stdout: B1 hits, sample/template copies excluded.
leak_file_hits() {
  grep -E -- "$LEAK_FILE_RE" | grep -vE -- '\.(example|sample|template)$|\.dist$'
}

# $1: the label of the credential-file bullet. Prints one bullet per class set in LEAK_HITS_*
# (LEAK_HITS_FILE included) with its paths.
leak_report() {
  [ -n "$LEAK_HITS_HIGH" ] && { echo "• Known-format secret/token or private key in:"; printf '%s\n' "$LEAK_HITS_HIGH" | cut -f1 | sort -u | sed 's/^/    - /'; }
  [ -n "$LEAK_HITS_A4" ] && { echo "• Hardcoded credential assignment in:"; printf '%s\n' "$LEAK_HITS_A4" | cut -f1 | sort -u | sed 's/^/    - /'; }
  [ -n "$LEAK_HITS_A6" ] && { echo "• Credential field in a connection string (Password=/Pwd=/AccountKey=/SharedAccessKey=/AccessKey=) in:"; printf '%s\n' "$LEAK_HITS_A6" | sed 's/^/    - /'; }
  [ -n "$LEAK_HITS_FILE" ] && { echo "• $1:"; printf '%s\n' "$LEAK_HITS_FILE" | sed 's/^/    - /'; }
  true
}
