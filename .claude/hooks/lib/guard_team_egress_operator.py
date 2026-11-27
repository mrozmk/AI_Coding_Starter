"""Readings beside guard_team_egress.py that keep the Operator out of calls they already decided or
that carry only data: the gh calls of a command the Operator invoked this turn (operator_rules), a
commit message fed to `git commit -F -` from a quoted here-document (commit_message_dropped), and a
plain git remote read standing beside a gh read (git_remote_read). Never allows by itself; every
reader is fail-closed ([] / the text unchanged / False: today's path)."""
import json
import os
import re

# The gh calls of each command, as local-rule text (guard_team_egress_supervisor.GH_RULE): covered
# only through gh_covered, so a host selector or unquoted shell syntax in the call still asks.
COMMANDS = {"/pr-create": ["Bash(gh pr create *)"],
            "/pr-merge": ["Bash(gh pr merge *)", "Bash(gh pr ready *)"]}
# team-evidence.sh TEAM_EVIDENCE_MACHINE_RE: a line a script or a peer session typed into the window.
MACHINE = re.compile(r"^(stop |gate |prompt |ask |attention |unasked |inbox:|relaunched: |human-only "
                     r"|rejected |continue granted |round |close refused: |relayed: |handed back: "
                     r"|\[peer\] |\[team-run\]|\[team-watch |<hc from=)")
# `git [-C <dir>] [-c user.name|email=<v>]… commit [-q] -F - <<'DELIM'` + body + DELIM: the body is
# the commit message — a quoted delimiter is never expanded and git never runs its stdin.
COMMIT_DOC = re.compile(r"\A(git(?: -C [\w./~-]+)?(?: -c user\.(?:name|email)=[\w@.+-]+)*"
                        r" commit(?: -q| --quiet)* -F - <<'([A-Za-z_]+)'\n)(?:.*\n)*?\2[ \t]*(?=\n|\Z)")
# Set by guard_team_egress.main from the hook payload: the session's own transcript.
TRANSCRIPT = None


def commit_message_dropped(cmd):
    """<cmd> without the here-document body of a leading `git commit -F -` (COMMIT_DOC); what
    follows the delimiter stays and is read as before."""
    m = COMMIT_DOC.match(cmd)
    return m.group(1) + m.group(2) + cmd[m.end():] if m else cmd


def git_remote_read(vals, text, egress_in):
    """A plain `git [-C <dir>] ls-remote|fetch …` the egress reader passes on its own: an allowed
    host, no option that runs a local command."""
    rest = vals[3:] if vals[1:2] == ["-C"] else vals[1:]
    if vals[:1] != ["git"] or rest[:1] not in (["ls-remote"], ["fetch"]):
        return False
    try:
        return egress_in(text) == ""
    except ValueError:
        return False


def turn_prompt(path):
    """Text of the newest message a human typed into the session of transcript <path> — the prompt
    of the running turn (a message sent mid-turn is no user record). "" when the transcript does
    not read whole from its end back to that message, or the message is a machine line."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except (OSError, UnicodeDecodeError, TypeError):
        return ""
    for line in reversed([x for x in lines if x.strip()]):
        try:
            e = json.loads(line)
        except ValueError:
            return ""
        if not isinstance(e, dict) or e.get("type") != "user" or e.get("isMeta") \
                or e.get("toolUseResult") is not None or e.get("isSidechain"):
            continue
        if (e.get("origin") or {}).get("kind") != "human":
            continue
        body = (e.get("message") or {}).get("content")
        if isinstance(body, list):
            body = " ".join(str(b.get("text", "")) for b in body
                            if isinstance(b, dict) and b.get("type") == "text")
        text = body.strip() if isinstance(body, str) else ""
        return "" if MACHINE.match(text) else text
    return ""


def operator_rules(cmd):
    """Local-rule texts for the gh calls of the commands the Operator named in the running turn's
    prompt (`/pr-create`, `/pr-merge` as whole words — typed, or the invoked slash command). The
    invocation is their decision; a later turn without the name grants nothing."""
    if "gh pr " not in cmd or not TRANSCRIPT or not str(TRANSCRIPT).endswith(".jsonl") \
            or not os.path.isfile(TRANSCRIPT):
        return []
    text = turn_prompt(TRANSCRIPT)
    return [r for name, rules in COMMANDS.items()
            if re.search(r"(?<![\w/.-])" + re.escape(name) + r"(?![\w-])", text) for r in rules]
