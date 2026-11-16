"""The per-run TeamLead's Bash check, run by guard-teamlead-bash.sh before every Bash call.

Usage: python3 -I team_lead_bash.py <clone> <run> [<main checkout>] < command
       → exit 0 allowed · exit 2 refused, the reason on stdout

Refused:
  - a key or text sent into a session: tmux's send-keys/send/paste-buffer, hc keys/send/interrupt,
    session-host.sh keys/type/send to a stage address (<team>-planner|coder|qa|wrapup|cli) — the
    lead never presses a key in a stage window (a human-only prompt is the Operator's there);
  - team-inbox.sh done or close-run for any address but the lead's own team (another inbox is not its
    to clear);
  - any command that names a protected path, unless it only reads it or is one of the scripts that
    own those files. Protected: everything under the clone's and the main checkout's
    .agents/team/ except the lead's own files under runs/<run>/ (and its round dirs r<n>/), the clone's
    .claude/ (the scripts and guards themselves) and any *.jsonl (a stage transcript). The owning
    scripts count only when run from the clone's .claude/lib/; so does /prime's closing
    `bash .claude/lib/costs/runtime-mark.sh stage end <name>` (exactly that form, nothing else
    under costs/). A redirection target, a `bash -c` string and a path inside a
    word (`open('…/answers.md','w')`) count; a path behind $VAR or a backtick cannot be resolved
    and is refused when it names .agents/team.
Best effort on command text: a path built at run time can pass (team-lead.md §7, limits).
"""
import glob
import json
import os
import re
import sys
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import team_prompt_check as c  # noqa: E402

OWN = re.compile(r"^(r[0-9]+/)?(gate-[a-z]+-[0-9]+\.md|rework-[0-9]+\.md|digest\.md|"
                 r"teamlead-notes\.md|opinion-[0-9]+\.md|acceptance-brief\.md|blind-check\.md|"
                 r"wrapup-decision-[0-9]+\.md)$")
SCRIPTS = {"team-verdict.sh", "team-answer.sh", "team-lead.sh", "team-tracker.sh", "team-inbox.sh",
           "tracker-snapshot.mjs", "codex-bg.sh", "session-host.sh"}
# Commands that only read their file operands (sort -o, uniq <out>, sed -i write, so they are not here).
READERS = {"cat", "head", "tail", "less", "jq", "grep", "egrep", "rg", "wc", "ls", "diff", "stat",
           "file", "cut", "shasum", "md5", "test", "[", "realpath", "cd", "pushd"}
STAGE_NAME = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
STAGES = re.compile(r"^[a-z0-9-]+-(planner|coder|qa|wrapup|cli)$")
TEAM_TEXT = re.compile(r"[A-Za-z0-9_./~${}`*?-]*\.agents/team(/[A-Za-z0-9_./~${}`*?<>-]*)?")


def keys_refusal(w):
    """The reason a command sends keys or text into a session, or None."""
    name = os.path.basename(w[0]) if w else ""
    # tmux takes any unique command prefix: `send-k` is send-keys, `paste` is paste-buffer.
    hit = next((x for x in w[1:] if x in ("send", "pasteb") or x.startswith(("send-k", "paste"))),
               None) if name == "tmux" else None
    if hit:
        return "TeamLead never sends keys into a session (tmux %s)" % hit
    if name == "hc" and w[1:2] and w[1] in ("keys", "send", "interrupt"):
        return "TeamLead never sends keys into a session (hc %s)" % w[1]
    if name == "session-host.sh" or (name in ("bash", "sh") and w[1:2]
                                     and os.path.basename(w[1]) == "session-host.sh"):
        rest = w[1:] if name == "session-host.sh" else w[2:]
        if rest[:1] and rest[0] in ("keys", "type", "send") and len(rest) > 1 \
                and STAGES.match(rest[1]):
            return "TeamLead never presses a key in a stage window (session-host.sh %s %s)" % (
                rest[0], rest[1])
    return None


