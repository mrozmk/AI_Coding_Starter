"""#323: the Supervisor clearance checker — one decider for both carriers (team-clearance-hook.sh, the
role-profile PermissionRequest hook; team-ask-hook.sh through team_prompt_check's `clearance:` line).

clear_class(tool, tool_input, cwd, project, ctx, main, rules_file) -> {result, class_id, reason, pins,
dest}, result one of
  hard       never passed or cleared: a classifier deny/operator kind, a human-only or never-waived
             tier cause, a write to a protected path (settings, role profiles, .claude/hooks/**,
             .codex/hooks.json, the clearance and team ledgers, the main checkout's trusted clearance
             code), a reserved gh operation, a deny or ask rule of the session, an unevaluable rule,
             any error;
  pass       a mechanical allow: Bash whose classifier kind is pass and whose every simple command
             (literal loops unrolled) is an egress read (gh read forms, npm view|ls, pip list|show,
             git fetch|ls-remote into remote-tracking refs, the curl public GET without -o) or a
             companion that writes nothing, with no redirection but /dev/null and fd duplication;
             or a WebFetch the classifier passes. A pass from no egress at all is no pass (none);
  clearable  exactly one class of clearance-classes.json: public-get-long, lockfile-install,
             gh-own-repo-write, starter-worktree-edit (a stage's), inline-code-no-io — the classifier
             kind must be ask (a file edit for the worktree class);
  none       everything else: Claude Code's normal path decides. Also "no decision": a launch rule
             digest that differs, a missing launch profile, a PreToolUse hook whose ask this checker
             does not reproduce (#323 R2-8, R3-1).
Order hard > pass > clearable > none; fails closed (an exception -> hard). The DNS resolver is the
classifier's: nothing here reads a resolver setting (the tests swap it through
fixtures/clearance/drive.py). CLI: classify | digest | rules-digest (see main()).
Contract: .agents/reference/security-egress.md -> Supervisor clearance (#323).
"""
import ast
import fnmatch
import glob as globmod
import hashlib
import json
import os
import re
import sys
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib"))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

import guard_team_egress as g  # noqa: E402
import guard_team_egress_classify as cl  # noqa: E402
import guard_team_egress_effect as ef  # noqa: E402
import guard_team_egress_hard as hd  # noqa: E402
import guard_team_egress_loops as lp  # noqa: E402
import guard_team_egress_supervisor as sv  # noqa: E402
import guard_team_egress_words as wd  # noqa: E402

CLASSES = os.path.join(HERE, "clearance-classes.json")
FILE_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
TOOLS = ("Bash", "WebFetch") + FILE_TOOLS
MANAGED = "/Library/Application Support/ClaudeCode/managed-settings.json"
LEDGER = re.compile(r"/\.agents/team/(?:clearance|relays|delegated|mandate\.json)(?:$|[./-])"
                    r"|/\.agents/team/runs/[^/]+/(?:r[0-9]+/)?(?:asks|decisions)(?:$|/)")
# `>` / `>>` to a word, or a duplication `>&N`: only /dev/null and an fd number are writes-nothing.
REDIR = re.compile(r">>?([ \t]*)(&?)([^\s;&|<>()]*)")
GH_URL = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?:issues|pull)/[0-9]+/?$")
REMOTE = re.compile(r"github\.com[:/]+([^/\s]+/[^/\s]+?)(?:\.git)?/?$")
HOOK_CMD = re.compile(r'^(?:[A-Z_][A-Z0-9_]*=\S*\s+)*bash\s+"?([^"\s]+)"?(?:\s+[A-Z]+)?$')
# gh write kinds: (value options, bool options, positional count). -R/--repo is read apart.
GH_SPEC = {
    ("issue", "comment"): ({"-b", "--body", "-F", "--body-file"}, {"--edit-last"}, 1),
    ("issue", "create"): ({"-t", "--title", "-b", "--body", "-F", "--body-file", "-l", "--label",
                           "-a", "--assignee", "-m", "--milestone"}, set(), 0),
    ("issue", "edit"): ({"-t", "--title", "-b", "--body", "-F", "--body-file", "--add-label",
                         "--remove-label", "--add-assignee", "--remove-assignee", "-m", "--milestone"}, set(), 1),
    ("issue", "close"): ({"-c", "--comment", "-r", "--reason"}, set(), 1),
    ("issue", "reopen"): ({"-c", "--comment"}, set(), 1),
    ("pr", "comment"): ({"-b", "--body", "-F", "--body-file"}, {"--edit-last"}, 1),
    ("pr", "create"): ({"-t", "--title", "-b", "--body", "-F", "--body-file", "-B", "--base", "-H", "--head",
                        "-l", "--label", "-a", "--assignee", "-r", "--reviewer", "-m", "--milestone"},
                       {"-d", "--draft", "-f", "--fill"}, 0),
    ("project", "item-add"): ({"--owner", "--url"}, set(), 1),
    ("label", "create"): ({"-c", "--color", "-d", "--description"}, {"-f", "--force"}, 1),
}


class Hard(Exception):
    """A request that is never passed or cleared."""


class NoDecision(Exception):
    """The checker may not decide this session's request: Claude Code's normal path does."""


