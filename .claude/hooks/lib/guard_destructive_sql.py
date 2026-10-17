"""Logic of guard-destructive-sql.sh: classify the SQL a Bash command would run (TT-1020, TT-1041).

Verdicts: DROP/TRUNCATE of a table, database or schema -> deny (never by an agent); any other write
(DELETE, UPDATE, INSERT, MERGE, ALTER, CREATE, EXEC, GRANT, SELECT INTO, DROP of smaller objects) -> ask.
Covered inputs: sqlcmd -Q/-q, -i/--input-file, `< file`, `cat file |`, here-docs, scripts run by
bash/sh/zsh/source/./x.sh, and the same forms nested in bash -c / tmux new-session / tmux send-keys.
A command that mentions sqlcmd or a .sql file but cannot be parsed -> ask (fail-closed).
"""
import json
import os
import re
import shlex
import sys

RUNNERS = {"bash", "sh", "zsh", "source", "."}
NESTED = {"bash", "sh", "zsh", "tmux", "env", "nohup", "sudo", "time", "command", "exec"}
SEPARATORS = set(";&|()!\n")
WRAPPERS = {"sudo", "time", "env", "nohup", "command", "exec"}
OBJ = r"[\w\[#@]"

DENY = re.compile(r"\b(drop|truncate)\s+(table|database|schema)\b", re.I)
ASK = re.compile(
    r"\bdelete\s+(top\s*\(\s*\d+\s*\)\s+)?(from\s+)?" + OBJ
    + r"|\bupdate\s+(top\s*\(\s*\d+\s*\)\s+)?" + OBJ
    + r"|\binsert\s+(into\s+)?" + OBJ
    + r"|\bmerge\s+(into\s+)?" + OBJ
    + r"|\b(alter|create)\s+(table|database|schema|index|view|proc|procedure|function|trigger|type"
    r"|synonym|user|login|role|sequence|column)\b"
    + r"|\bdrop\s+(index|view|proc|procedure|function|trigger|type|synonym|user|login|role|sequence"
    r"|column|constraint)\b"
    + r"|\bexec(ute)?\s+" + OBJ
    + r"|\b(grant|revoke|deny)\s+\w"
    + r"|\bselect\b[^;]*?\binto\s+" + OBJ,
    re.I | re.S)
# Shell text outside a sqlcmd call: only the unmistakable forms, same-line whitespace, so test
# fixtures that merely contain the word ("role assignment delete\n...") stay quiet (TT-1034).
SHELL_DENY = re.compile(r"\b(drop|truncate)[ \t]+(table|database|schema)\b", re.I)
SHELL_ASK = re.compile(r"\bdelete[ \t]+(top\s*\(\s*\d+\s*\)[ \t]+)?from[ \t]+" + OBJ, re.I)

# String literals are kept so a `--` inside quotes does not hide the rest of the line.
SQL_PARTS = re.compile(r"'(?:[^']|'')*'|/\*.*?\*/|--[^\n]*", re.S)
MENTIONS_SQL = re.compile(r"sqlcmd|\.sql\b", re.I)


