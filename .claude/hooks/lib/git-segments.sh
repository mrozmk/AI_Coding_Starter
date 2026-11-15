# Sourced by guard-commit.sh and guard-push.sh: find `git <sub>` invocations a plain regex misses —
# in a subshell `( … )`, a `$( … )` / backtick substitution, or a `bash|sh|zsh|dash -c '…'` string —
# without matching quoted text such as `echo 'git push'` or a commit message naming git push.

# git_segments <command> → one simple command per line: split outside quotes on ; & | ( ) `,
# newlines and a standalone { or } (a group or a function body); the quoted argument of `<shell> -c` is split the same way, as further segments.
git_segments() {
  printf '%s' "$1" | LC_ALL=C awk -v sq="'" '
    function flush() { gsub(/^[ \t]+|[ \t]+$/, "", cur); if (cur != "") print cur; cur = "" }
    function split_cmd(s,    i, n, c, q, buf) {
      n = length(s); q = ""; buf = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q != "") {
          if (q == "\"" && c == "\\" && i < n) { buf = buf c substr(s, ++i, 1); continue }
          if (c == q) {
            if (cur ~ /(^|[ \t])(bash|sh|zsh|dash)([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*c[ \t]*$/) {
              pending[++np] = buf; cur = cur "Q"
            } else cur = cur q buf q
            q = ""; buf = ""; continue
          }
          buf = buf (c == "\n" ? " " : c); continue
        }
        if (c == "\"" || c == sq) { q = c; continue }
        if (c ~ /[;&|()`\n]/) { flush(); continue }
        # `{` / `}` are group words only when they stand alone: `{ cmd; }`, `f() { cmd; }` —
        # never inside a word such as ${VAR} or a refspec.
        if ((c == "{" || c == "}") && cur ~ /^[ \t]*$|[ \t]$/ && (i == n || substr(s, i + 1, 1) ~ /[ \t\n;]/)) {
          flush(); continue
        }
        cur = cur c
      }
      if (q != "") cur = cur q buf
      flush()
    }
    { text = text (NR > 1 ? "\n" : "") $0 }
    END { np = 0; split_cmd(text); for (k = 1; k <= np; k++) split_cmd(pending[k]) }'
}

# git_seg_is <segment> <sub> → true when the segment itself runs `git [-C dir|-c k=v]… <sub>`,
# optionally after VAR=value assignments or time/nohup/command/exec/env. Quoted spans are masked
# first, so a quoted `git <sub>` is never an invocation.
git_seg_is() {
  printf '%s' "$1" | sed -E "s/'[^']*'/Q/g; s/\"([^\"\\\\]|\\\\.)*\"/Q/g" | grep -Eq \
    "^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|time|nohup|command|exec|env|sudo|if|then|else|elif|do|while|until|!)[[:space:]]+)*git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|\$)"
}

# git_first <command> <sub> → the first segment running `git <sub>`, prefixed with the last
# `cd <dir> &&` before it in the split order (the dir the hooks' own resolution expects); empty
# when there is none.
git_first() {
  local seg d cdir=""
  while IFS= read -r seg; do
    d=$(printf '%s' "$seg" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p")
    if [ -n "$d" ]; then cdir="$d"; continue; fi
    if git_seg_is "$seg" "$2"; then
      if [ -n "$cdir" ]; then printf 'cd "%s" && %s\n' "$cdir" "$seg"; else printf '%s\n' "$seg"; fi
      return 0
    fi
  done <<EOF_GS
$(git_segments "$1")
EOF_GS
  return 1
}
