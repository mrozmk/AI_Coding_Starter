// Load of each machine: CPU, memory, swap, disk, the heaviest processes and orphaned dev
// processes (right-click one to kill it). Reads only while this panel is shown, every 20 s.
// macOS only for now: a Linux machine needs its own probe (/proc) before it can be listed.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, layout, run, openOverlay, nextCommand, theme } from "herdr";

// on: the machine as exec takes it (null: this computer).
const MACHINES = [{ on: null, name: "This Mac" }];
const REFRESH_MS = 20000;

// Room for more teams, always rounded down. A team runs one Claude session at a time
// (planner → coder → qa → wrapup), measured live with its helpers (MCP servers, tsserver),
// plus headroom for the builds and tests it starts.
const BUILD_HEADROOM_MB = 1024;
const TEAM_MIN_MB = 1536;
const SYSTEM_RESERVE_MB = 2048;
// macOS grows swap on demand, so its size says nothing about how full it is: judge it against RAM.
// Up to a quarter of RAM is tolerated as cold pages; beyond that it counts as memory already borrowed.
const SWAP_TOLERATED_SHARE = 0.25;
const SWAP_METER_SHARE = 0.5;
// Sustained reads back from swap mean the Mac is waiting on disk right now.
const SWAP_IN_BUSY_MB_S = 5;

const PROBE = [
  "echo @ncpu; sysctl -n hw.ncpu",
  "echo @load; sysctl -n vm.loadavg",
  "echo @mem; sysctl -n hw.memsize",
  "echo @vm; vm_stat",
  "echo @swap; sysctl -n vm.swapusage",
  "echo @pressure; sysctl -n kern.memorystatus_vm_pressure_level",
  "echo @disk; df -k /System/Volumes/Data | tail -1",
  "echo @boot; sysctl -n kern.boottime",
  "echo @user; id -un",
  "echo @ram; top -l 1 -o mem -stats pid,mem,command",
  "echo @procs; ps -axo pid=,ppid=,etime=,rss=,%cpu=,user=,command=",
  "echo @top; top -l 2 -s 1 -o cpu -n 40 -stats pid,cpu,command",
].join("; ");

// Orphans: our own interpreters and shells whose parent died (ppid 1), alive over an hour.
const ORPHAN_KIND = /(^|\/)(bash|sh|zsh|node|python[\d.]*|Python|dotnet|deno|bun|ruby|perl|claude|codex)(\s|$)/;
// Daemons that live under launchd on purpose.
const NOT_ORPHANS = [/tmux/, /app-server daemon/, /agent_mail_deliver/, /MSBuild\.dll.*nodeReuse/, /VBCSCompiler/, /limactl|colima/];

function sections(text) {
  const out = {};
  let key = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("@")) { key = line.slice(1).trim(); out[key] = []; }
    else if (key && line.trim()) out[key].push(line);
  }
  return out;
}

