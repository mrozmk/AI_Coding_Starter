"""The per-run TeamLead's Bash check, run by guard-teamlead-bash.sh before every Bash call.

Usage: python3 -I team_lead_bash.py <clone> <run> [<main checkout>] [--trust clone] < command
       → exit 0 allowed · exit 2 refused, the reason on stdout
       --trust clone: the guard runs from the clone (an older profile registered the clone's copy):
       the owning scripts count from the clone's lib, as before the main-checkout tools.

Refused:
  - a key or text sent into a session: tmux's send-keys/send/paste-buffer, hc keys/send/interrupt,
    session-host.sh keys/type/send to a stage address (<team>-planner|coder|qa|wrapup|cli) — the
    lead never presses a key in a stage window (a human-only prompt is the Operator's there);
  - team-inbox.sh done or close-run for any address but the lead's own team (another inbox is not its
    to clear);
  - any command that names a protected path, unless it only reads it or is one of the scripts that
    own those files. Read-only: cat/head/tail/grep/rg/wc/ls/diff/cmp/stat/file/echo/printf and
    the like, sed without -i or a w/W/e command, awk whose program has no >, |, system or getline,
    sort without -o, find without -delete/-exec/-ok/-fprint, git log|show|diff|ls-tree|status|
    rev-parse|cat-file|blame|ls-files|grep|merge-base|describe|shortlog (no --output), bash/sh -n,
    a `for NAME in …` header, a bare assignment, and an input redirection (`< file`); a shell
    keyword (do, then, else, if, while, until, !) is dropped before the command is judged. Such a
    read is refused when the same command feeds a command taking its targets from stdin (xargs,
    parallel, read, eval, source, a shell reading stdin). Protected: everything under the clone's and the main checkout's
    .agents/team/ except the lead's own files under runs/<run>/ (and its round dirs r<n>/), the clone's
    and the main checkout's .claude/ (the scripts and guards themselves) and any *.jsonl (a stage
    transcript). The owning scripts count only when run from the main checkout's .claude/lib/ — the
    copy the runner and the stage hook run (nothing under costs/: the lead runs no stage command). A redirection target, a `bash -c` string and a path inside a
    word (`open('…/answers.md','w')`) count; a path behind $VAR or a backtick cannot be resolved
    and is refused when it names .agents/team.
Best effort on command text: a path built at run time can pass (team-lead.md §7, limits).
"""
import glob
import json
import os
import re
import shlex
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
           "file", "cut", "shasum", "md5", "test", "[", "realpath", "cd", "pushd", "cmp", "comm",
           "echo", "printf", "true", "false", ":", "basename", "dirname", "readlink", "nl", "od",
           "column", "fold", "paste", "rev", "tac", "tr", "du", "tree", "md5sum", "sha256sum",
           "sha1sum", "fgrep", "zcat", "less", "more"}
# Read-only git subcommands; --output (log/diff/show) writes a file, so it stays refused.
GIT_READS = {"log", "show", "diff", "ls-tree", "status", "rev-parse", "cat-file", "blame", "ls-files",
             "grep", "merge-base", "describe", "shortlog", "name-rev", "for-each-ref", "cherry",
             "whatchanged"}
# Shell keywords that start a command without being one: `do cmp a b`, `if grep -q x f`.
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}", "done", "fi",
            "esac"}
SED_WRITE = re.compile(r"(^|[;{}\s])[wWe](\s+\S|$)|/[gpIiM0-9]*[wWe](\s+\S|$)")
AWK_WRITE = re.compile(r"[>|]|system|getline")
FIND_WRITE = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf",
              "-fls"}
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
    def __init__(self, clone, run, main, trust_clone=False):
        self.clone = os.path.realpath(clone)
        self.teams = [os.path.realpath(os.path.join(d, ".agents", "team"))
                      for d in {clone, main or clone}]
        self.own = os.path.realpath(os.path.join(clone, ".agents", "team", "runs", run))
        # Resolved: a clone may link its .claude/ (or lib/) elsewhere. Both .claude/ trees are
        # protected; the owning scripts run from the main checkout's lib (an older profile that
        # registered the clone's guard: --trust clone, the clone's lib).
        self.claude = [os.path.realpath(os.path.join(d, ".claude")) for d in [clone] + ([main] if main else [])]
        owner = clone if trust_clone or not main else main
        self.lib = os.path.realpath(os.path.join(owner, ".claude", "lib"))

    def protected(self, full):
        if full.endswith(".jsonl") or c.under(full, self.claude):
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


def read_only(w):
    """True when argv <w> only reads its file operands (redirection operands are judged apart)."""
    name = os.path.basename(w[0]) if w else ""
    args = w[1:]
    if name in READERS:
        return True
    if name == "git":
        return args[:1] and args[0] in GIT_READS and not any(
            a.startswith("--output") for a in args)
    if name == "sed":
        opts = [a for a in args if a.startswith("-")]
        if any(a.startswith("--in-place") or (not a.startswith("--") and "i" in a[1:])
               for a in opts):
            return False
        return not any(SED_WRITE.search(a) for a in args if not a.startswith("-"))
    if name in ("awk", "gawk", "nawk"):
        prog = [a for a in args if not a.startswith("-")][:1]
        return "-f" not in args and not any(a.startswith("-i") for a in args) and bool(prog) \
            and not AWK_WRITE.search(prog[0])
    if name == "sort":
        return not any(a == "-o" or a.startswith(("--output", "-o")) for a in args)
    if name == "uniq":
        return len([a for a in args if not a.startswith("-")]) <= 1
    if name == "find":
        return not any(a in FIND_WRITE for a in args)
    if name == "for":
        return True  # `for NAME in …` only binds a name; the body is its own command
    return False