def load_classes():
    with open(CLASSES, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or not isinstance(data.get("version"), int):
        raise Hard("clearance-classes.json unreadable")
    return data


def _json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _checker():
    """team_prompt_check (the tier's module `c`) from this checkout's .claude/lib."""
    if LIB not in sys.path:
        sys.path.insert(0, LIB)
    import team_prompt_check
    return team_prompt_check


def _classes_lib():
    if LIB not in sys.path:
        sys.path.insert(0, LIB)
    import team_prompt_classes
    return team_prompt_classes


# --- the list version: version + the policy digest of the trusted clearance code -----------------

def _local_dep(main, name, near):
    for d in (near, ".claude/hooks/lib", ".claude/lib"):
        rel = os.path.normpath(os.path.join(d, name))
        if os.path.isfile(os.path.join(main, rel)):
            return rel
    return None


def deps_of(main, rel):
    """The .claude/ modules one trusted file loads: Python imports of a local module, shell
    `.`/source lines of a sibling library."""
    full, near, out = os.path.join(main, rel), os.path.dirname(rel), []
    try:
        with open(full, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, ValueError):
        return out
    if rel.endswith(".py"):
        for node in ast.walk(ast.parse(text)):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else \
                [node.module] if isinstance(node, ast.ImportFrom) and node.module and not node.level else []
            for n in names:
                dep = _local_dep(main, n.split(".")[0] + ".py", near)
                if dep:
                    out.append(dep)
    elif rel.endswith(".sh"):
        for m in re.finditer(r'(?m)^\s*(?:\.|source)\s+"?[^"\n]*/([A-Za-z0-9_.-]+\.sh)"?', text):
            dep = _local_dep(main, m.group(1), near)
            if dep:
                out.append(dep)
    return out


def closure_missing(main, listed):
    """Members of the load closure of the listed files that the list leaves out (#323 R1-6)."""
    seen, todo, missing = set(listed), list(listed), []
    while todo:
        for dep in deps_of(main, todo.pop()):
            if dep not in seen:
                seen.add(dep)
                missing.append(dep)
                todo.append(dep)
    return sorted(missing)


def policy_digest(main, classes=None):
    """sha256 over the bytes of every trusted_code file of <main>, in list order (a missing file is
    the literal `missing:<path>`); raises Hard when the load closure names an unlisted module."""
    k = classes or load_classes()
    listed = [p for p in k.get("trusted_code") or [] if isinstance(p, str)]
    if not listed:
        raise Hard("no trusted_code list")
    gap = closure_missing(main, listed)
    if gap:
        raise Hard("trusted_code misses " + ", ".join(gap))
    h = hashlib.sha256()
    for rel in listed:
        h.update(rel.encode() + b"\0")
        try:
            with open(os.path.join(main, rel), "rb") as fh:
                h.update(fh.read())
        except OSError:
            h.update(b"missing:" + rel.encode())
        h.update(b"\0")
    return h.hexdigest()


def list_version(main, classes=None):
    k = classes or load_classes()
    return "%d-%s" % (k["version"], policy_digest(main, k)[:16])


# --- the session's rules and hooks (R1-5, R2-2, R2-8, R3-1, R3-2) --------------------------------

def user_config_dir(main):
    """The session's Claude config dir as team_claude_home resolves it: the checkout's declared
    profile (.claude/claude-profile, first line that is neither blank nor a comment), else
    $CLAUDE_CONFIG_DIR, else ~/.claude."""
    try:
        with open(os.path.join(main, ".claude", "claude-profile"), encoding="utf-8") as fh:
            first = next((ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")), "")
        if first:
            return os.path.realpath(os.path.expanduser(first))
    except OSError:
        pass
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def rule_sources(project, rules_file, main=None):
    cfg = user_config_dir(main or project)
    out = [("profile", rules_file)] if rules_file else []
    return out + [("project", os.path.join(project, ".claude", "settings.json")),
                  ("local", os.path.join(project, ".claude", "settings.local.json")),
                  ("user", os.path.join(cfg, "settings.json")), ("managed", MANAGED)]


def load_sources(project, rules_file, main=None):
    """[(name, settings)] of every rule source that exists. A missing launch profile is no decision;
    a source that exists but does not read is hard."""
    out = []
    for name, path in rule_sources(project, rules_file, main):
        if name == "profile" and not os.path.isfile(path):
            raise NoDecision("the launch profile %s is missing" % path)
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            raise Hard("%s settings unreadable" % name)
        if not isinstance(data, dict):
            raise Hard("%s settings unreadable" % name)
        out.append((name, data))
    return out


def rules_of(sources):
    deny, ask = [], []
    for name, data in sources:
        perms = data.get("permissions") or {}
        if not isinstance(perms, dict):
            raise Hard("%s permissions unreadable" % name)
        for tier, acc in (("deny", deny), ("ask", ask)):
            v = perms.get(tier) or []
            if not isinstance(v, list):
                raise Hard("%s %s rules unreadable" % (name, tier))
            acc.extend(r for r in v if isinstance(r, str))
    return deny, ask


def rules_digest(sources):
    deny, ask = rules_of(sources)
    blob = json.dumps({"deny": sorted(set(deny)), "ask": sorted(set(ask))}, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()


def matcher_hits(m, tool):
    """Claude Code's matcher: empty or * matches all, else a name list or a regex (unanchored; an
    invalid regex counts as matching)."""
    if not isinstance(m, str) or m.strip() in ("", "*"):
        return True
    if tool in [p.strip() for p in re.split(r"[|,]", m)]:
        return True
    try:
        return re.search(m, tool) is not None
    except re.error:
        return True


def foreign_hook(sources, tool, known):
    """The first PreToolUse hook matching <tool> whose ask this checker does not reproduce, or None."""
    for name, data in sources:
        hooks = data.get("hooks") or {}
        pre = hooks.get("PreToolUse") or [] if isinstance(hooks, dict) else None
        if not isinstance(pre, list):
            return "%s hooks unreadable" % name
        for ent in pre:
            if not isinstance(ent, dict):
                return "%s hooks unreadable" % name
            if not matcher_hits(ent.get("matcher"), tool):
                continue
            for h in ent.get("hooks") or []:
                cmd = h.get("command") if isinstance(h, dict) and (h.get("type") or "command") == "command" else None
                m = HOOK_CMD.match(cmd.strip()) if isinstance(cmd, str) else None
                if not (m and "/.claude/hooks/" in m.group(1) and os.path.basename(m.group(1)) in known):
                    return "%s hook %s" % (name, (cmd or "?")[:120] if isinstance(cmd, str) else "?")
    return None


def path_rule_hit(pat, target, project):
    """A file rule's gitignore-style pattern against the resolved target (case-folded; `*` crosses
    `/`, erring toward the rule)."""
    low = target.lower()
    if pat.startswith("//"):
        full = pat[1:]
    elif pat.startswith("~/"):
        full = os.path.expanduser(pat)
    elif pat.startswith("/"):
        full = os.path.join(os.path.realpath(project), pat[1:])
    else:
        rel = os.path.relpath(target, os.path.realpath(project)).lower()
        p = pat[2:] if pat.startswith("./") else pat
        return (fnmatch.fnmatchcase(rel, p.lower()) or fnmatch.fnmatchcase(low, "*/" + p.lower().lstrip("*/"))
                or fnmatch.fnmatchcase(low, "*/" + p.lower()))
    return fnmatch.fnmatchcase(low, full.lower()) or low.startswith(full.lower().rstrip("*").rstrip("/") + "/")


def rule_hit(rule, tool, inp, target, project, c):
    """True when <rule> covers this call; Hard when it is relevant and cannot be evaluated."""
    name, paren, arg = rule.partition("(")
    family = FILE_TOOLS if tool in FILE_TOOLS else (tool,)
    if name not in family:
        return False
    if not paren:
        return True
    if not arg.endswith(")"):
        raise Hard("rule %s cannot be evaluated" % rule)
    arg = arg[:-1]
    if tool == "Bash":
        pat = arg[:-2] + "*" if arg.endswith(":*") else arg
        try:
            return bool(c.matches(inp.get("command") or "", [("rule", rule, pat)], True))
        except c.Refuse:
            raise Hard("rule %s cannot be evaluated on this command" % rule)
    if tool == "WebFetch":
        if not arg.startswith("domain:"):
            raise Hard("WebFetch rule %s cannot be evaluated" % rule)
        d, host = arg[7:].strip().lower().rstrip("."), (urlsplit(str(inp.get("url") or "")).hostname or "").lower()
        if d.startswith("*.") and "*" not in d[2:]:
            return host.endswith(d[1:])
        if "*" in d or not d:
            raise Hard("WebFetch rule %s cannot be evaluated" % rule)
        return host.rstrip(".") == d
    if target is None:
        raise Hard("rule %s: the target cannot be resolved" % rule)
    return path_rule_hit(arg, target, project)


# --- protected writes (R1-4, R3-5) ---------------------------------------------------------------

def protected(path, project, main, k):
    """Why a resolved write target is protected, or ''."""
    if not path:
        return ""
    low = os.path.realpath(path).lower()
    if hd.guard_layer(os.path.realpath(path), project):
        return "settings or a role profile"
    if fnmatch.fnmatchcase(low, "*/.claude/hooks/*") or low.endswith("/.claude/hooks"):
        return ".claude/hooks"
    if low.endswith("/.codex/hooks.json"):
        return ".codex/hooks.json"
    if LEDGER.search(low):
        return "a team ledger (clearance, relays, delegations, asks)"
    for rel in k.get("trusted_code") or []:
        if os.path.realpath(os.path.join(main, rel)).lower() == low:
            return "trusted clearance code (%s)" % rel
    return ""


def unresolved_protected(target):
    low = target.lower()
    base = os.path.basename(low)
    return (fnmatch.fnmatchcase(base, "settings*.json") or base.endswith(".settings.json") or base == "hooks.json"
            or "/.claude/hooks/" in "/" + low or ".agents/team/clearance" in low or base.startswith("clearance"))


def bash_targets(cmd, project, cwd):
    """[(target, cwd | None)] of every write a Bash command names (the classifier's readers)."""
    base = cwd or project
    cmd = ef.inline_literals(cmd)
    out = []
    top = hd.segment_cwds(cmd, base)
    for raw, words, seg_cwd in top:
        out += [(t, seg_cwd) for t in wd.redirect_targets(raw) + wd.word_targets(words)]
        out += [(t, seg_cwd) for t in py_targets(words)]
    here = None if re.search(r"(?:^|[\s;&|(])(?:cd|pushd|popd)\s", cmd) else base
    seen = [r for r, _, _ in top]
    for raw, words in wd.units(cmd):
        if raw not in seen:
            out += [(t, here) for t in wd.redirect_targets(raw) + wd.word_targets(words) + py_targets(words)]
    for line_no, line in enumerate(cmd.split("\n")):
        m = ef.PY_DOC.search(line)
        if m:
            lines = cmd.split("\n")
            end = next((i for i in range(line_no + 1, len(lines)) if lines[i] == m.group(4)), None)
            if end is not None:
                out += [(t, here) for t in wd.py_write_targets("\n".join(lines[line_no + 1:end]), [])]
    return out


def py_targets(words):
    if not words or os.path.basename(words[0]) not in ("python3", "python"):
        return []
    j = ef.py_flags(words)
    if words[j:j + 1] != ["-c"] or len(words) < j + 2:
        return []
    return wd.py_write_targets(words[j + 1], words[j + 2:])


def file_target(inp, cwd):
    t = inp.get("file_path") or inp.get("notebook_path")
    if not isinstance(t, str) or not t:
        return None
    return os.path.realpath(os.path.join(cwd, os.path.expanduser(t)))


def reserved_gh(cmd, k):
    """The reserved gh operation a Bash command runs anywhere (R1-1), or ''."""
    reserved = [r.split() for r in k.get("reserved_gh") or []]
    for _, words in wd.units(cmd):
        if words and os.path.basename(words[0]) == "gh":
            for r in reserved:
                if words[1:1 + len(r)] == r:
                    return "gh " + " ".join(r)
    return ""


# --- pass ----------------------------------------------------------------------------------------

def redirections_ok(text):
    for m in REDIR.finditer(wd.ops_masked(text)):
        if m.group(2) == "&" and m.group(3).isdigit():
            continue
        if not m.group(2) and m.group(3) == "/dev/null":
            continue
        return False
    return True


def git_net_read(vals):
    """git fetch|ls-remote (only -C before it) into remote-tracking refs: no `-u`, no destination
    outside refs/remotes/ (R3-3)."""
    i = 1
    while i < len(vals) and vals[i].startswith("-"):
        if vals[i] != "-C" or i + 1 >= len(vals):
            return False
        i += 2
    if vals[i:i + 1] not in (["fetch"], ["ls-remote"]):
        return False
    for a in vals[i + 1:]:
        if a in ("-u", "--update-head-ok") or re.match(r"^-[A-Za-z]*u", a) and not a.startswith("--"):
            return False
        if ":" in a and "://" not in a and not a.startswith("-"):
            if not a.split(":", 1)[1].startswith("refs/remotes/"):
                return False
    return True


def read_form(vals, seg, project):
    head = vals[0] if vals else ""
    if head == "gh":
        return (tuple(vals[1:3]) in ef.GH_READ_FORMS or ef.gh_api_read(vals)) and sv.gh_covered(seg, vals, [])
    if head in ("npm", "pip", "pip3"):
        return vals[1:2] in (["view"], ["ls"], ["list"], ["show"]) and cl.net_read(vals, project)
    if head == "curl":
        return "-o" not in vals[1:] and cl.curl_get_ok(vals, project)
    if head == "git":
        return git_net_read(vals)
    return False


def quiet(vals, seg, allowed=None):
    """The one read-only argument predicate (R2-5): an allowlisted companion that writes nothing."""
    head = vals[0] if vals else ""
    if head == "tee" or (allowed is not None and head not in allowed):
        return False
    if head == "sort" and any(a.startswith("-") and not a.startswith("--") and "o" in a[1:] for a in vals[1:]):
        return False
    if head == "uniq" and len(wd.positional(vals[1:])) > 1:
        return False
    return lp.companion_safe(vals, g.egress_in, seg)


def egress_read_pass(text, project, depth=0):
    bodies = lp.for_bodies(text, wd.LOOP_WORD)
    if bodies is not None:
        return depth < 2 and 0 < len(bodies) <= lp.FOR_MAX and all(
            egress_read_pass(b, project, depth + 1) for b in bodies)
    if not redirections_ok(text):
        return False
    segs = sv.plain_segments(text)
    if not segs:
        return False
    reads = 0
    for seg in segs:
        vals = [w.value for w in seg]
        if any(kind == "g" for w in seg for kind, _ in w.parts):
            return False
        if read_form(vals, seg, project):
            reads += 1
        elif not quiet(vals, seg):
            return False
    return reads > 0


# --- the class detectors -------------------------------------------------------------------------

def digest(path):
    a = _checker().team_prompt_authority
    return a.path_digest(path)


def git_blob_equal(path):
    """True when <path> is tracked and its bytes equal HEAD's blob in its own repository, read
    through the hardened git reader (no filters, hooks or replace refs; R2-3)."""
    tpc = _classes_lib()
    d = os.path.dirname(os.path.realpath(path))
    top = tpc.git(d, "rev-parse", "--show-toplevel")
    if not top:
        return False
    top = top.strip()
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(top))
    blob = tpc.git(top, "cat-file", "blob", "HEAD:" + rel, raw=True)
    try:
        with open(path, "rb") as fh:
            return blob is not None and fh.read() == blob
    except OSError:
        return False


def one_segment(cmd):
    if lp.for_bodies(cmd, wd.LOOP_WORD) is not None or not redirections_ok(cmd):
        return None
    segs = sv.plain_segments(cmd)
    if not segs or len(segs) != 1 or any(kind == "g" for w in segs[0] for kind, _ in w.parts):
        return None
    return segs[0]


def url_long_ok(url, project, k):
    """Every #322 public-GET condition but the query ban and the 160-character cap; the address
    check runs for an allowlisted host too (R3-7)."""
    if not isinstance(url, str) or len(url) > int(k.get("url_cap") or 0) or "\\" in url \
            or re.search(r"[\s\x00-\x1f\x7f]", url) or cl.TOKEN.search(url):
        return False
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").rstrip(".").lower()
    except ValueError:
        return False
    return (parts.scheme.lower() == "https" and "@" not in parts.netloc and bool(host)
            and not cl.private_host(host) and cl.public_name(host) and cl.public_addresses(host))


def public_get_long(tool, inp, cwd, project, k):
    if tool == "WebFetch":
        url = inp.get("url")
        return ("clearable", [], (urlsplit(url).hostname or "").lower()) if url_long_ok(url, project, k) else None
    cmd = inp.get("command") or ""
    if lp.for_bodies(cmd, wd.LOOP_WORD) is not None or not redirections_ok(cmd):
        return None
    segs = sv.plain_segments(cmd)
    if not segs or any(s.op != "|" for s in segs[:-1]) or segs[-1].op not in ("end", "\n"):
        return None
    vals = [w.value for w in segs[0]]
    if vals[:1] != ["curl"]:
        return None
    # An unquoted `?` of a query is a glob to the shell: accepted only in a URL word that matches
    # no path from the cwd (the shell then passes it literally).
    for w in segs[0]:
        globs = [t for kind, t in w.parts if kind == "g"]
        if globs and (set(globs) != {"?"} or "://" not in w.value
                      or globmod.glob(os.path.join(cwd, w.value.replace("[", "[[]")))):
            return None
    urls, outs, i = [], [], 1
    while i < len(vals):
        a = vals[i]
        if re.fullmatch(r"-[sSf]+", a):
            i += 1
        elif a == "-o" and i + 1 < len(vals) and wd.plain_output(vals[i + 1]):
            outs.append(vals[i + 1])
            i += 2
        elif a.startswith("-"):
            return None
        else:
            urls.append(a)
            i += 1
    if len(urls) != 1 or len(outs) > 1 or re.search(r"[{}\[\]]", urls[0]) or cl.curl_config_present() \
            or not url_long_ok(urls[0], project, k):
        return None
    for seg in segs[1:]:
        if not quiet([w.value for w in seg], seg, set(k.get("filters") or [])):
            return None
    pins = [digest(hd.resolve(outs[0], cwd))] if outs else []
    return "clearable", pins, (urlsplit(urls[0]).hostname or "").lower()


def lockfile_install(tool, inp, cwd, project, k):
    if tool != "Bash":
        return None
    seg = one_segment(inp.get("command") or "")
    if seg is None:
        return None
    vals = [w.value for w in seg]
    verb, args = hd.pip_form(vals[0], vals[1:])
    if verb not in ("npm", "pip", "pip3"):
        return None
    if any(cl.REGISTRY_OPTS.match(a) for a in args):
        return "hard", "an install with a registry, index, proxy or config option"
    if verb == "npm":
        rest, prefix = list(args), None
        for i, a in enumerate(rest):
            if a.startswith("--prefix="):
                prefix, rest = a.split("=", 1)[1], rest[:i] + rest[i + 1:]
                break
            if a == "--prefix" and i + 1 < len(rest):
                prefix, rest = rest[i + 1], rest[:i] + rest[i + 2:]
                break
        if not any(sorted(rest) == sorted(f) for f in k.get("npm_forms") or []):
            return None
        d = hd.resolve(prefix or ".", cwd)
        if not d or not os.path.isdir(d) or os.path.exists(os.path.join(d, ".npmrc")):
            return None
        lock = next((os.path.join(d, n) for n in k.get("lockfiles") or [] if os.path.isfile(os.path.join(d, n))), None)
        pkg = os.path.join(d, "package.json")
        if not lock or not os.path.isfile(pkg) or not git_blob_equal(lock):
            return None
        return "clearable", [digest(pkg)] + [digest(os.path.join(d, n)) for n in k.get("lockfiles") or []], \
            "npm registry (lockfile %s)" % lock
    if args[:1] != ["install"]:
        return None
    rest, req = list(args[1:]), None
    for i, a in enumerate(rest):
        if a in ("-r", "--requirement") and i + 1 < len(rest):
            req, rest = rest[i + 1], rest[:i] + rest[i + 2:]
            break
    if req is None or sorted(rest) != sorted((k.get("pip_form") or [])[1:]):
        return None
    f = hd.resolve(req, cwd)
    if not f or not os.path.isfile(f) or not git_blob_equal(f):
        return None
    try:
        with open(f, encoding="utf-8") as fh:
            lines = fh.read().replace("\\\n", " ").splitlines()
    except (OSError, ValueError):
        return None
    bad = [re.compile(p) for p in k.get("pip_bad_lines") or []]
    for line in lines:
        body = line.split(" #", 1)[0] if not line.lstrip().startswith("#") else ""
        if body.strip() and any(p.search(body) for p in bad):
            return None
    return "clearable", [digest(f)], "pip index (hash-pinned %s)" % f


def gh_config(main):
    prof = _json(os.path.join(main, ".claude", "project-profile.json"))
    for block in ((prof.get("teams") or {}).get("github") if isinstance(prof.get("teams"), dict) else None,
                  prof.get("github")):
        if isinstance(block, dict) and block.get("repo"):
            return block
    return {}


def cwd_repo_own(cwd, own):
    """Every remote of the cwd's repository resolves to the own repo (gh's default repo there)."""
    out = _classes_lib().git(cwd, "remote", "-v")
    urls = [ln.split()[1] for ln in (out or "").splitlines() if len(ln.split()) >= 2]
    if not urls:
        return False
    for u in urls:
        m = REMOTE.search(u)
        if not m or m.group(1).lower() != own:
            return False
    return True


def gh_own_repo_write(tool, inp, cwd, project, k, main):
    if tool != "Bash" or os.environ.get("GH_REPO") or os.environ.get("GH_HOST"):
        return None
    seg = one_segment(inp.get("command") or "")
    if seg is None:
        return None
    vals = [w.value for w in seg]
    kind = tuple(vals[1:3])
    if vals[:1] != ["gh"] or [list(kind)] not in [[list(x)] for x in k.get("gh_kinds") or []] or kind not in GH_SPEC:
        return None
    vopts, bopts, npos = GH_SPEC[kind]
    if kind[0] != "project":
        vopts = vopts | {"-R", "--repo"}
    opts, pos, i = {}, [], 3
    while i < len(vals):
        a = vals[i]
        if a == "--":
            pos += vals[i + 1:]
            break
        name, eq, val = a.partition("=") if a.startswith("--") else (a, "", "")
        if a.startswith("-") and a != "-":
            if name in vopts and eq:
                opts.setdefault(name, []).append(val)
                i += 1
            elif a in vopts and i + 1 < len(vals):
                opts.setdefault(a, []).append(vals[i + 1])
                i += 2
            elif a in bopts:
                i += 1
            else:
                return None  # --attach, --input or any unmodelled option (R2-4)
            continue
        pos.append(a)
        i += 1
    if len(pos) != npos:
        return None
    own = hd.own_repo(main)
    if not own:
        return None
    if kind == ("project", "item-add"):
        cfg = gh_config(main)
        url = (opts.get("--url") or [""])[-1]
        m = GH_URL.match(url)
        if not (cfg.get("project_owner") and str(cfg.get("project_number") or "") == pos[0]
                and (opts.get("--owner") or [""])[-1] == cfg.get("project_owner") and m and m.group(1).lower() == own):
            return None
        return "clearable", [], "%s project %s (%s)" % (cfg["project_owner"], pos[0], own)
    repos = (opts.get("-R") or []) + (opts.get("--repo") or [])
    if repos:
        if any(not sv.GH_PLAIN_REPO.match(r) or r.lower() != own for r in repos):
            return None
    for p in pos:
        if "://" in p:
            m = GH_URL.match(p)
            if not m or m.group(1).lower() != own:
                return None
            repos.append(m.group(1))
        elif kind[0] in ("issue", "pr") and not re.fullmatch(r"[0-9]+", p):
            return None
    if not repos and not cwd_repo_own(cwd, own):
        return None
    if any(":" in h for h in opts.get("-H", []) + opts.get("--head", [])):
        return None
    pins = []
    for f in opts.get("-F", []) + opts.get("--body-file", []):
        full = hd.resolve(f, cwd) if f != "-" else None
        if not full or not os.path.isfile(full):
            return None
        pins.append(digest(full))
    return "clearable", pins, own


def starter_binding(project, main, target):
    """'' when <target> lies in the stage's own registered starter worktree; 'named' when it lies in
    a directory merely named like a starter worktree; 'other' otherwise (#323 R1-3)."""
    st = (_json(os.path.join(main, ".claude", "project-profile.json")).get("teams") or {})
    root = st.get("starter_root") if isinstance(st, dict) else None
    if not isinstance(root, str) or not root:
        return "other"
    starter = os.path.realpath(os.path.join(main, root))
    low = target.lower()
    parent, stem = os.path.dirname(starter).lower(), os.path.basename(starter).lower() + "-"
    rel = low[len(parent) + 1:] if low.startswith(parent + os.sep) else ""
    if not rel or not rel.split(os.sep, 1)[0].startswith(stem):
        return "other"
    tpc = _classes_lib()
    team = tpc.anchor_team(project, main)
    a = _json(os.path.join(main, ".agents", "team", "anchors", team + ".json")) if team else {}
    s = _json(os.path.join(project, ".agents", "team", "session.json"))
    try:
        with open(os.path.join(project, ".agents", "team", "run"), encoding="utf-8") as fh:
            run = fh.read().strip()
    except OSError:
        run = ""
    if (not a or a.get("mismatch") or s.get("team") != team or not run or a.get("run") != run
            or any(str(a.get(f)) != str(s.get(f)) for f in ("ticket", "run", "session_id", "attempt"))
            or not s.get("session_id")):
        return "named"
    want = starter + "-" + str(team) + "-" + str(s.get("ticket"))
    listed = tpc.git(starter, "worktree", "list", "--porcelain")
    paths = {os.path.realpath(ln[len("worktree "):]) for ln in (listed or "").splitlines() if ln.startswith("worktree ")}
    if os.path.realpath(want) not in paths or os.path.realpath(want) == starter:
        return "named"
    return "" if hd.inside(low, want) else "named"


def starter_worktree_edit(tool, inp, cwd, project, k, main, ctx, rest):
    if tool not in FILE_TOOLS or ctx != "stage":
        return None
    target = file_target(inp, cwd)
    if not target or not rest or rest[0] != "operator" or not str(rest[1]).startswith("refuse (outside clone)"):
        return None
    where = starter_binding(project, main, target)
    if where:
        return None if where == "named" else ("hard", str(rest[1]))
    return "clearable", [digest(target)], target


def code_of(cmd):
    """(code, shell_text) of a `python3 -I -c '<literal>'` or a quoted-delimiter `python3 -I -`
    here-doc that is the whole command; None for any other shape or without -I (R3-6)."""
    lines = cmd.split("\n")
    m = ef.PY_DOC.match(lines[0])
    if m and m.end() == len(lines[0].rstrip()) and not m.group(5).strip():
        end = next((i for i in range(1, len(lines)) if lines[i] == m.group(4)), None)
        if end is None or any(l.strip() for l in lines[end + 1:]) or "I" not in m.group(1):
            return None
        return "\n".join(lines[1:end]), False
    seg = one_segment(cmd)
    vals = [w.value for w in seg] if seg is not None else []
    j = ef.py_flags(vals) if vals else 0
    if vals[:1] != ["python3"] or vals[j:j + 1] != ["-c"] or len(vals) < j + 2 or "I" not in "".join(vals[1:j]):
        return None
    word = seg[j + 1].parts
    return (word[0][1], True) if len(word) == 1 and word[0][0] == "s" else None


def code_ext_safe(code, extra, banned_attrs, shell_text):
    """py_code_safe with its two relaxations only (R1-2): the class file's extra modules, and an
    allowed import anywhere. Every other restriction stays, plus banned_attrs."""
    if shell_text and re.search(r"[$`]", code):
        return False
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    mods = lambda n: n in extra or n.split(".")[0] in ef.PY_MODULES  # noqa: E731
    nodes, sys_ok = list(ast.walk(tree)), set()
    for node in nodes:
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == "sys" and node.attr in ef.SYS_OK):
            sys_ok.add(id(node.value))
    for node in nodes:
        if isinstance(node, ast.Import):
            if any(not mods(a.name) or (a.name == "sys" and a.asname) for a in node.names):
                return False
        elif isinstance(node, ast.ImportFrom):
            if (node.level or not mods(node.module or "")
                    or any(a.name in ef.PY_NAMES or ef.PY_ATTR.match(a.name)
                           or (node.module == "sys" and a.name not in ef.SYS_OK) for a in node.names)):
                return False
        elif isinstance(node, ast.Name):
            if node.id in ef.PY_NAMES or node.id.startswith("__") or (node.id == "sys" and id(node) not in sys_ok):
                return False
        elif isinstance(node, ast.Attribute) and (ef.PY_ATTR.match(node.attr) or node.attr in banned_attrs):
            return False
    return True


def inline_code_no_io(tool, inp, k):
    if tool != "Bash":
        return None
    got = code_of(inp.get("command") or "")
    if got is None:
        return None
    code, shell_text = got
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return None
    banned, calls = set(k.get("banned_modules") or []), set(k.get("banned_calls") or [])
    os_attrs, lits = k.get("banned_os_attrs") or [], k.get("protected_literals") or []
    for node in ast.walk(tree):
        names = [a.name for a in node.names] if isinstance(node, ast.Import) else \
            [node.module or ""] if isinstance(node, ast.ImportFrom) else []
        if any(n.split(".")[0] in banned for n in names):
            return "hard", "inline code imports a network or process module"
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in calls:
            return "hard", "inline code calls %s" % node.func.id
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in ("os", "posix")
                and any(fnmatch.fnmatchcase(node.attr, p) for p in os_attrs)):
            return "hard", "inline code runs a process (%s.%s)" % (node.value.id, node.attr)
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and any(x in node.value for x in lits):
            return "hard", "inline code names a guard or team-state path"
    if ef.py_code_safe(code, shell_text) or not code_ext_safe(code, set(k.get("extra_modules") or []),
                                                               set(k.get("banned_attrs") or []), shell_text):
        return None
    return "clearable", [], "local (python3 -I)"


# --- the decider ---------------------------------------------------------------------------------

def result(r, cls=None, reason="", pins=None, dest=None):
    return {"result": r, "class_id": cls, "reason": reason, "pins": pins or [], "dest": dest}


def tier_rest(tool, inp, cwd, project, main, rules_file):
    """(kind, why, rest) of tier_full on this structured request (team_prompt_authority)."""
    c = _checker()
    a = c.team_prompt_authority
    inp2 = dict(inp)
    target = inp2.get("file_path") or inp2.get("notebook_path")
    if isinstance(target, str) and target:
        inp2["file_path"] = os.path.join(cwd, os.path.expanduser(target))
    cmd = inp2.get("command") if isinstance(inp2.get("command"), str) else ""
    text = str(inp2.get("file_path") or inp2.get("url") or cmd.split("\n", 1)[0])
    extra = [rules_file] if rules_file and os.path.isfile(rules_file) else []
    kind, why, _, rest = a.tier_full(c, project, main, extra, tool, a.HEADERS.get(tool),
                                     [cmd] if tool == "Bash" else [], inp2, text, cwd)
    return kind, why, rest


def _clear(tool, inp, cwd, project, ctx, main, rules_file, launch_rules):
    k = load_classes()
    if tool not in TOOLS or not isinstance(inp, dict):
        return result("none", reason="tool not evaluated")
    cwd = cwd if isinstance(cwd, str) and cwd else project
    c = _checker()
    sources = load_sources(project, rules_file, main)
    if launch_rules is not None and launch_rules != rules_digest(sources):
        raise NoDecision("the session's rules changed since its launch")
    # 1. protected writes, reserved gh operations.
    target = file_target(inp, cwd) if tool in FILE_TOOLS else None
    if tool in FILE_TOOLS:
        if not target:
            return result("hard", reason="no file path")
        why = protected(target, project, main, k)
        if why:
            return result("hard", reason="write into " + why)
    cmd = inp.get("command") if tool == "Bash" else None
    if tool == "Bash":
        if not isinstance(cmd, str):
            return result("hard", reason="unreadable Bash command")
        for t, at in bash_targets(cmd, project, cwd):
            full = hd.resolve(t, at)
            why = protected(full, project, main, k) if full else ("an unresolvable protected name"
                                                                 if unresolved_protected(t) else "")
            if why:
                return result("hard", reason="Bash write into " + why)
        why = reserved_gh(cmd, k)
        if why:
            return result("hard", reason="reserved operation: " + why)
    # 2. the classifier.
    kind = None
    if tool == "Bash":
        kind, why = cl.classify_bash(cmd, project, cwd)
    elif tool == "WebFetch":
        kind, why = cl.classify_webfetch(inp.get("url"), project)
    if kind in ("deny", "operator"):
        return result("hard", reason="classifier %s: %s" % (kind, why))
    # 3. the tier.
    tkind, twhy, rest = tier_rest(tool, inp, cwd, project, main, rules_file)
    if rest is None:
        return result("hard", reason=str(twhy))
    worktree = (tool in FILE_TOOLS and ctx == "stage" and rest[0] == "operator"
                and str(rest[1]).startswith("refuse (outside clone)"))
    if rest[0] == "operator" and not worktree:
        return result("hard", reason=str(rest[1]))
    # 4. the session's effective rules: any deny or ask match, an unevaluable rule.
    deny, ask = rules_of(sources)
    for tier, rules in (("deny", deny), ("ask", ask)):
        for r in rules:
            if rule_hit(r, tool, inp, target, project, c):
                return result("hard", reason="%s rule %s" % (tier, r))
    hook = foreign_hook(sources, tool, set(k.get("reproduced_hooks") or []))
    if hook:
        raise NoDecision("a PreToolUse hook this checker does not reproduce: " + hook)
    # 5. pass: an egress read, no rule, no other cause.
    if kind == "pass" and tuple(rest) == ("lead", None):
        if tool == "WebFetch" or egress_read_pass(cmd, project):
            return result("pass", reason="egress read")
        return result("none", reason="no egress read (the classifier's pass covers no local effect)")
    # 6. the classes.
    if tool in FILE_TOOLS:
        found = [("starter-worktree-edit", starter_worktree_edit(tool, inp, cwd, project, k, main, ctx, rest))]
    elif kind != "ask" or tuple(rest) != ("lead", None):
        return result("none", reason="no class (kind %s)" % kind)
    else:
        found = [("public-get-long", public_get_long(tool, inp, cwd, project, k)),
                 ("lockfile-install", lockfile_install(tool, inp, cwd, project, k)),
                 ("gh-own-repo-write", gh_own_repo_write(tool, inp, cwd, project, k, main)),
                 ("inline-code-no-io", inline_code_no_io(tool, inp, k))]
    hard = [(n, f) for n, f in found if f and f[0] == "hard"]
    if hard:
        return result("hard", reason="%s: %s" % (hard[0][0], hard[0][1][1]))
    hits = [(n, f) for n, f in found if f]
    if len(hits) == 1:
        n, (_, pins, dest) = hits[0]
        return result("clearable", n, "class " + n, pins, dest)
    if len(hits) > 1:
        return result("none", reason="ambiguous: " + ", ".join(n for n, _ in hits))
    return result("none", reason="no class matches")


def clear_class(tool, inp, cwd, project, ctx, main, rules_file=None, launch_rules=None):
    try:
        return _clear(tool, inp, cwd, project, ctx, main, rules_file, launch_rules)
    except NoDecision as e:
        return result("none", reason="no decision: %s" % e)
    except Hard as e:
        return result("hard", reason=str(e))
    except Exception as e:  # noqa: BLE001 — the checker fails closed
        return result("hard", reason="checker error (%s: %s)" % (e.__class__.__name__, str(e)[:120]))


def request_hash(payload, pins, dest, binding):
    """sha256 over the canonical payload, its pins, the resolved destination and the binding
    (session, role, team, run, attempt, switch, list version)."""
    blob = json.dumps({"tool_name": payload.get("tool_name"), "tool_input": payload.get("tool_input"),
                       "cwd": payload.get("cwd"), "pins": pins, "dest": dest, "binding": binding},
                      sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()


def _cut(text, cap):
    text = str(text)
    return text if len(text.encode()) <= cap else \
        text.encode()[:cap].decode("utf-8", "ignore") + "\n    … cut at %d bytes of %d" % (cap, len(text.encode()))


def render(path, now):
    """One open request for the Supervisor (team-clearance.sh pending): the script's fields only,
    masked by touches.mask_obj; an edit's change and a body file's start, cut at the class file's caps."""
    if LIB not in sys.path:
        sys.path.insert(0, LIB)
    import touches
    k = load_classes()
    with open(path, encoding="utf-8") as fh:
        r = json.load(fh)
    p = r.get("payload") or {}
    ti = touches.mask_obj(p.get("tool_input") or {})
    try:
        left = int(cl_epoch(r.get("expires_at")) - now)
    except (TypeError, ValueError):
        left = 0
    who = " ".join(x for x in (r.get("role"), r.get("team"), r.get("run")) if x)
    out = ["%s — class %s · %s · dest %s · from %s (session %s%s) · %ds left" % (
        r.get("id"), r.get("class_id"), p.get("tool_name"), r.get("dest") or "-", who or "?",
        r.get("session_id") or "?", ", agent %s" % r["agent_type"] if r.get("agent_type") else "", max(left, 0))]
    out.append("  cwd: %s" % touches.mask_value(p.get("cwd") or ""))
    for key in ("command", "url", "file_path", "notebook_path"):
        if isinstance(ti.get(key), str):
            out.append("  %s: %s" % (key, ti[key].replace("\n", "\n    ")))
    if r.get("class_id") == "starter-worktree-edit":
        cap = int(k.get("edit_excerpt") or 4000)
        if "old_string" in ti:
            out.append("  change: %s\n  →\n  %s" % (_cut(ti.get("old_string", ""), cap), _cut(ti.get("new_string", ""), cap)))
        for e in ti.get("edits") or [] if isinstance(ti.get("edits"), list) else []:
            out.append("  change: %s\n  →\n  %s" % (_cut(e.get("old_string", ""), cap), _cut(e.get("new_string", ""), cap)))
        if "content" in ti or "new_source" in ti:
            out.append("  content: %s" % _cut(ti.get("content", ti.get("new_source", "")), cap))
    for pin in r.get("pins") or []:
        out.append("  pin: %s %s" % (pin[0], " ".join(str(x) for x in pin[1:])))
        if r.get("class_id") == "gh-own-repo-write" and os.path.isfile(pin[0]):
            cap = int(k.get("body_excerpt") or 2000)
            with open(pin[0], "rb") as fh:
                body = fh.read(cap + 1)
            out.append("  body: %s" % _cut(touches.mask_value(body.decode("utf-8", "replace")), cap).replace("\n", "\n    "))
    out.append("  hash: %s · list %s · answer: bash .claude/lib/team-clearance.sh answer %s allow|deny|unsure" % (
        r.get("request_hash"), r.get("list_version"), r.get("id")))
    print("\n".join(out))


def cl_epoch(at):
    import calendar
    import time
    return calendar.timegm(time.strptime(str(at), "%Y-%m-%dT%H:%M:%SZ"))


# --- CLI -----------------------------------------------------------------------------------------

USAGE = ("usage: guard_team_egress_clear.py classify --input-json <f> --project <p> --ctx "
         "stage|teamlead|advisor|supervisor --main <m> [--rules <f>] [--launch-rules <sha>] [--binding <json>]\n"
         "       guard_team_egress_clear.py digest --main <m>\n"
         "       guard_team_egress_clear.py protected --path <p> --project <p> --main <m>\n"
         "       guard_team_egress_clear.py render --request <f> [--now <epoch>]\n"
         "       guard_team_egress_clear.py rules-digest --project <p> [--rules <f>]")


def _opts(argv, names):
    o = {}
    while argv:
        a = argv.pop(0)
        if a not in names or not argv:
            raise ValueError(a)
        o[a] = argv.pop(0)
    return o


def main(argv):
    cmd, rest = (argv[0], list(argv[1:])) if argv else ("", [])
    try:
        if cmd == "digest":
            o = _opts(rest, ("--main",))
            try:
                print(list_version(o["--main"]))
            except (Hard, OSError, ValueError) as e:
                print("error: %s" % e, file=sys.stderr)
                return 1
            return 0
        if cmd == "protected":
            o = _opts(rest, ("--path", "--project", "--main"))
            try:
                print(protected(o["--path"], o["--project"], o["--main"], load_classes()))
            except Exception as e:  # noqa: BLE001 — the write guard refuses on a bug
                print("error: %s" % e, file=sys.stderr)
                return 2
            return 0
        if cmd == "render":
            o = _opts(rest, ("--request", "--now"))
            try:
                render(o["--request"], int(o.get("--now") or 0))
            except (OSError, ValueError, KeyError, TypeError) as e:
                print("error: %s" % e, file=sys.stderr)
                return 1
            return 0
        if cmd == "rules-digest":
            o = _opts(rest, ("--project", "--rules", "--main"))
            try:
                print(rules_digest(load_sources(o["--project"], o.get("--rules"), o.get("--main"))))
            except (Hard, NoDecision) as e:
                print("error: %s" % e, file=sys.stderr)
                return 1
            return 0
        if cmd not in ("classify", "hash"):
            raise ValueError(cmd)
        o = _opts(rest, ("--input-json", "--project", "--ctx", "--main", "--rules", "--launch-rules", "--binding"))
        if not all(x in o for x in ("--input-json", "--project", "--ctx", "--main")) \
                or o["--ctx"] not in ("stage", "teamlead", "advisor", "supervisor"):
            raise ValueError("missing option")
    except ValueError:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        with open(o["--input-json"], encoding="utf-8") as fh:
            payload = json.load(fh)
        tool, inp = payload.get("tool_name"), payload.get("tool_input")
        binding = json.loads(o["--binding"]) if "--binding" in o else None
    except (OSError, ValueError, AttributeError):
        print("result: hard\nclass: -\nreason: unreadable input")
        return 2
    r = clear_class(tool, inp, payload.get("cwd"), o["--project"], o["--ctx"], o["--main"],
                    o.get("--rules"), o.get("--launch-rules"))
    print("result: %s\nclass: %s\nreason: %s\ndest: %s\npins: %s" % (
        r["result"], r["class_id"] or "-", str(r["reason"]).replace("\n", " "), r["dest"] or "-",
        json.dumps(r["pins"], sort_keys=True)))
    if binding is not None and r["result"] == "clearable":
        print("hash: " + request_hash(payload, r["pins"], r["dest"], binding))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