const seconds = (etime) => {
  const [days, rest] = etime.includes("-") ? etime.split("-") : ["0", etime];
  return rest.split(":").map(Number).reduce((total, n) => total * 60 + n, 0) + Number(days) * 86400;
};
const appName = (path) => path.match(/([^/]+)\.app\//)?.[1] ?? path.split("/").pop();
const gb = (bytes) => `${(bytes / 2 ** 30).toFixed(1).replace(".", ",")} GB`;
const mb = (megabytes) => (megabytes >= 1024 ? `${(megabytes / 1024).toFixed(1).replace(".", ",")} GB` : `${Math.round(megabytes)} MB`);
// "/Library/.../Python -m http.server 4321" reads as "Python -m http.server 4321".
const short = (command) => command.replace(/^\S*\//, "");
const age = (s) => s >= 86400 ? `${Math.floor(s / 86400)} d` : s >= 3600 ? `${Math.floor(s / 3600)} h` : `${Math.floor(s / 60)} min`;

// Used as Activity Monitor counts it: app memory + wired + compressed. File cache is reclaimable.
function vmStats(lines) {
  const page = Number(/page size of (\d+)/.exec(lines[0] ?? "")?.[1]);
  const bytes = (name) => Number(/(\d+)\.\s*$/.exec(lines.find(l => l.startsWith(`${name}:`)) ?? "")?.[1]) * page;
  return {
    used: bytes("Anonymous pages") - bytes("Pages purgeable") + bytes("Pages wired down") + bytes("Pages occupied by compressor"),
    swapIns: bytes("Swapins"),
  };
}

// MB read back from swap per second since the last reading; none after a long gap (panel hidden).
function swapRate(now, bytes, prev) {
  const elapsed = prev?.swapAt ? (now - prev.swapAt) / 1000 : Infinity;
  if (elapsed < 5) return { swapAt: prev.swapAt, swapBytes: prev.swapBytes, swapInRate: prev.swapInRate };
  return { swapAt: now, swapBytes: bytes, swapInRate: elapsed <= 120 ? (bytes - prev.swapBytes) / elapsed / 2 ** 20 : null };
}

// Claude, Codex, Herdr and the window server, whose load follows the AI windows open, as one row.
const AI_POOL = /^(claude|codex|WindowServer|Herdr|herdr)/;
// The heaviest five, processes of the same name summed. The row's pid is only a stable key.
function topRows(rows, key) {
  const totals = new Map();
  for (const r of rows) {
    const name = AI_POOL.test(r.name) ? "AI sessions" : r.name;
    totals.set(name, (totals.get(name) ?? 0) + r[key]);
  }
  return [...totals].map(([name, value], pid) => ({ pid, name, [key]: value })).sort((a, b) => b[key] - a[key]).slice(0, 5);
}

const UNIT_MB = { B: 1 / 2 ** 20, K: 1 / 1024, M: 1, G: 1024 };

function parse(text, prev) {
  const s = sections(text), number = (k) => Number(s[k]?.[0]);
  const memory = number("mem"), vm = vmStats(s.vm ?? []);
  const swap = /total = ([\d.]+)M\s+used = ([\d.]+)M/.exec(s.swap?.[0] ?? "");
  const disk = (s.disk?.[0] ?? "").split(/\s+/);
  const user = s.user?.[0]?.trim();
  const samples = (s.top ?? []).join("\n").split("Processes:");
  const last = samples[samples.length - 1] ?? "";
  const idle = Number(/([\d.]+)% idle/.exec(last)?.[1] ?? NaN);
  const topCpu = topRows(last.split("\n").filter(l => /^\d+\s+[\d.]+\s+/.test(l)).map(l => {
    const [, pid, cpu, name] = /^(\d+)\s+([\d.]+)\s+(.*)$/.exec(l.trim());
    return { pid: Number(pid), cpu: Number(cpu), name: name.trim() };
  }), "cpu");
  // Footprint, not rss: it includes what the process has compressed or swapped out.
  const footprints = (s.ram ?? []).map(l => /^\s*(\d+)\*?\s+([\d.]+)([BKMG])[+-]?\s+(.*)$/.exec(l)).filter(Boolean)
    .map(m => ({ pid: Number(m[1]), rss: Number(m[2]) * UNIT_MB[m[3]], name: m[4].trim() }));
  const procs = (s.procs ?? []).map(l => {
    const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+([\d.]+)\s+(\S+)\s+(.*)$/.exec(l);
    return m && { pid: Number(m[1]), ppid: Number(m[2]), age: seconds(m[3]), rss: Number(m[4]) / 1024, cpu: Number(m[5]), user: m[6], command: m[7] };
  }).filter(Boolean);
  // top cuts names to 16 characters, which leaves a virtual machine unrecognizable.
  const vmName = procs.some(p => /limactl|colima/.test(p.command)) ? "Colima VM" : "Virtual machine";
  const topRam = topRows(footprints, "rss").map(f => f.name.startsWith("com.apple.Virtua") ? { ...f, name: vmName } : f);
  const base = (p) => p.command.split(" ")[0].split("/").pop();
  const orphans = procs.filter(p => p.ppid === 1 && p.user === user && p.age >= 3600
    && ORPHAN_KIND.test(p.command) && !NOT_ORPHANS.some(r => r.test(p.command)));
  const result = {
    pressure: number("pressure"),
    cpus: number("ncpu"),
    cpu: Number.isNaN(idle) ? null : Math.round(100 - idle),
    load: (s.load?.[0] ?? "").replace(/[{}]/g, "").trim().split(/\s+/).map(Number),
    memory, used: vm.used, ram: Number.isNaN(vm.used) ? null : vm.used / memory * 100,
    ...swapRate(Date.now(), vm.swapIns, prev),
    swap: swap ? { total: Number(swap[1]), used: Number(swap[2]) } : null,
    disk: disk.length > 3 ? { used: Number(disk[2]) * 1024, free: Number(disk[3]) * 1024 } : null,
    boot: Number(/sec = (\d+)/.exec(s.boot?.[0] ?? "")?.[1] ?? NaN),
    agents: { claude: procs.filter(p => base(p) === "claude").length, codex: procs.filter(p => base(p) === "codex" && !/app-server/.test(p.command)).length },
    topCpu, topRam, orphans,
  };
  result.capacity = capacity(result, procs, new Map(footprints.map(f => [f.pid, f.rss])));
  return result;
}

// Typical footprint of one Claude session: the process plus everything it started. The median,
// because one session running a VM or a big build would otherwise set the price of every team.
function sessionMb(procs, footprint) {
  const children = new Map();
  for (const p of procs) children.set(p.ppid, [...(children.get(p.ppid) ?? []), p]);
  const tree = (p) => (footprint.get(p.pid) ?? p.rss) + (children.get(p.pid) ?? []).reduce((sum, c) => sum + tree(c), 0);
  const claude = procs.filter(p => /^(\S*\/)?claude(\.exe)?(\s|$)/.test(p.command) && !/--chrome-native-host/.test(p.command));
  const pids = new Set(claude.map(p => p.pid));
  const sizes = claude.filter(p => !pids.has(p.ppid)).map(tree).sort((a, b) => a - b);
  return sizes.length ? sizes[Math.floor(sizes.length / 2)] : 0;
}

// What is free after the reserve, minus swap beyond the tolerated share, divided by a team's size.
// A negative budget says how many teams too many are running. High pressure or active swapping: none.
function capacity(d, procs, footprint) {
  const ramMb = d.memory / 2 ** 20;
  const perTeam = Math.max(TEAM_MIN_MB, sessionMb(procs, footprint) + BUILD_HEADROOM_MB);
  const usable = ramMb - d.used / 2 ** 20 - SYSTEM_RESERVE_MB;
  const swapOver = Math.max(0, (d.swap?.used ?? 0) - ramMb * SWAP_TOLERATED_SHARE);
  const budget = usable - swapOver;
  const teams = new Set(procs.map(p => /team-run\.sh ([a-z]+)/.exec(p.command)?.[1]).filter(Boolean)).size;
  let room = Math.max(0, Math.floor(budget / perTeam)), why = null;
  if (d.pressure >= 2) { room = 0; why = "memory pressure is high"; }
  else if (d.swapInRate >= SWAP_IN_BUSY_MB_S) { room = 0; why = "the Mac is reading from swap"; }
  return { room, over: budget < 0 ? Math.ceil(-budget / perTeam) : 0, perTeam, usable, swapOver, teams, why };
}

// Shown: the side panel is open on this mod.
function shown() {
  const find = (node, id) => node?.id === id ? node : (node?.children ?? []).map(c => find(c, id)).find(Boolean) ?? null;
  const root = layout(), panel = find(root, "panel"), body = find(root, "panel-body");
  return Boolean(panel && !panel.hidden && body?.active === "machines");
}

export default class Machines extends View {
  init(_props, cx) {
    this.data = {};
    this.at = 0;
    this.busy = false;
    // Cheap check every 2 s; the probe itself runs only while shown and stale.
    cx.spawn(async (cx) => {
      for (;;) {
        if (shown() && Date.now() - this.at >= REFRESH_MS) await this.load(cx);
        await cx.sleep(2000);
      }
    });
    cx.spawn(async (cx) => {
      for (;;) {
        if (await nextCommand() === "refresh") await this.load(cx);
      }
    });
  }

  async load(cx) {
    if (this.busy) return;
    this.busy = true; cx.notify();
    await Promise.all(MACHINES.map(async (m) => {
      try {
        const r = await exec("sh", ["-c", PROBE], { on: m.on });
        this.data[m.name] = r.code === 0 || r.stdout ? parse(r.stdout, this.data[m.name]) : { error: (r.stderr || "No answer").trim() };
      } catch (e) { this.data[m.name] = { error: String(e) }; }
    }));
    this.at = Date.now(); this.busy = false;
    cx.notify();
  }

  meter(t, label, percent, detail) {
    const p = Math.min(100, Math.max(0, Math.round(percent ?? 0)));
    const color = p >= 90 ? t.ansi1 : p >= 70 ? t.ansi3 : t.ansi2;
    return v_flex().gap(4)
      .child(h_flex().items_center().text_size(11.5)
        .child(div().w(46).text_color(t.muted).child(label))
        .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(detail))
        .child(div().font_medium().text_color(percent === null ? t.dim : color).child(percent === null ? "–" : `${p}%`)))
      .child(div().h(5).w_full().rounded(3).bg(t.raised).child(div().h_full().rounded(3).bg(color).w(`${p}%`)));
  }

  capacityBox(t, c) {
    const color = c.room === 0 ? t.ansi1 : c.room === 1 ? t.ansi3 : t.ansi2;
    const teamWord = (n) => `${n} team${n === 1 ? "" : "s"}`;
    const verdict = c.over > 0 ? `Over by ${teamWord(c.over)}` : c.room === 0 ? "No room for another team" : `Room for ${c.room} more team${c.room === 1 ? "" : "s"}`;
    const usable = mb(Math.max(0, c.usable));
    return v_flex().gap(3).px(10).py(8).rounded(8).border_1().border_color(color)
      .child(h_flex().gap(8).items_center()
        .child(div().size(8).rounded(4).bg(color))
        .child(div().flex_1().font_semibold().text_color(color).child(verdict))
        .child(div().text_size(11).text_color(t.dim).child(`${c.teams} running`)))
      .child(div().text_size(11).text_color(t.dim).child(c.why
        ? `${c.why[0].toUpperCase()}${c.why.slice(1)} · ~${mb(c.perTeam)} per team`
        : c.swapOver > 0 ? `${usable} free − ${mb(c.swapOver)} swap · ~${mb(c.perTeam)} per team`
        : `${usable} usable · ~${mb(c.perTeam)} per team`));
  }

  heading(t, text) {
    return div().text_size(10.5).font_medium().text_color(t.muted).child(text.toUpperCase());
  }

  row(t, id, cells, el) {
    return h_flex().id(id).h(22).px(4).gap(8).items_center().rounded(5).text_size(11.5).children(cells).when(Boolean(el), el ?? (x => x));
  }

  card(t, m) {
    const d = this.data[m.name];
    const body = !d ? div().text_size(11.5).text_color(t.dim).child("Loading…")
      : d.error ? div().text_size(11.5).text_color(t.ansi1).child(d.error)
      : this.sections(t, [
        this.capacityBox(t, d.capacity),
        v_flex().gap(10)
          .child(this.meter(t, "CPU", d.cpu, `load ${d.load.map(n => n.toFixed(1)).join(" ")} · ${d.cpus} cores`))
          .child(this.meter(t, "RAM", d.ram, `${gb(d.memory * d.ram / 100)} / ${gb(d.memory)} in use`))
          .child(this.meter(t, "Swap", d.swap ? d.swap.used / (d.memory / 2 ** 20 * SWAP_METER_SHARE) * 100 : 0, d.swap ? `${mb(d.swap.used)} / ${mb(d.memory / 2 ** 20 * SWAP_METER_SHARE)}${d.swapInRate === null ? "" : ` · in ${d.swapInRate.toFixed(1).replace(".", ",")} MB/s`}` : ""))
          .child(this.meter(t, "Disk", d.disk ? d.disk.used / (d.disk.used + d.disk.free) * 100 : null, d.disk ? `${gb(d.disk.free)} free` : ""))
          .child(h_flex().gap(12).text_size(11.5).text_color(t.dim)
            .child(div().child(`up ${age(Date.now() / 1000 - d.boot)}`))
            .child(div().child(`${d.agents.claude} Claude · ${d.agents.codex} Codex`))),
        v_flex().gap(6)
          .child(this.heading(t, "Top memory"))
          .child(v_flex().children(d.topRam.map(p => this.row(t, `ram-${m.name}-${p.pid}`, [
            div().flex_1().min_w(0).truncate().child(p.name),
            div().text_color(t.dim).child(mb(p.rss))])))),
        v_flex().gap(6)
          .child(this.heading(t, "Top CPU"))
          .child(v_flex().children(d.topCpu.map(p => this.row(t, `cpu-${m.name}-${p.pid}`, [
            div().flex_1().min_w(0).truncate().child(p.name),
            div().text_color(t.dim).child(`${p.cpu.toFixed(0)}%`)])))),
        v_flex().gap(6)
          .child(this.heading(t, `Orphaned · ${d.orphans.length}`))
          .child(d.orphans.length === 0 ? div().text_size(11.5).text_color(t.dim).child("None")
            : v_flex().children(d.orphans.map(p => this.row(t, `orphan-${m.name}-${p.pid}`, [
              div().w(44).flex_none().text_color(t.dim).child(String(p.pid)),
              div().flex_1().min_w(0).truncate().child(short(p.command)),
              div().flex_none().text_color(p.cpu >= 5 ? t.ansi3 : t.dim).child(`${p.cpu.toFixed(0)}% · ${age(p.age)}`)],
              el => el.hover(s => s.bg(t.hover)).on_mouse_down("right", (_e, cx) => {
                cx.stop_propagation();
                openOverlay({ mod: "machines-menu", kind: "popup", width: 190, props: { pid: p.pid, command: p.command, on: m.on } });
              })))))
          .when(d.orphans.length > 0, el => el.child(div().text_size(10.5).text_color(t.dim).child("Right-click a process to kill it"))),
      ]);
    return v_flex().gap(10).px(14).py(12).border_b(1).border_color(t.border)
      .child(div().font_semibold().child(m.name))
      .child(body);
  }

  // Sections with a rule and some air between them.
  sections(t, parts) {
    return v_flex().children(parts.flatMap((part, i) => [
      ...(i > 0 ? [div().my(14).h(1).bg(t.border)] : []),
      part,
    ]));
  }

  render(cx) {
    const t = theme();
    const updated = this.at ? new Date(this.at).toTimeString().slice(0, 8) : "";
    return v_flex().id("machines").size_full().min_h(0).rounded(10).overflow_hidden().bg(t.background).border_1().border_color(t.border).text_color(t.foreground).text_size(13)
      .child(h_flex().h(42).flex_none().px(14).gap(8).items_center().border_b(1).border_color(t.border)
        .child(div().font_semibold().child("Machines"))
        .child(div().flex_1())
        .child(div().text_size(11).text_color(t.dim).child(this.busy ? "Reading…" : updated))
        .child(div().id("machines-refresh").size(22).flex().items_center().justify_center().rounded(5).text_color(t.dim)
          .hover(s => s.bg(t.hover).text_color(t.foreground)).on_click(() => this.load(cx))
          .child(svg("mods/machines/refresh-cw.svg").size(13))))
      .child(div().id("machines-scroll").flex_1().min_h(0).overflow_y_scrollbar()
        .child(v_flex().children(MACHINES.map(m => this.card(t, m)))));
  }
}
