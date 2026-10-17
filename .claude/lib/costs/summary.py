"""Period summary of Claude + Codex token usage: build + render (TT-980).

Python 3.9 stdlib only.
"""
from datetime import datetime, timedelta

import bindings
import config
import report
import store

LOW_CACHE_MIN_TOTAL = 1_000_000
TOP_N = 10
PROVIDERS = ("claude", "codex")
SCOPES = (("claude", "team", "Claude zespoły"), ("claude", "supervisor", "Claude supervisor"),
          ("codex", "team", "Codex zespoły"), ("codex", "supervisor", "Codex supervisor"))
MAIN_KIND = "sesja główna"
TS_FMT = "%Y-%m-%dT%H:%M:%S.%fZ"


def _agg():
    return dict.fromkeys(bindings.TOKENS + ("calls",), 0)


def _add(agg, row, share=1.0):
    for k, v in bindings.tokens(row, share).items():
        agg[k] += v
    agg["calls"] += 1


def total(agg):
    return sum(agg[k] for k in bindings.TOKENS)


def full(agg):
    return agg["input"] + agg["cache_write"] + agg["output"]


def hit(agg):
    seen = agg["input"] + agg["cache_write"] + agg["cache_read"]
    return agg["cache_read"] / seen if seen else None


def _fmt(n):
    if n >= 1e6:
        return f"{n / 1e6:.1f} M"
    if n >= 1e3:
        return f"{n / 1e3:.0f} k"
    return str(round(n))


def _pct(x):
    return "-" if x is None else f"{x * 100:.1f}%"


def _day_ts(day):
    return f"{day.isoformat()}T00:00:00.000Z"


def _period_rows(conn, since, until):
    return conn.execute("SELECT * FROM usage WHERE ts >= ? AND ts < ? ORDER BY ts",
                        (_day_ts(since), _day_ts(until + timedelta(days=1)))).fetchall()


def _dirs(cfg):
    """(dir, is_clone) — the first configured dir of a project is its main checkout."""
    return [(d, i > 0) for dirs in cfg["projects"].values() for i, d in enumerate(dirs)]


def _clone_of(dirs, cwd):
    """Longest configured dir wins, as in config.project_for_cwd."""
    best = max((d for d in dirs if config.under(cwd, d[0])), key=lambda d: len(d[0]),
               default=None)
    return best[0] if best and best[1] else None


def _scope(dirs, roles, row):
    """(scope, clone_dir)."""
    clone = _clone_of(dirs, row["cwd"])
    if clone:
        return "team", clone
    if row["provider"] == "claude" and row["session"] in roles:
        return "team", None
    return "supervisor", None


def _codex_roles(conn, dirs, roles, threads):
    """Role per Codex thread: the allocator's lineage first, then an inferred team-run role."""
    parents = bindings.lineage_parents(conn)
    # The thread's own first usage, not sessions.first_ts: replayed parent history lowers that.
    starts = {r[0]: (r[1], r[2]) for r in conn.execute(
        "SELECT session, MIN(ts), cwd FROM usage WHERE provider = 'codex' AND ts IS NOT NULL"
        " GROUP BY session")}
    runs = conn.execute("SELECT role, cwd, at FROM registrations WHERE source = 'team-run'"
                        " AND provider = 'claude' AND role IS NOT NULL ORDER BY at").fetchall()
    out = {}
    for thread in threads:
        linked = [roles[s][1] for s in bindings.ancestors(parents, "codex", thread)
                  if s in roles and roles[s][1]]
        if linked:
            out[thread] = linked[0]
            continue
        first_ts, cwd = starts.get(thread, (None, None))
        clone = _clone_of(dirs, cwd)
        inferred = [r["role"] for r in runs if config.under(r["cwd"], clone)
                    and r["at"] <= first_ts] if clone and first_ts else []
        out[thread] = f"{inferred[-1]} (inferred)" if inferred else "-"
    return out


