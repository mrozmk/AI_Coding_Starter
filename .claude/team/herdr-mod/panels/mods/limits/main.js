// Usage limits of every Claude and Codex profile on this computer, as a side panel.
// Claude: ~/.claude*/rate-limits.json, written by the status line script on each refresh.
// Profiles are found in the home folder: .claude, .claude-*, .codex, .codex-* (Claude: with projects/, Codex: with sessions/), paired by suffix.
// Codex: the rate_limits of the newest session log under each CODEX_HOME.
// Both are snapshots from the profile's last use; a window past its reset counts as 0%.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, readTextFile, home, theme } from "herdr";

// Plain names only (CODEX_LAST splits a path with a space): letters, digits, . _ - after the dash.
const DISCOVER = 'cd "$HOME" || exit 0; for d in .claude .claude-* .codex .codex-*; do [ -d "$d" ] || continue; '
  + 'case "$d" in *[!A-Za-z0-9._-]*) continue ;; esac; '
  + 'case "$d" in .claude*) [ -d "$d/projects" ] && echo "$d" ;; *) [ -d "$d/sessions" ] && echo "$d" ;; esac; done';

// One group per suffix: .claude-x above .codex-x; the unsuffixed pair first, the rest by name.
function groupProfiles(dirs) {
  const bySuffix = {};
  for (const dir of dirs) {
    const kind = dir.startsWith(".claude") ? "claude" : "codex";
    const suffix = dir.slice(kind.length + 1);
    (bySuffix[suffix] ??= []).push({ name: dir.slice(1), kind, dir });
  }
  return Object.keys(bySuffix).sort((a, b) => (a === "" ? -1 : b === "" ? 1 : a.localeCompare(b)))
    .map(s => bySuffix[s].sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "claude" ? -1 : 1)));
}

// Prints the newest session log's mtime, then its last line carrying rate limits.
const CODEX_LAST = 'f=$(ls -t $(ls -d "$1"/sessions/*/*/* 2>/dev/null | tail -3 | sed "s|$|/*.jsonl|") 2>/dev/null | head -1); '
  + '[ -n "$f" ] || exit 0; stat -f %m "$f"; tail -c 400000 "$f" | grep \'"rate_limits":{\' | tail -1';

const windowLabel = (minutes) => minutes === 300 ? "5h" : minutes === 10080 ? "Week" : minutes >= 1440 ? `${Math.round(minutes / 1440)}d` : `${Math.round(minutes / 60)}h`;

async function claudeLimits(path) {
  const text = await readTextFile(`${path}/rate-limits.json`).catch(() => null);
  if (!text) return null;
  const data = JSON.parse(text), windows = [];
  if (data.five_hour) windows.push({ label: "5h", used: data.five_hour.used_percentage, resets: data.five_hour.resets_at });
  if (data.seven_day) windows.push({ label: "Week", used: data.seven_day.used_percentage, resets: data.seven_day.resets_at });
  return { at: data.at, windows };
}

async function codexLimits(path) {
  const r = await exec("sh", ["-c", CODEX_LAST, "codex-last", path]);
  const [mtime, line] = r.stdout.split("\n");
  if (!line) return null;
  const limits = JSON.parse(line)?.payload?.rate_limits ?? JSON.parse(line)?.rate_limits;
  if (!limits) return null;
  const windows = [limits.secondary, limits.primary].filter(Boolean)
    .sort((a, b) => a.window_minutes - b.window_minutes)
    .map(w => ({ label: windowLabel(w.window_minutes), used: w.used_percent, resets: w.resets_at }));
  return { at: Number(mtime), windows };
}

function ago(seconds) {
  const s = Math.max(0, Date.now() / 1000 - seconds);
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}

function until(seconds) {
  const s = seconds - Date.now() / 1000, d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.ceil(s % 3600 / 60);
  return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export default class Limits extends View {
  init(_props, cx) {
    this.data = {};
    this.groups = [];
    cx.spawn(async (cx) => {
      for (;;) {
        await this.load();
        this.loaded = true;
        cx.notify();
        await cx.sleep(30000);
      }
    });
  }

  async load() {
    const r = await exec("sh", ["-c", DISCOVER]).catch(() => null);
    this.groups = groupProfiles((r?.stdout ?? "").split("\n").filter(Boolean));
    await Promise.all(this.groups.flat().map(async (a) => {
      const path = `${home()}/${a.dir}`;
      try { this.data[a.name] = await (a.kind === "claude" ? claudeLimits(path) : codexLimits(path)); }
      catch { this.data[a.name] = null; }
    }));
  }

  bar(t, w) {
    const reset = w.resets && w.resets < Date.now() / 1000;
    const used = reset ? 0 : Math.min(100, Math.max(0, Math.round(w.used ?? 0)));
    const color = used >= 80 ? t.ansi1 : used >= 50 ? t.ansi3 : t.ansi2;
    return v_flex().gap(4)
      .child(h_flex().items_center().text_size(11.5)
        .child(div().w(38).text_color(t.muted).child(w.label))
        .child(div().flex_1().text_color(t.dim).child(reset ? "reset since" : w.resets ? `resets in ${until(w.resets)}` : ""))
        .child(div().font_medium().text_color(color).child(`${used}%`)))
      .child(div().h(5).w_full().rounded(3).bg(t.raised).child(div().h_full().rounded(3).bg(color).w(`${used}%`)));
  }

  card(t, a) {
    const d = this.data[a.name];
    return v_flex().gap(9).px(14).py(10)
      .child(h_flex().gap(7).items_center()
        .child(div().font_semibold().child(a.name))
        .child(div().flex_1())
        .when(Boolean(d?.at), el => el.child(div().text_size(11).text_color(t.dim).child(ago(d.at)))))
      .child(!d ? div().text_size(11.5).text_color(t.dim).child(!this.loaded ? "Loading…" : a.kind === "claude"
          ? "No data yet: it appears once a session in this profile runs"
          : "No sessions in this profile yet")
        : v_flex().gap(10).children(d.windows.map(w => this.bar(t, w))));
  }

  render() {
    const t = theme();
    return v_flex().id("limits").size_full().min_h(0).rounded(10).overflow_hidden().bg(t.background).border_1().border_color(t.border).text_color(t.foreground).text_size(13)
      .child(h_flex().h(42).flex_none().px(14).gap(8).items_center().border_b(1).border_color(t.border)
        .child(div().font_semibold().child("Limits")))
      .child(div().id("limits-scroll").flex_1().min_h(0).overflow_y_scrollbar()
        .child(v_flex().py(6).children(this.groups.flatMap((group, i) => [
          ...(i > 0 ? [div().mx(14).my(8).h(1).bg(t.border)] : []),
          ...group.map(a => this.card(t, a)),
        ]))));
  }
}