def strip_shell_comments(cmd):
    """Drops `# ...` outside quotes but keeps its newline, so the command separator survives."""
    out, quote, i = [], None, 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < len(cmd):
                out.append(cmd[i:i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "\\" and i + 1 < len(cmd):
            out.append(cmd[i:i + 2])
            i += 2
            continue
        elif c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()"):
            while i < len(cmd) and cmd[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_sql_comments(text):
    return SQL_PARTS.sub(lambda m: m.group(0) if m.group(0).startswith("'") else " ", text)


def tokenize(cmd):
    lex = shlex.shlex(strip_shell_comments(cmd), posix=True, punctuation_chars=";&|()!<\n")
    lex.whitespace = " \t\r"
    lex.commenters = ""
    lex.whitespace_split = True
    return list(lex)


def commands(tokens):
    cur = []
    for t in tokens:
        if t and set(t) <= SEPARATORS | {"<"}:
            if cur:
                yield cur
            cur = [] if t != "<" else cur + ["<"]
        else:
            cur.append(t)
    if cur:
        yield cur


def heredocs(cmd):
    """Bodies of `<<EOF ... EOF` / `<<'EOF'` / `<<-EOF` in the raw command text."""
    bodies = []
    for m in re.finditer(r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n(.*?)^\s*\1\s*$", cmd, re.S | re.M):
        bodies.append(m.group(2))
    return bodies


class Scan:
    def __init__(self, cwd, project):
        self.cwd, self.project = cwd, project
        self.deny, self.ask = [], []

    def resolve(self, f):
        path = os.path.expanduser(f)
        if os.path.isabs(path):
            return path
        for root in (self.cwd, self.project):
            if root and os.path.isfile(os.path.join(root, path)):
                return os.path.join(root, path)
        return ""

    def read(self, f):
        try:
            with open(self.resolve(f), encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except OSError:
            return None

    def sql(self, text, where):
        text = strip_sql_comments(text)
        if DENY.search(text):
            self.deny.append(where)
        elif ASK.search(text):
            self.ask.append(where)

    def shell_text(self, text, where, depth):
        """A script body: classify its sqlcmd calls fully; lines that both call sqlcmd and carry an
        unmistakable statement catch SQL assembled on the same line. Test fixtures under tests/ only
        get the first pass — they print SQL into files, they do not run it."""
        if depth < 3:
            try:
                self.command(text, where, depth + 1)
            except ValueError:
                self.ask.append(where + " (unparsable)")
        if "/tests/" in where:
            return
        for line in text.splitlines():
            if re.match(r"\s*(#|//)", line) or "sqlcmd" not in line:
                continue
            if SHELL_DENY.search(line):
                self.deny.append(where)
                return
            if SHELL_ASK.search(line):
                self.ask.append(where)

    def sqlcmd(self, words, where, cmd):
        i = 1
        while i < len(words):
            w = words[i]
            if w in ("-Q", "-q") and i + 1 < len(words):
                self.sql(words[i + 1], where + " -Q")
                i += 1
            elif w in ("-i", "--input-file", "<") and i + 1 < len(words):
                body = self.read(words[i + 1])
                if body is None:
                    self.ask.append(where + " (unreadable " + words[i + 1] + ")")
                else:
                    self.sql(body, words[i + 1])
                i += 1
            elif w.startswith(("-Q", "-q")) and len(w) > 2:
                self.sql(w[2:], where + " -Q")
            elif w.startswith("-i") and len(w) > 2:
                body = self.read(w[2:])
                self.sql(body, w[2:]) if body is not None else self.ask.append(where)
            i += 1
        for body in heredocs(cmd):
            self.sql(body, where + " <<heredoc")

    def command(self, cmd, where, depth):
        tokens = tokenize(cmd)
        piped_file = None
        for words in commands(tokens):
            while words and (words[0] in WRAPPERS or re.match(r"^\w+=", words[0])):
                words = words[1:]
            if not words:
                continue
            verb = os.path.basename(words[0])
            if verb == "cd" and len(words) > 1:
                self.cwd = os.path.join(self.cwd, os.path.expanduser(words[1]))
            elif verb == "sqlcmd":
                if piped_file:
                    words = words + ["<", piped_file]
                self.sqlcmd(words, where + " sqlcmd", cmd)
            elif verb == "cat" and len(words) > 1 and words[1].endswith(".sql"):
                piped_file = words[1]
                continue
            elif words[0].endswith(".sh") and "/" in words[0]:
                self.script(words[0], depth)
            elif verb in RUNNERS:
                nested = [w for w in words[1:] if w.endswith((".sh", ".sql"))][:1]
                for f in nested:
                    self.script(f, depth)
                if "-c" in words and words.index("-c") + 1 < len(words) and depth < 3:
                    self.command(words[words.index("-c") + 1], where + " " + verb + " -c", depth + 1)
            elif verb == "tmux" and depth < 3:
                for w in words[1:]:
                    if MENTIONS_SQL.search(w):
                        self.command(w, where + " tmux", depth + 1)
            piped_file = None

    def script(self, f, depth):
        body = self.read(f)
        if body is None:
            return
        if f.endswith(".sql"):
            self.sql(body, f)
        else:
            self.shell_text(body, f, depth)


def classify(cmd, cwd, project):
    """Returns (decision, reason) with decision in deny | ask | None."""
    scan = Scan(cwd, project)
    try:
        scan.command(cmd, "command", 0)
    except ValueError:
        if MENTIONS_SQL.search(cmd):
            return "ask", "Destructive-SQL guard could not parse a command that mentions sqlcmd/.sql"
        return None, ""
    if scan.deny:
        return "deny", ("DROP/TRUNCATE of a table, database or schema in: " + ", ".join(scan.deny)
                        + " — never run by an agent; hand the statement to the Operator (TT-1041).")
    if scan.ask:
        return "ask", ("SQL write in: " + ", ".join(scan.ask)
                       + " — Operator must approve this run (ask).")
    return None, ""


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    cmd = (payload.get("tool_input") or {}).get("command") or ""
    cwd = payload.get("cwd") or os.getcwd()
    project = os.environ.get("CLAUDE_PROJECT_DIR", "")
    decision, reason = classify(cmd, cwd, project)
    if decision:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    main()