def _kind(labels, row):
    if row["provider"] == "codex":
        s = labels.sessions.get(("codex", row["session"], ""))
        return (s and s["source_label"]) or "codex"
    if not row["agent_id"]:
        return MAIN_KIND
    return labels.types.get((row["session"], row["agent_id"])) or "subagent"


def _facts(conn, cfg, labels, rows):
    """Per-row (row, scope, clone, role, kind, agent label) shared by every section."""
    dirs = _dirs(cfg)
    threads = {r["session"] for r in rows if r["provider"] == "codex"}
    codex_roles = _codex_roles(conn, dirs, labels.roles, threads)
    out = []
    for row in rows:
        scope, clone = _scope(dirs, labels.roles, row)
        agent, _, role = labels.agent(row)
        if row["provider"] == "codex":
            role = codex_roles[row["session"]]
        out.append({"row": row, "scope": scope, "clone": clone, "role": role or "-",
                    "kind": _kind(labels, row), "agent": agent})
    return out


def _group(facts, key):
    groups = {}
    for f in facts:
        _add(groups.setdefault(key(f), _agg()), f["row"])
    return groups


def _by_provider(facts, key):
    """{key: {provider: agg}} for the tables that split Claude and Codex columns."""
    groups = {}
    for f in facts:
        aggs = groups.setdefault(key(f), {p: _agg() for p in PROVIDERS})
        _add(aggs[f["row"]["provider"]], f["row"])
    return groups


def _merged(aggs):
    out = _agg()
    for agg in aggs:
        for k in out:
            out[k] += agg[k]
    return out


def _tickets(conn, facts):
    tickets, clones, unassigned = {}, {}, 0.0
    # allocate returns one entry per input row, in input order.
    for fact, a in zip(facts, bindings.allocate(conn, [f["row"] for f in facts])):
        row = a["row"]
        unassigned += total(bindings.tokens(row)) * a["unassigned_share"]
        if a["conflict"]:
            continue
        for b in a["bindings"]:
            aggs = tickets.setdefault(b["ticket"], {p: _agg() for p in PROVIDERS})
            _add(aggs[row["provider"]], row, b["share"])
            if fact["clone"]:
                clones.setdefault(b["ticket"], set()).add(fact["clone"])
    rows = sorted(tickets.items(), key=lambda kv: -full(_merged(kv[1].values())))[:TOP_N]
    return [{"ticket": t, "claude": aggs["claude"], "codex": aggs["codex"],
             "clones": len(clones.get(t, ()))} for t, aggs in rows], unassigned


def _roles(facts):
    groups = _by_provider(facts, lambda f: f["role"])
    order = sorted((r for r in groups if r != "-"),
                   key=lambda r: -full(_merged(groups[r].values())))
    return [(r, groups[r]) for r in order + (["-"] if "-" in groups else [])]


def _low_cache(facts):
    groups, names = {}, {}
    for f in facts:
        row = f["row"]
        key = (row["provider"], row["session"], row["agent_id"] or "")
        _add(groups.setdefault(key, _agg()), row)
        names.setdefault(key, f["agent"])
    big = [(names[k], k[0], g) for k, g in groups.items()
           if total(g) >= LOW_CACHE_MIN_TOTAL and hit(g) is not None]
    return sorted(big, key=lambda x: hit(x[2]))[:TOP_N]


def _duration(first, last):
    span = datetime.strptime(last, TS_FMT) - datetime.strptime(first, TS_FMT)
    minutes = int(span.total_seconds()) // 60
    return f"{minutes // 60}:{minutes % 60:02d}"


def _supervisor(facts, labels):
    sessions = {}
    for f in facts:
        row = f["row"]
        if row["provider"] != "claude" or f["scope"] != "supervisor":
            continue
        s = sessions.setdefault(row["session"], {
            "label": labels.main(row), "all": _agg(),
            "main": _agg(), "first": row["ts"], "last": row["ts"]})
        _add(s["all"], row)
        if not row["agent_id"]:
            _add(s["main"], row)
        s["first"], s["last"] = min(s["first"], row["ts"]), max(s["last"], row["ts"])
    out = []
    for s in sorted(sessions.values(), key=lambda s: -full(s["all"]))[:TOP_N]:
        main = s["main"]
        context = main["input"] + main["cache_write"] + main["cache_read"]
        out.append({"label": s["label"], "agg": s["all"], "calls": main["calls"],
                    "avg_context": context / main["calls"] if main["calls"] else None,
                    "duration": _duration(s["first"], s["last"])})
    return out


