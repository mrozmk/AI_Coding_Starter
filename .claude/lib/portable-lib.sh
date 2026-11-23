#!/bin/bash
# portable-lib.sh — sourced: GNU/BSD userland helpers for the team runtime scripts (macOS and
# GNU/Linux, e.g. WSL). No side effects on source; bash 3.2; never exits.
#
#   file_mode <path>                 permission bits in octal, special bits masked (600) | rc 1
#   file_mtime <path>                modification time, epoch seconds | rc 1
#   new_uuid                         a lower-case UUID (uuidgen, else Python) | rc 1
#   epoch_fmt [-u] <epoch> <+fmt>    date(1) of an epoch (GNU -d @n, else BSD -r n)
#
# GNU first: GNU `stat -f` means "file system" and prints its lines to stdout before failing, so a
# BSD-first `stat -f … || stat -c …` leaks them into the value. Every candidate's output is used
# only when it exited 0 and has the expected shape; a symlink is never followed (lstat).

file_mode() {
  local v
  if v="$(stat -c %a "$1" 2>/dev/null)" && [[ "$v" =~ ^[0-7]+$ ]]; then :
  elif v="$(stat -f %Lp "$1" 2>/dev/null)" && [[ "$v" =~ ^[0-7]+$ ]]; then :
  elif v="$(python3 -I -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o777)[2:])' "$1" 2>/dev/null)" \
       && [[ "$v" =~ ^[0-7]+$ ]]; then :
  else return 1
  fi
  printf '%o\n' "$(( 8#$v & 8#777 ))"
}

file_mtime() {
  local v
  if v="$(stat -c %Y "$1" 2>/dev/null)" && [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; return 0; fi
  if v="$(stat -f %m "$1" 2>/dev/null)" && [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; return 0; fi
  if v="$(python3 -I -c 'import os,sys; print(int(os.lstat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null)" \
     && [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; return 0; fi
  return 1
}

new_uuid() {
  local v re='^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
  if v="$(uuidgen 2>/dev/null)"; then
    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    if [[ "$v" =~ $re ]]; then echo "$v"; return 0; fi
  fi
  if v="$(python3 -I -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)" && [[ "$v" =~ $re ]]; then
    echo "$v"; return 0
  fi
  return 1
}

epoch_fmt() {
  local u=""
  if [ "${1:-}" = -u ]; then u=1; shift; fi
  if date -d @0 +%s >/dev/null 2>&1; then date ${u:+-u} -d "@$1" "$2"
  else date ${u:+-u} -r "$1" "$2"
  fi
}
