"""Decides whether the supervisor may press Enter on a team role's permission prompt (TT-1041).

Reads the captured pane on stdin and the clone root as argv[1]. Exit 0 = tier 1 (nothing in the
prompt matches an ask/deny rule of the clone's settings and the SQL guard stays quiet), exit 1 =
the Operator must answer in the window, with the reason on stderr. A prompt whose command block
cannot be found is refused too — never approve what was not read.
"""
import fnmatch
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hooks", "lib"))
import guard_destructive_sql  # noqa: E402

END = re.compile(r"Do you want to (proceed|make this edit|create|allow)|❯ *1\. Yes")
START = re.compile(r"^\s*(Bash command|Bash\(|Edit file|Write file|Create file|Read file|WebFetch|Fetch)")


def command_block(pane):
    lines = pane.splitlines()
    end = next((i for i, l in enumerate(lines) if END.search(l)), None)
    if end is None:
        return None
    start = next((i for i in range(end - 1, -1, -1) if START.search(lines[i])), None)
    if start is None:
        return None
    body = [re.sub(r"^[\s│┃|>]+", "", l) for l in lines[start + 1:end]]
    return "\n".join(l for l in body if l.strip())


def rules(clone):
    out = []
    for rel in (".claude/settings.json", ".claude/settings.local.json"):
        try:
            with open(os.path.join(clone, rel), encoding="utf-8") as fh:
                perms = json.load(fh).get("permissions", {})
        except (OSError, ValueError):
            continue
        for tier in ("deny", "ask"):
            for rule in perms.get(tier, []):
                m = re.match(r"^Bash\((.*)\)$", rule)
                if m:
                    pat = m.group(1)
                    pat = pat[:-2] + "*" if pat.endswith(":*") else pat
                    out.append((tier, rule, pat))
    return out


def main():
    pane = sys.stdin.read()
    clone = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    block = command_block(pane)
    if block is None:
        print("refuse: could not read the command behind the prompt", file=sys.stderr)
        return 1
    cmd = block
    decision, reason = guard_destructive_sql.classify(cmd, clone, clone)
    if decision:
        print("refuse (%s): %s" % (decision, reason), file=sys.stderr)
        return 1
    for line in cmd.splitlines():
        text = line.strip()
        for tier, rule, pat in rules(clone):
            if fnmatch.fnmatchcase(text, pat) or fnmatch.fnmatchcase(text, pat + "*"):
                print("refuse (%s-tier): %s matches %s" % (tier, text, rule), file=sys.stderr)
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
