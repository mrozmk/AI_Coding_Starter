"""Checks the supervision role profiles against the effective permission rules of the main checkout.

Usage: python3 -I .claude/lib/session_profile_check.py <main checkout> [--hooks]
         [--profiles <dir>] [--clone <dir>] [role ...]

Roles: the team-watch receiver (ROLES, the Supervisor) plus every standing, enabled Claude role of
teams.sessions with a `settings` template (read through roles-lib.sh, the one reader); a role's
template may carry another name (Fable → Advisor.settings.json). A declared `TeamLead` is the per-run
launcher's model/effort, never a session profile, and is skipped. Rules come from the materialised profile
(.agents/team/watch/profiles/<role>.settings.json, written by `supervisor-sessions.sh materialize`,
whose env role must be <role>) when it exists, else from the template, plus the project settings. The per-run role TeamLead-run reads TeamLead-run.settings.json and, with
--clone <dir>, the materialised <dir>/.agents/team/teamlead.settings.json (team-lead.sh
materialize); its env role is TeamLead. Each `_samples` command is classified deny > ask > allow > prompt with the
same fnmatch matcher team_prompt_check.py uses for tier 1 — an approximation of Claude Code's
matcher, so the live `/permissions` check stays a runbook step. `reads` must be allow, `secrets`
ask or deny, `writes` anything but allow. A sample written `Read(<path>)` is checked against the
Read(...) rules instead (`**/` also matches no directory). A `secrets`/`writes` sample allowed only
once the local settings are added is a LEAK. Exit 0 OK, 1 FAIL, 2 usage, 3 local leak (and no FAIL).
"""
import fnmatch
import json
import os
import re
import subprocess
import sys

# Mirror of TW_ROLES in team-watch-route.sh; the smoke part `sessions` asserts they are equal.
ROLES = ("Supervisor",)
# Per-run roles: never in ROLES (not team-watch receivers); profile <role>.settings.json, env role
# without the suffix.
RUN_ROLES = ("TeamLead-run",)
LAYERS = (("project", ".claude/settings.json"), ("local", ".claude/settings.local.json"))


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError:
        return None


def bash_rules(perms, tool="Bash"):
    out = []
    for tier in ("deny", "ask", "allow"):
        for rule in perms.get(tier, []):
            m = re.match(r"^%s\((.*)\)$" % tool, rule)
            if m:
                pat = m.group(1)
                pat = pat[:-2] + "*" if pat.endswith(":*") else pat
                out.append((tier, ("Read:" if tool == "Read" else "") + pat))
    return out


def tool_rules(perms):
    return bash_rules(perms) + bash_rules(perms, "Read")


def fits(text, pat):
    m = re.match(r"^Read\((.*)\)$", text)
    if pat.startswith("Read:") != bool(m):
        return False
    if not m:
        return fnmatch.fnmatchcase(text, pat) or fnmatch.fnmatchcase(text, pat + "*")
    path, pat = m.group(1), pat[len("Read:"):]
    return fnmatch.fnmatchcase(path, pat) or (pat.startswith("**/")
                                               and fnmatch.fnmatchcase(path, pat[3:]))


def match(text, rules):
    """→ (tier, pattern) of the deciding rule, or ("prompt", None)."""
    for tier in ("deny", "ask", "allow"):
        for t, pat in rules:
            if t != tier:
                continue
            if fits(text, pat):
                return tier, pat
    return "prompt", None


def classify(text, rules):
    return match(text, rules)[0]


def effective(main, profile, mat_path, notes):
    """→ (profile + project perms, the profile's own deny, local perms, project+local deny floor,
    materialised?)."""
    floor, layers = set(), {}
    for name, rel in LAYERS:
        data = load(os.path.join(main, rel))
        if data is None:
            notes.append("%s settings absent — skipped" % name)
        layers[name] = (data or {}).get("permissions", {})
        floor.update(layers[name].get("deny", []))
    mat = load(mat_path) if mat_path else None
    own = (mat if mat is not None else profile).get("permissions", {})
    # Arrays merge across every layer: the project allow rules apply to the session too.
    perms = {t: own.get(t, []) + layers["project"].get(t, []) for t in ("deny", "ask", "allow")}
    return perms, own.get("deny", []), layers["local"], floor, mat is not None


def declared(main):
    """→ {role: settings template} of the standing, enabled Claude roles with a template, from
    roles-lib.sh; {} when the lib is absent (an older checkout)."""
    lib = os.path.join(main, ".claude/lib/roles-lib.sh")
    if not os.path.isfile(lib):
        return {}
    prog = ('. "$1" || exit 3; out="$(roles_list --standing)" || exit 3; for r in $out; do '
            's="$(roles_cfg "$r" settings)" || exit 3; [ -z "$s" ] || printf "%s\\t%s\\n" "$r" "$s"; done')
    p = subprocess.run(["bash", "-c", prog, "_", lib], cwd=main, capture_output=True, text=True,
                       env=dict(os.environ, ROLES_ROOT=main))
    if p.returncode != 0:
        raise ValueError((p.stderr.strip().splitlines() or ["roles-lib.sh failed"])[-1])
    found = dict(line.split("\t", 1) for line in p.stdout.splitlines() if "\t" in line)
    found.pop("TeamLead", None)
    return found


