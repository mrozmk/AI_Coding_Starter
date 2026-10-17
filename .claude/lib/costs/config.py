"""Paths, config and timestamp normalization for the token-usage tool (spec TT-813).

Python 3.9 stdlib only.
"""
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

EXAMPLE = ".claude/lib/costs/config.example.json"
DEFAULT_STAGE_SKILLS = [
    "prime", "brainstorm", "plan-feature", "execute", "check-implementation", "qa-verify",
    "pr-create", "orchestrate", "quick-change", "pr-merge",
]
OPEN_END = "9999-12-31T00:00:00.000Z"
TICKET_RE = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?"
    r"(Z|[+-]\d{2}:?\d{2})?)?$")


def fail(code, message):
    print(f"cost: {message}", file=sys.stderr)
    raise SystemExit(code)


def home():
    return os.path.expanduser(os.environ.get("AGENT_COSTS_HOME") or "~/.agent-costs")


def db_path():
    return os.path.join(home(), "costs.sqlite")


def config_path():
    return os.path.join(home(), "config.json")


def runtime_path():
    return os.path.join(home(), "runtime.jsonl")


def _norm_dir(value):
    return os.path.normpath(os.path.expanduser(value))


def load_config():
    path = config_path()
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        fail(2, f"no config at {path} — copy {EXAMPLE} there and edit it")
    except (OSError, json.JSONDecodeError) as err:
        fail(2, f"cannot read {path}: {err}")
    projects = cfg.get("projects") if isinstance(cfg, dict) else None
    if not isinstance(projects, dict) or not projects:
        fail(2, f"{path}: 'projects' must map a name to a list of dirs (see {EXAMPLE})")
    cfg["projects"] = {name: [_norm_dir(d) for d in dirs] for name, dirs in projects.items()}
    cfg["claude_projects_dir"] = _norm_dir(cfg.get("claude_projects_dir") or "~/.claude/projects")
    homes = cfg.get("codex_homes") or [os.environ.get("CODEX_HOME") or "~/.codex"]
    cfg["codex_homes"] = [_norm_dir(h) for h in homes]
    cfg["stage_skills"] = list(cfg.get("stage_skills") or DEFAULT_STAGE_SKILLS)
    return cfg


def slug(directory):
    return re.sub(r"[^a-zA-Z0-9]", "-", directory)


def under(path, directory):
    return bool(path) and (path == directory or path.startswith(directory + "/"))


def project_for_cwd(cfg, cwd):
    best, best_len = None, -1
    for name, dirs in cfg["projects"].items():
        for d in dirs:
            if under(cwd, d) and len(d) > best_len:
                best, best_len = name, len(d)
    return best


def resolve_cwd(cfg, value):
    expanded = _norm_dir(value)
    for dirs in cfg["projects"].values():
        for d in dirs:
            if d == expanded or slug(d) == value:
                return d
    fail(2, f"--cwd {value} is not a configured project dir or slug")


def norm_ts(value):
    """Canonical UTC `YYYY-MM-DDTHH:MM:SS.mmmZ`; raises ValueError on anything else."""
    m = TS_RE.match(value.strip()) if isinstance(value, str) else None
    if not m:
        raise ValueError(f"not an ISO timestamp: {value!r}")
    day, clock, frac, zone = m.groups()
    if clock and not zone:
        raise ValueError(f"timestamp with a time needs Z or an offset: {value!r}")
    dt = datetime.strptime(f"{day}T{clock or '00:00:00'}", "%Y-%m-%dT%H:%M:%S")
    if zone and zone != "Z":
        sign = -1 if zone[0] == "-" else 1
        digits = zone[1:].replace(":", "")
        dt -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    # Truncate, never round: rounding could move a timestamp across a window boundary.
    millis = (frac or "").ljust(3, "0")[:3]
    return dt.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + f".{millis}Z"


def safe_ts(value):
    try:
        return norm_ts(value)
    except ValueError:
        return None


def now_ts():
    return norm_ts(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:23] + "Z")
