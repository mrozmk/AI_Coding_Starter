"""Checks the supervision role profiles against the effective permission rules of the main checkout.

Usage: python3 -I .claude/lib/session_profile_check.py <main checkout> [--hooks]
         [--profiles <dir>] [role ...]

Rules come from the materialised profile (.agents/team/watch/profiles/<role>.settings.json,
written by `supervisor-sessions.sh materialize`) when it exists, else from the role profile, plus
the project settings. Each `_samples` command is classified deny > ask > allow > prompt with the
same fnmatch matcher team_prompt_check.py uses for tier 1 — an approximation of Claude Code's
matcher, so the live `/permissions` check stays a runbook step. `reads` must be allow, `secrets`
ask or deny, `writes` anything but allow. A `secrets`/`writes` sample allowed only once the local
settings are added is a LEAK. Exit 0 OK, 1 FAIL, 2 usage, 3 local leak (and no FAIL).
"""
import fnmatch
import json
import os
import re
import sys

# Mirror of TW_ROLES in team-watch-route.sh; the smoke part `sessions` asserts they are equal.
ROLES = ("Supervisor", "TeamLead")
LAYERS = (("project", ".claude/settings.json"), ("local", ".claude/settings.local.json"))


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError:
        return None


def bash_rules(perms):
    out = []
    for tier in ("deny", "ask", "allow"):
        for rule in perms.get(tier, []):
            m = re.match(r"^Bash\((.*)\)$", rule)
            if m:
                pat = m.group(1)
                pat = pat[:-2] + "*" if pat.endswith(":*") else pat
                out.append((tier, pat))
    return out


def match(text, rules):
    """→ (tier, pattern) of the deciding rule, or ("prompt", None)."""
    for tier in ("deny", "ask", "allow"):
        for t, pat in rules:
            if t != tier:
                continue
            if fnmatch.fnmatchcase(text, pat) or fnmatch.fnmatchcase(text, pat + "*"):
                return tier, pat
    return "prompt", None


def classify(text, rules):
    return match(text, rules)[0]


def effective(main, profile, role, notes):
    """→ (profile + project perms, the profile's own deny, local perms, project+local deny floor,
    materialised?)."""
    floor, layers = set(), {}
    for name, rel in LAYERS:
        data = load(os.path.join(main, rel))
        if data is None:
            notes.append("%s settings absent — skipped" % name)
        layers[name] = (data or {}).get("permissions", {})
        floor.update(layers[name].get("deny", []))
    mat = load(os.path.join(main, ".agents/team/watch/profiles/%s.settings.json" % role))
    own = (mat if mat is not None else profile).get("permissions", {})
    # Arrays merge across every layer: the project allow rules apply to the session too.
    perms = {t: own.get(t, []) + layers["project"].get(t, []) for t in ("deny", "ask", "allow")}
    return perms, own.get("deny", []), layers["local"], floor, mat is not None


def check_role(main, pdir, role, out):
    profile = load(os.path.join(pdir, "%s.settings.json" % role))
    if profile is None:
        out.append("%s FAIL: profile %s missing" % (role, role))
        return 1
    fails, leaks, notes = [], [], []
    if profile.get("env", {}).get("TEAM_SESSION_ROLE") != role:
        fails.append("env.TEAM_SESSION_ROLE is not %s" % role)
    perms, own_deny, local, floor, materialised = effective(main, profile, role, notes)
    lost = floor - set(own_deny)
    if materialised and lost:
        fails.append("materialised profile lost %d deny rules" % len(lost))
    rules = bash_rules(perms)
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
    with_local = rules + bash_rules(local)
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


def hooks(main, pdir, roles, out):
    layers = [(n, os.path.join(main, rel)) for n, rel in LAYERS]
    layers += [("profile:%s" % r, os.path.join(pdir, "%s.settings.json" % r)) for r in roles]
    for name, path in layers:
        for event, groups in sorted(((load(path) or {}).get("hooks") or {}).items()):
            for group in groups:
                for h in group.get("hooks", []):
                    out.append("hooks %s %s: %s" % (name, event, h.get("command", "?")))


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    main_dir, rest, roles, show_hooks = argv[0], argv[1:], [], False
    pdir = os.path.join(main_dir, ".claude/team/sessions")
    while rest:
        a = rest.pop(0)
        if a == "--hooks":
            show_hooks = True
        elif a == "--profiles" and rest:
            pdir = rest.pop(0)
        elif a in ROLES:
            roles.append(a)
        else:
            print("error: unknown argument %s" % a, file=sys.stderr)
            return 2
    roles = roles or list(ROLES)
    out = []
    codes = [check_role(main_dir, pdir, r, out) for r in roles]
    if show_hooks:
        hooks(main_dir, pdir, roles, out)
    print("\n".join(out))
    return 1 if 1 in codes else 3 if 3 in codes else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