def inbox_refusal(w, clone):
    """The reason a team-inbox.sh call marks another address's message done, or None."""
    name = os.path.basename(w[0]) if w else ""
    if name == "team-inbox.sh":
        rest = w[1:]
    elif name in ("bash", "sh"):
        # Shell options first (`bash -x …/team-inbox.sh`), then the script.
        i = next((k for k, x in enumerate(w[1:], 1) if not x.startswith("-")), len(w))
        if os.path.basename(w[i] if i < len(w) else "") != "team-inbox.sh":
            return None
        rest = w[i + 1:]
    else:
        return None
    if rest[:1] == ["--main"]:
        rest = rest[2:]
    if rest[:1] not in (["done"], ["close-run"]):
        return None
    try:
        with open(os.path.join(clone, ".agents", "team", "team.json")) as f:
            own = json.load(f).get("team") or ""
    except (OSError, ValueError, AttributeError):
        own = ""
    if own and rest[1:2] == [own]:
        return None
    return "TeamLead marks only its own team's inbox done (team-inbox.sh %s %s …)" % (
        rest[0], own or "<team>")


class Paths:
    def __init__(self, clone, run, main):
        self.clone = os.path.realpath(clone)
        self.teams = [os.path.realpath(os.path.join(d, ".agents", "team"))
                      for d in {clone, main or clone}]
        self.own = os.path.realpath(os.path.join(clone, ".agents", "team", "runs", run))
        # Resolved: a clone may link its .claude/ (or lib/) elsewhere.
        self.claude = os.path.realpath(os.path.join(self.clone, ".claude"))
        self.lib = os.path.realpath(os.path.join(self.clone, ".claude", "lib"))
        self.mark = os.path.realpath(os.path.join(self.lib, "costs", "runtime-mark.sh"))

    def protected(self, full):
        if full.endswith(".jsonl") or c.under(full, [self.claude]):
            return True
        if not any(c.under(full, [t]) or full == t for t in self.teams):
            return False
        rel = os.path.relpath(full, self.own)
        return not (c.under(full, [self.own]) and OWN.match(rel))

    def hit(self, word, bases):
        """True when <word> (or a path inside it) names a protected path from any base dir."""
        cands = [word] + [m.group(0) for m in TEAM_TEXT.finditer(word) if m.group(0) != word]
        for part in cands:
            if re.search(r"[$`]", part):
                if ".agents/team" in part:
                    return True
                continue
            for base in bases:
                full = os.path.join(base, os.path.expanduser(part))
                hits = glob.glob(full) if re.search(r"[*?[]", part) else [full]
                if any(self.protected(os.path.realpath(h)) for h in hits):
                    return True
        return False


def check(clone, run, main, cmd):
    """→ None when allowed, else the refusal line."""
    try:
        cmds = c.canonical(cmd)
    except c.Refuse as e:
        return "TeamLead Bash: %s" % e
    paths = Paths(clone, run, main)
    # Every directory a `cd` chain can reach is a base, each target joined to every earlier base
    # (`cd a && cd ../team/…`); a target behind $VAR or a backtick cannot be followed at all.
    bases = [paths.clone]
    for w in map(c.argv_plain, cmds):
        if w[:1] in (["cd"], ["pushd"]) and len(w) > 1:
            if re.search(r"[$`]", w[1]):
                return "TeamLead Bash: cd %s cannot be resolved — use paths from the clone root" % w[1]
            bases += [os.path.realpath(os.path.join(b, os.path.expanduser(w[1]))) for b in bases]
    for words in cmds:
        w = c.argv_plain(words)
        why = keys_refusal(w) or keys_refusal(c.shell_words(words)) or inbox_refusal(w, clone)
        if why:
            return why
        if not any(paths.hit(x, bases) for x in words):
            continue
        name = os.path.basename(w[0]) if w else ""
        prog = w[1] if name in ("bash", "sh", "node") and len(w) > 1 else w[0] if w else ""
        script = os.path.basename(prog) in SCRIPTS and os.path.realpath(
            os.path.join(paths.clone, prog)) == os.path.join(paths.lib, os.path.basename(prog))
        # /prime's closing cost mark (a no-op the stage hook records): this one file, this one form.
        script = script or (name == "bash" and len(w) == 5 and w[2:4] == ["stage", "end"]
                            and STAGE_NAME.match(w[4]) and os.path.realpath(
                                os.path.join(paths.clone, prog)) == paths.mark)
        # One word alone is a redirection operand (`> file`) or the file run as a program.
        if script or (name in READERS and len(words) > 1):
            continue
        return ("TeamLead Bash: %s names a protected file — verdicts, decisions and answers are "
                "written by the scripts, never by the lead" % (name or "a command"))
    return None


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    why = check(argv[1], argv[2], argv[3] if len(argv) == 4 else None, sys.stdin.read())
    if why:
        print(why)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
