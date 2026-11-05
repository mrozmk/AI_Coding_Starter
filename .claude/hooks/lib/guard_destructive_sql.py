"""Logic of guard-destructive-sql.sh: classify the SQL a Bash command would run.

Verdicts: DROP/TRUNCATE of a table, database or schema -> deny (never by an agent); any other write
(DELETE, UPDATE, INSERT, MERGE, ALTER, CREATE, EXEC, GRANT, SELECT INTO, DROP of smaller objects) -> ask.
Covered inputs: sqlcmd -Q/-q/--query, -i/--input-file, `< file`, `cat file |`, here-docs, scripts run by
bash/sh/zsh/source/./x.sh, and the same forms nested in bash -c / tmux new-session / tmux send-keys
/ `$(…)` / backticks. A sqlcmd long option this file does not parse -> ask.
A command that mentions sqlcmd or a .sql file but cannot be parsed -> ask (fail-closed); a script
that cannot be parsed is retried once with the quotes of its documentation heredocs blanked, else
ask.
"""
import json
import os
import re
import shlex
import sys

RUNNERS = {"bash", "sh", "zsh", "source", "."}
SEPARATORS = set(";&|()!\n")
# ---- the one wrapper table both classifiers share (this file and guard_team_egress.py) ----------
# A wrapper runs the command that follows its own options (and, for some, one positional word).
WRAPPERS = {"sudo", "time", "env", "nohup", "command", "exec", "xargs", "nice", "timeout",
            "stdbuf", "flock", "watch", "chrt", "ionice", "caffeinate"}