def strip_keywords(words):
    words = list(words)
    while words and words[0] in KEYWORDS:
        words = words[1:]
    return words


def stdin_executor(w):
    """True for a command that takes what it acts on from stdin: xargs, parallel, read, a shell or
    eval/source reading its script from stdin."""
    name = os.path.basename(w[0]) if w else ""
    if name in ("xargs", "parallel", "read", "eval", "source", "."):
        return True
    return name in ("bash", "sh", "zsh") and (len(w) == 1 or "-s" in w[1:])


def input_operands(cmd):
    """Words read through `<` and words written through any `>`-redirection, as canonical() names
    them (normalised paths): an input redirection is a read, the same word also written is not."""
    reads, writes = set(), set()
    try:
        lex = shlex.shlex(c.CONTINUATION.sub("", cmd).replace("\n", " ; "), posix=True,
                          punctuation_chars=True)
        lex.whitespace_split, lex.commenters = True, ""
        toks = list(lex)
    except ValueError:
        return set(), set()
    for op, word in zip(toks, toks[1:]):
        if not (set(op) <= c.PUNCT and re.search("[<>]", op)) or set(word) <= c.PUNCT:
            continue
        norm = os.path.normpath(re.sub("/+", "/", word)) if "/" in word else word
        (reads if op == "<" else writes).add(norm)
    return reads - writes, writes


def check(clone, run, main, cmd, trust_clone=False):
    """→ None when allowed, else the refusal line."""
    try:
        cmds = c.canonical(cmd)
    except c.Refuse as e:
        return "TeamLead Bash: %s" % e
    paths = Paths(clone, run, main, trust_clone)
    # Every directory a `cd` chain can reach is a base, each target joined to every earlier base
    # (`cd a && cd ../team/…`); a target behind $VAR or a backtick cannot be followed at all.
    bases = [paths.clone]
    for w in map(c.argv_plain, cmds):
        if w[:1] in (["cd"], ["pushd"]) and len(w) > 1:
            if re.search(r"[$`]", w[1]):
                return "TeamLead Bash: cd %s cannot be resolved — use paths from the clone root" % w[1]
            bases += [os.path.realpath(os.path.join(b, os.path.expanduser(w[1]))) for b in bases]
    reads, _ = input_operands(cmd)
    relied = False
    for words in cmds:
        w = c.argv_plain(words)
        why = keys_refusal(w) or keys_refusal(c.shell_words(words)) or inbox_refusal(w, clone)
        if why:
            return why
        if not any(paths.hit(x, bases) for x in words):
            continue
        # An input redirection's operand (`wc -l < file`) is read, not written.
        if len(words) == 1 and words[0] in reads:
            continue
        lead = strip_keywords(words)
        w = c.argv_plain(lead) if lead else []
        if not w:
            # Only keywords or assignments (`R=.agents/team/runs/x`): nothing runs, nothing written.
            continue
        name = os.path.basename(w[0])
        prog = w[1] if name in ("bash", "sh", "node") and len(w) > 1 else w[0]
        script = os.path.basename(prog) in SCRIPTS and os.path.realpath(
            os.path.join(paths.clone, prog)) == os.path.join(paths.lib, os.path.basename(prog))
        # One word alone is a redirection operand (`> file`) or the file run as a program.
        if script:
            continue
        # argv_plain drops shell options: `bash -n x.sh` (a syntax check) is read from the raw words.
        raw = c.shell_words(lead)
        syntax = name in ("bash", "sh") and len(raw) > 2 and raw[1] == "-n"
        if syntax or (len(w) > 1 and read_only(w)):
            relied = True
            continue
        return ("TeamLead Bash: %s names a protected file — verdicts, decisions and answers are "
                "written by the scripts, never by the lead" % name)
    # A read that names a protected path must not feed a command taking its targets from stdin.
    # Raw first words too: argv_plain strips wrappers such as xargs.
    feeder = next((w for x in cmds for w in (strip_keywords(x), c.argv_plain(strip_keywords(x)))
                   if stdin_executor(w)), None) if relied else None
    if feeder:
        return ("TeamLead Bash: a protected path read into %s — verdicts, decisions and answers are "
                "written by the scripts, never by the lead" % os.path.basename(feeder[0]))
    return None


def main(argv):
    trust_clone = argv[-2:] == ["--trust", "clone"]
    if trust_clone:
        argv = argv[:-2]
    if len(argv) not in (3, 4):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    why = check(argv[1], argv[2], (argv[3] or None) if len(argv) == 4 else None, sys.stdin.read(),
                trust_clone)
    if why:
        print(why)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