def mat_path(main, role, clone):
    if role in RUN_ROLES:
        return os.path.join(clone, ".agents/team/teamlead.settings.json") if clone else None
    return os.path.join(main, ".agents/team/watch/profiles/%s.settings.json" % role)


def check_role(main, pdir, role, out, clone=None, template=None):
    template = template or role
    profile = load(os.path.join(pdir, "%s.settings.json" % template))
    if profile is None:
        out.append("%s FAIL: profile %s missing" % (role, template))
        return 1
    fails, leaks, notes = [], [], []
    env_role = template.split("-")[0] if template in RUN_ROLES else template
    if profile.get("env", {}).get("TEAM_SESSION_ROLE") != env_role:
        fails.append("env.TEAM_SESSION_ROLE is not %s" % env_role)
    mp = mat_path(main, role, clone)
    perms, own_deny, local, floor, materialised = effective(main, profile, mp, notes)
    if materialised and role not in RUN_ROLES \
            and (load(mp) or {}).get("env", {}).get("TEAM_SESSION_ROLE") != role:
        fails.append("materialised env.TEAM_SESSION_ROLE is not %s" % role)
    if role in RUN_ROLES and clone and not materialised:
        fails.append("materialised profile missing in %s" % clone)
    lost = floor - set(own_deny)
    if materialised and lost:
        fails.append("materialised profile lost %d deny rules" % len(lost))
    rules = tool_rules(perms)
    samples = profile.get("_samples", {})
    for cmd in samples.get("forbidden", []):
        got = classify(cmd, rules)
        if got != "deny":
            fails.append("%s → %s, expected deny" % (cmd, got))
    for s in samples.get("allowed", []):
        cmd, want = (s["cmd"], s.get("expect")) if isinstance(s, dict) else (s, None)
        got = classify(cmd, rules)
        if (want and got != want) or (not want and got == "deny"):
            fails.append("%s → %s, expected %s" % (cmd, got, want or "not deny"))
    for skill in samples.get("skills", []):
        if skill not in perms["deny"]:
            fails.append("%s → absent, expected deny" % skill)
    for cmd in samples.get("reads", []):
        got = classify(cmd, rules)
        if got != "allow":
            fails.append("%s → %s, expected allow" % (cmd, got))
    with_local = rules + tool_rules(local)
    for kind, bad in (("secrets", ("allow", "prompt")), ("writes", ("allow",))):
        for cmd in samples.get(kind, []):
            got = classify(cmd, rules)
            if got in bad:
                fails.append("%s → %s, expected %s" % (
                    cmd, got, "ask or deny" if kind == "secrets" else "not allow"))
                continue
            tier, pat = match(cmd, with_local)
            if got != "allow" and tier == "allow":
                leaks.append("%s allowed by local Bash(%s)" % (cmd, pat))
    out.extend("%s FAIL: %s" % (role, f) for f in fails)
    out.extend("%s LEAK: %s — Operator: remove it from settings.local.json" % (role, x)
               for x in leaks)
    if not fails and not leaks:
        out.append("%s OK" % role)
    out.extend("%s note: %s" % (role, n) for n in notes)
    return 1 if fails else 3 if leaks else 0


def hooks(main, pdir, roles, out, templates):
    layers = [(n, os.path.join(main, rel)) for n, rel in LAYERS]
    layers += [("profile:%s" % r, os.path.join(pdir, "%s.settings.json" % templates.get(r, r)))
               for r in roles]
    for name, path in layers:
        for event, groups in sorted(((load(path) or {}).get("hooks") or {}).items()):
            for group in groups:
                for h in group.get("hooks", []):
                    out.append("hooks %s %s: %s" % (name, event, h.get("command", "?")))


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    main_dir, rest, roles, show_hooks, clone = argv[0], argv[1:], [], False, None
    pdir = os.path.join(main_dir, ".claude/team/sessions")
    try:
        templates = declared(main_dir)
    except ValueError as e:
        print("error: teams.sessions: %s" % e, file=sys.stderr)
        return 2
    while rest:
        a = rest.pop(0)
        if a == "--hooks":
            show_hooks = True
        elif a == "--profiles" and rest:
            pdir = rest.pop(0)
        elif a == "--clone" and rest:
            clone = rest.pop(0)
        elif a in ROLES or a in RUN_ROLES or a in templates:
            roles.append(a)
        else:
            print("error: unknown argument %s" % a, file=sys.stderr)
            return 2
    roles = roles or list(ROLES) + [r for r in templates if r not in ROLES]
    out = []
    codes = [check_role(main_dir, pdir, r, out, clone, templates.get(r)) for r in roles]
    if show_hooks:
        hooks(main_dir, pdir, roles, out, templates)
    print("\n".join(out))
    return 1 if 1 in codes else 3 if 3 in codes else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
