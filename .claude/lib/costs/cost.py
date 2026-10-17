"""Token usage per ticket — collect, bind, unassigned, report, summary (TT-813, TT-821, TT-980).

Usage:
  python3 cost.py collect [--project NAME]
  python3 cost.py bind TICKET (--session UUID_OR_REGISTERED_NAME | --turn ID
                              | --window FROM TO --cwd DIR_OR_SLUG | --team-run CLONE_DIR RUN_ID)
                              [--share F] [--provider P] [--note T]
  python3 cost.py unassigned --since DATE [--project NAME]
  python3 cost.py report TICKET [--with-children A,B] [--by-stage]
                         [--format md|json|jira] [--jira-action COMMENTS_JSON]
  python3 cost.py summary [--days N | --since YYYY-MM-DD [--until YYYY-MM-DD]]
Exit codes: 0 ok · 2 usage/config error · 3 binding refused or Jira comment history incomplete
· 4 no DB yet (run collect).
Data lives in $AGENT_COSTS_HOME (default ~/.agent-costs). Python 3.9 stdlib only.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import bindings
import claude_adapter
import codex_adapter
import config
import jira_comment
import report
import runtime
import store
import summary


def _open(create=False):
    path = config.db_path()
    if not create and not os.path.exists(path):
        config.fail(4, "no data yet — run cost.py collect")
    conn = store.connect(path)
    store.migrate(conn)
    return conn


def cmd_collect(args):
    cfg = config.load_config()
    if args.project and args.project not in cfg["projects"]:
        config.fail(2, f"unknown project {args.project}")
    conn = _open(create=True)
    stats = {"files": 0, "new_occurrences": 0, "codex_skipped": 0}
    touched = set()
    runtime_lines = runtime.ingest(conn)
    for name, dirs in cfg["projects"].items():
        if args.project in (None, name):
            touched |= claude_adapter.collect_project(conn, cfg, name, dirs, stats)
    touched |= codex_adapter.collect_codex(conn, cfg, stats, args.project)
    store.recompute(conn, touched)
    store.set_meta(conn, "last_collect_at", config.now_ts())
    conn.commit()
    usage_rows = conn.execute("SELECT COUNT(*) FROM usage").fetchone()[0]
    partial = conn.execute("SELECT COUNT(*) FROM sessions WHERE coverage_reasons IS NOT NULL"
                           ).fetchone()[0]
    print(f"collect: files={stats['files']} new_occurrences={stats['new_occurrences']}"
          f" usage_rows={usage_rows} codex_skipped={stats['codex_skipped']}"
          f" partial_sessions={partial} runtime_lines={runtime_lines}")
    return 0


def _bind_team_run(conn, cfg, args):
    if args.share != 1.0 or args.provider:
        config.fail(2, "--team-run binds whole sessions — no --share or --provider")
    created, run_ticket = bindings.bind_team_run(conn, cfg, args.ticket, *args.team_run,
                                                 note=args.note)
    if run_ticket != args.ticket:
        print(f"cost: warning — run records name {run_ticket}, binding {args.ticket}",
              file=sys.stderr)
    for bid, kind, provider, basis in created:
        scope = f" provider={provider}" if provider else ""
        print(f"bind: #{bid} {args.ticket} {kind}{scope} share=1 basis={basis}")
    return 0


def cmd_bind(args):
    cfg = config.load_config()
    conn = _open()
    runtime.ingest(conn)
    conn.commit()
    if args.team_run:
        return _bind_team_run(conn, cfg, args)
    if args.session:
        args.session = runtime.resolve_name(conn, args.session)
    bid, basis = bindings.add_binding(conn, cfg, args.ticket, session=args.session,
                                      turn=args.turn, window=args.window, cwd=args.cwd,
                                      share=args.share, provider=args.provider, note=args.note)
    kind = "window" if args.window else ("session" if args.session else "turn")
    print(f"bind: #{bid} {args.ticket} {kind} share={args.share:g} basis={basis}")
    return 0


def cmd_unassigned(args):
    config.load_config()
    conn = _open()
    try:
        since = config.norm_ts(args.since)
    except ValueError as err:
        config.fail(2, str(err))
    sys.stdout.write(report.render_unassigned_md(bindings.unassigned(conn, since, args.project)))
    return 0


def cmd_report(args):
    cfg = config.load_config()
    conn = _open()
    if args.jira_action and args.format not in (None, "jira"):
        config.fail(2, "--jira-action renders the Jira body — drop --format")
    fmt = args.format or ("jira" if args.jira_action else "md")
    children = [c.strip() for c in (args.with_children or "").split(",") if c.strip()]
    data = report.build(conn, cfg, args.ticket, children, args.by_stage)
    if args.jira_action:
        action = jira_comment.decide(jira_comment.load_comments(args.jira_action), args.ticket,
                                     jira_comment.body(data))
        print(json.dumps(action, indent=2, ensure_ascii=False))
    elif fmt == "jira":
        sys.stdout.write(jira_comment.body(data))
    else:
        sys.stdout.write(report.render_json(data) if fmt == "json" else report.render_md(data))
    return 0


def _date(value, flag):
    try:
        day = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        day = None
    # strptime also takes "2026-10-1"; the round trip keeps the format strict.
    if day is None or day.isoformat() != value:
        config.fail(2, f"{flag} {value!r} is not a YYYY-MM-DD date")
    return day


def _period(args):
    """(since, until) UTC dates, both inclusive; default the last 30 days."""
    today = datetime.now(timezone.utc).date()
    if args.until is not None and args.since is None:
        config.fail(2, "--until needs --since")
    if args.since is None:
        days = 30 if args.days is None else args.days
        if days < 1:
            config.fail(2, f"--days {days} must be at least 1")
        return today - timedelta(days=days - 1), today
    since = _date(args.since, "--since")
    until = _date(args.until, "--until") if args.until is not None else today
    if since > until:
        config.fail(2, f"--since {since} is after --until {until}")
    return since, until


def cmd_summary(args):
    cfg = config.load_config()
    since, until = _period(args)
    conn = _open()
    sys.stdout.write(summary.render_md(summary.build(conn, cfg, since, until)))
    return 0


def _parser():
    parser = argparse.ArgumentParser(prog="cost.py", description="Token usage per ticket.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("collect")
    p.add_argument("--project")
    p.set_defaults(func=cmd_collect)
    p = sub.add_parser("bind")
    p.add_argument("ticket")
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--session")
    target.add_argument("--turn")
    target.add_argument("--window", nargs=2, metavar=("FROM", "TO"))
    target.add_argument("--team-run", nargs=2, metavar=("CLONE_DIR", "RUN_ID"))
    p.add_argument("--cwd")
    p.add_argument("--share", type=float, default=1.0)
    p.add_argument("--provider", choices=("claude", "codex"))
    p.add_argument("--note")
    p.set_defaults(func=cmd_bind)
    p = sub.add_parser("unassigned")
    p.add_argument("--since", required=True)
    p.add_argument("--project")
    p.set_defaults(func=cmd_unassigned)
    p = sub.add_parser("report")
    p.add_argument("ticket")
    p.add_argument("--with-children")
    p.add_argument("--by-stage", action="store_true")
    p.add_argument("--format", choices=("md", "json", "jira"))
    p.add_argument("--jira-action", metavar="COMMENTS_JSON")
    p.set_defaults(func=cmd_report)
    p = sub.add_parser("summary")
    period = p.add_mutually_exclusive_group()
    period.add_argument("--days", type=int)
    period.add_argument("--since")
    p.add_argument("--until")
    p.set_defaults(func=cmd_summary)
    return parser


def main(argv=None):
    try:
        args = _parser().parse_args(argv)
        return args.func(args)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 1


if __name__ == "__main__":
    sys.exit(main())