def _coverage(conn, facts, labels, unassigned):
    grand = sum(total(bindings.tokens(f["row"])) for f in facts)
    partial = {(f["row"]["provider"], f["row"]["session"], f["row"]["agent_id"] or "")
               for f in facts if labels.partial(f["row"])}
    skipped = conn.execute("SELECT COUNT(*) FROM files WHERE provider = 'codex'"
                           " AND skipped = 1").fetchone()[0]
    return {"unassigned_pct": unassigned / grand if grand else None, "partial": len(partial),
            "codex_skipped": skipped}


def build(conn, cfg, since, until):
    """Summary of the UTC days since..until (both `datetime.date`, inclusive)."""
    header = {"since": since.isoformat(), "until": until.isoformat(),
              "last_collect_at": store.get_meta(conn, "last_collect_at")}
    rows = _period_rows(conn, since, until)
    if not rows:
        return {"header": header, "empty": True}
    labels = report.Labels(conn)
    facts = _facts(conn, cfg, labels, rows)
    tickets, unassigned = _tickets(conn, facts)
    return {
        "header": header, "empty": False,
        "totals": _group(facts, lambda f: (f["row"]["provider"], f["scope"])),
        "days": sorted(_by_provider(facts, lambda f: f["row"]["ts"][:10]).items()),
        "tickets": tickets,
        "roles": _roles(facts),
        "models": sorted(_group(facts, lambda f: (f["row"]["provider"], f["row"]["model"],
                                                  f["row"]["effort"])).items(),
                         key=lambda kv: -full(kv[1])),
        "kinds": sorted(_group(facts, lambda f: (f["row"]["provider"], f["kind"])).items(),
                        key=lambda kv: -full(kv[1])),
        "low_cache": _low_cache(facts),
        "supervisor": _supervisor(facts, labels),
        "coverage": _coverage(conn, facts, labels, unassigned),
    }


def _table(head, rows, text=1):
    """The first `text` columns are left-aligned labels, the rest right-aligned numbers."""
    align = "|---" * text + "|---:" * (len(head) - text) + "|"
    return ["| " + " | ".join(head) + " |", align] + \
        ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]


def _metrics(agg):
    return [_fmt(total(agg)), _fmt(full(agg)), _pct(hit(agg))]


def _legend():
    return ["### Legenda", "",
            "- **Razem** — wszystkie tokeny: input + cache write + cache read + output.",
            "- **Pełna stawka** — input + cache write + output (cache read kosztuje ≈ 0.1×"
            " ceny inputu, output ≈ 5×).",
            "- **Cache hit** — cache read / (input + cache write + cache read)."]


def _totals_md(totals):
    rows = []
    for provider, scope, name in SCOPES:
        agg = totals.get((provider, scope), _agg())
        rows.append([name] + _metrics(agg) + [_fmt(agg["output"])])
    grand = _merged(totals.values())
    rows.append(["**Razem**"] + _metrics(grand) + [_fmt(grand["output"])])
    return ["### Sumy", ""] + _table(["Zakres", "Razem", "Pełna stawka", "Cache hit",
                                      "Output"], rows)


def _days_md(days):
    rows = [[d, _fmt(total(a["claude"])), _fmt(full(a["claude"])), _fmt(total(a["codex"])),
             _fmt(full(a["codex"]))] for d, a in days]
    return ["### Per dzień", ""] + _table(["Dzień", "Claude razem", "Claude pełna",
                                           "Codex razem", "Codex pełna"], rows)