# commands() splits on `;`/newline, so `do curl …` / `then curl …` start a command with a keyword.
KEYWORDS = {"{", "(", "!", "if", "then", "else", "elif", "do", "while", "until"}
# Wrapper options whose value is a separate word: `env -u NAME curl` must not read NAME as the verb.
# `env -S <string>` is not here: its value IS the command, split and classified like `sh -c`.
OPTION_VALUES = {
    "env": {"-u", "-C"}, "nice": {"-n"}, "timeout": {"-s", "-k"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"},
    "xargs": {"-n", "-P", "-I", "-L", "-s", "-d", "-E", "-a"},
    "stdbuf": {"-i", "-o", "-e"}, "flock": {"-w", "-E"}, "watch": {"-n", "-d"},
    "ionice": {"-c", "-n", "-p"}, "caffeinate": {"-t", "-w"},
}
# Wrappers with one positional word before the command: `flock <file> cmd`, `chrt <prio> cmd`.
POSITIONAL = {"flock", "chrt"}
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
SHELL_C = re.compile(r"^-[a-zA-Z]*c[a-zA-Z]*$")  # -c, -lc, -ec


def strip_wrappers(words):
    """The words from the command a wrapper chain runs: `sudo -u x timeout 5 env A=1 curl …` →
    `curl …`; `env -S "<string>"` and `flock <file> -c "<string>"` split their string; `find …
    -exec <cmd> …` yields <cmd>. ValueError when a string to split is unparsable."""
    while words:
        head = os.path.basename(words[0])
        if words[0] in KEYWORDS:
            words = words[1:]
            continue
        if head == "find":
            ix = next((i for i, w in enumerate(words) if w in FIND_EXEC), None)
            if ix is None:
                break
            words = [w for w in words[ix + 1:] if w not in (";", "+", "{}")]
            continue
        if head not in WRAPPERS and not re.match(r"^\w+=", words[0]):
            break
        takes_value = OPTION_VALUES.get(head, set())
        words = words[1:]
        split = False
        while words and (words[0].startswith("-") or re.match(r"^\w+=", words[0])):
            if head == "env" and words[0].startswith("-S"):
                text = words[0][2:] or " ".join(words[1:2])
                rest = words[1:] if words[0][2:] else words[2:]
                words, split = shlex.split(text) + rest, True
                break
            words = words[2:] if words[0] in takes_value else words[1:]
        if split:
            continue
        if head in POSITIONAL and words:
            words = words[1:]
        if head == "flock" and len(words) > 1 and words[0] in ("-c", "--command"):
            words = shlex.split(words[1]) + words[2:]
        if head == "timeout" and words and re.match(r"^\d", words[0]):
            words = words[1:]
    return words
OBJ = r"[\w\[#@]"

DENY = re.compile(r"\b(drop|truncate)\s+(table|database|schema)\b", re.I)
ASK = re.compile(
    r"\bdelete\s+(top\s*\(\s*\d+\s*\)\s+)?(from\s+)?" + OBJ
    + r"|\bupdate\s+(top\s*\(\s*\d+\s*\)\s+)?" + OBJ
    + r"|\binsert\s+(into\s+)?" + OBJ
    + r"|\bmerge\s+(into\s+)?" + OBJ
    + r"|\b(alter|create)\s+(table|database|schema|index|view|proc|procedure|function|trigger|type"
    r"|synonym|user|login|role|sequence|column)\b"
    + r"|\bcreate\s+(unique\s+)?((?:nonclustered|clustered)\s+)?index\b"
    + r"|\bdrop\s+(index|view|proc|procedure|function|trigger|type|synonym|user|login|role|sequence"
    r"|column|constraint)\b"
    + r"|\bexec(ute)?\s+" + OBJ
    + r"|\b(grant|revoke|deny)\s+\w"
    + r"|\bselect\b[^;]*?\binto\s+" + OBJ,
    re.I | re.S)
# Shell text outside a sqlcmd call: only the unmistakable forms, same-line whitespace, so test
# fixtures that merely contain the word ("role assignment delete\n...") stay quiet.
SHELL_DENY = re.compile(r"\b(drop|truncate)[ \t]+(table|database|schema)\b", re.I)
SHELL_ASK = re.compile(r"\bdelete[ \t]+(top\s*\(\s*\d+\s*\)[ \t]+)?from[ \t]+" + OBJ, re.I)

# String literals are kept so a `--` inside quotes does not hide the rest of the line.
SQL_PARTS = re.compile(r"'(?:[^']|'')*'|/\*.*?\*/|--[^\n]*", re.S)
MENTIONS_SQL = re.compile(r"sqlcmd|\.sql\b", re.I)
SUBST = re.compile(r"\$\(|`|\)")  # same as guard_team_egress.SUBST
DOC_HEREDOC = re.compile(r"<<-?[ \t]*(['\"])(\w+)\1")


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


def _close_paren(text, j):
    """Index of the `)` closing a `$(` whose body starts at j, or -1. The body is a fresh quoting
    context: `"$(sqlcmd -Q "x")"` — the inner quotes do not close the outer string."""
    depth, n = 1, len(text)
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = text.find("'", j + 1)
            if k < 0:
                return -1
            j = k + 1
            continue
        if c == '"':
            k = j + 1
            while k < n and text[k] != '"':
                if text[k] == "\\":
                    k += 2
                    continue
                if text.startswith("$(", k):
                    e = _close_paren(text, k + 2)
                    if e < 0:
                        return -1
                    k = e + 1
                    continue
                k += 1
            if k >= n:
                return -1
            j = k + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def substitutions(text):
    """Bodies of the top-level `$(…)` in shell text, quoting-aware (outside single quotes, also
    inside double quotes). ValueError when one that mentions SQL never closes (caller: ask)."""
    out, i, n, dq = [], 0, len(text), False
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not dq:
            k = text.find("'", i + 1)
            if k < 0:
                break
            i = k + 1
            continue
        if c == '"':
            dq = not dq
        elif text.startswith("$(", i) and not text.startswith("$((", i):
            end = _close_paren(text, i + 2)
            if end < 0:
                if MENTIONS_SQL.search(text[i:]):
                    raise ValueError("unterminated $( around sqlcmd/.sql")
                break
            out.append(text[i + 2:end])
            i = end + 1
            continue
        i += 1
    return out


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


def doc_heredocs_removed(text):
    """Blanks the quotes in the bodies of documentation heredocs: a quoted delimiter (the body is
    never expanded), a bare `cat` before `<<` with nothing after the delimiter, and no SQL mention
    in that line or the body. An apostrophe in such a body breaks shlex. The lines stay, so a body
    that runs after all (`<(cat <<'X'`) is still scanned; every other heredoc is left as is."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        m = DOC_HEREDOC.search(line)
        if (not m or line[m.end():].strip()
                or re.split(r"[;&|(]", line[:m.start()])[-1].split() != ["cat"]):
            continue
        end = next((j for j in range(i, len(lines)) if lines[j].strip() == m.group(2)), None)
        if end is None or any(MENTIONS_SQL.search(x) for x in lines[i - 1:end]):
            continue
        out.extend(re.sub(r"[\"'`]", " ", x) for x in lines[i:end])
        i = end
    return "\n".join(out)


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
                try:
                    self.command(doc_heredocs_removed(text), where, depth + 1)
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
            if w in ("-Q", "-q", "--query") and i + 1 < len(words):
                self.sql(words[i + 1], where + " -Q")
                i += 1
            elif w.startswith("--query="):
                self.sql(w[len("--query="):], where + " -Q")
            elif w.startswith("--input-file="):
                f = w[len("--input-file="):]
                body = self.read(f)
                self.sql(body, f) if body is not None else self.ask.append(where + " (unreadable " + f + ")")
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
            elif w.startswith("--"):
                # A long option this parser does not know may carry the statement: ask, never allow.
                self.ask.append(where + " (unparsed option " + w.split("=", 1)[0] + ")")
            i += 1
        for body in heredocs(cmd):
            self.sql(body, where + " <<heredoc")

    def command(self, cmd, where, depth):
        if depth < 3:
            # Before tokenizing: shlex reads `"$(sqlcmd -Q "x")"` as two strings and splits x.
            for body in substitutions(strip_shell_comments(cmd)):
                if MENTIONS_SQL.search(body):
                    self.command(body, where + " subst", depth + 1)
        tokens = tokenize(cmd)
        piped_file = None
        for raw in commands(tokens):
            words = strip_wrappers(raw)
            if depth < 3:
                # `$(…)`/backticks inside a quoted word or glued to it: scan the substituted text.
                for k, w in enumerate(raw):
                    # `$(…)` is read from the raw text above; backticks only here.
                    if "`" in w and MENTIONS_SQL.search(w):
                        self.command(SUBST.sub(" ; ", w), where + " subst", depth + 1)
                    if "`" in w:
                        # An unquoted backtick spans words: `echo `sqlcmd -Q "…"`` runs the tail.
                        tail = shlex.join([w.split("`", 1)[1]] + raw[k + 1:])
                        if MENTIONS_SQL.search(tail):
                            self.command(tail, where + " subst", depth + 1)
            if not words:
                continue
            verb = os.path.basename(words[0].lstrip("`"))
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
                flag = next((i for i, w in enumerate(words[1:-1], 1) if SHELL_C.match(w)), 0)
                if flag and depth < 3:
                    self.command(words[flag + 1], where + " " + verb + " " + words[flag], depth + 1)
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
                        + " — never run by an agent; hand the statement to the Operator.")
    if scan.ask:
        return "ask", ("SQL write in: " + ", ".join(scan.ask)
                       + " — Operator must approve this run (ask).")
    return None, ""


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except (ValueError, AttributeError):
        # Fail closed: rc 2 tells the hook wrapper the payload itself was unreadable.
        print("guard-destructive-sql: unreadable hook payload", file=sys.stderr)
        sys.exit(2)
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