def _tickets_md(tickets):
    rows = []
    for t in tickets:
        both = _merged((t["claude"], t["codex"]))
        flag = f"⚠ {t['clones']} klony" if t["clones"] > 1 else ""
        rows.append([t["ticket"], _fmt(total(both)), _fmt(full(both)), _fmt(full(t["claude"])),
                     _fmt(full(t["codex"])), _pct(hit(both)), flag])
    return [f"### Top {TOP_N} ticketów wg pełnej stawki", ""] + (_table(
        ["Ticket", "Razem", "Pełna stawka", "Claude pełna", "Codex pełna", "Cache hit",
         "Klony"], rows) if rows else ["- brak przypisań"])


def _roles_md(roles):
    rows = [[r, _fmt(total(a["claude"])), _fmt(full(a["claude"])), _fmt(total(a["codex"])),
             _fmt(full(a["codex"])), _pct(hit(_merged(a.values())))] for r, a in roles]
    return ["### Per rola", ""] + _table(["Rola", "Claude razem", "Claude pełna", "Codex razem",
                                          "Codex pełna", "Cache hit"], rows)


def _models_md(models):
    rows = [[p, m or "-", e or "-"] + _metrics(a) + [_fmt(a["output"])]
            for (p, m, e), a in models]
    return ["### Per model × effort", ""] + _table(["Provider", "Model", "Effort", "Razem",
                                                    "Pełna stawka", "Cache hit", "Output"], rows,
                                                   text=3)


def _kinds_md(kinds):
    rows = [[p, k, a["calls"]] + _metrics(a) for (p, k), a in kinds]
    return ["### Per rodzaj agenta", ""] + _table(["Provider", "Rodzaj", "Wywołania", "Razem",
                                                   "Pełna stawka", "Cache hit"], rows, text=2)


def _low_cache_md(groups):
    head = f"### Najniższy cache hit (Razem ≥ {_fmt(LOW_CACHE_MIN_TOTAL)})"
    rows = [[name, p, _fmt(total(a)), _pct(hit(a))] for name, p, a in groups]
    return [head, ""] + (_table(["Agent", "Provider", "Razem", "Cache hit"], rows, text=2)
                         if rows else ["- brak"])


def _supervisor_md(sessions):
    rows = [[s["label"]] + _metrics(s["agg"]) + [
        "-" if s["avg_context"] is None else _fmt(s["avg_context"]), s["calls"], s["duration"]]
        for s in sessions]
    return ["### Sesje supervisora", ""] + (_table(
        ["Sesja", "Razem", "Pełna stawka", "Cache hit", "Śr. kontekst / wywołanie",
         "Wywołania", "Czas"], rows) if rows else ["- brak"])


def _coverage_md(cov, header):
    return ["### Pokrycie", "",
            f"- Nieprzypisane do ticketu: {_pct(cov['unassigned_pct'])} Razem",
            f"- Sesje częściowe w okresie: {cov['partial']}",
            f"- Pominięte pliki Codex (codex_skipped): {cov['codex_skipped']}",
            f"- Ostatni collect: {header['last_collect_at'] or '-'}",
            "- Zakres: pierwszy skonfigurowany katalog projektu = główny checkout"
            " (supervisor), kolejne = klony zespołów."]


def render_md(data):
    h = data["header"]
    out = [f"## Zużycie tokenów — {h['since']}..{h['until']} (UTC)", "",
           f"- Ostatni collect: {h['last_collect_at'] or '-'}"]
    if data["empty"]:
        return "\n".join(out + ["", "no data"]) + "\n"
    sections = [_legend(), _totals_md(data["totals"]), _days_md(data["days"]),
                _tickets_md(data["tickets"]), _roles_md(data["roles"]),
                _models_md(data["models"]), _kinds_md(data["kinds"]),
                _low_cache_md(data["low_cache"]), _supervisor_md(data["supervisor"]),
                _coverage_md(data["coverage"], h)]
    for section in sections:
        out += [""] + section
    return "\n".join(out) + "\n"
