// Derived from Herdr's shipped "tabs" mod (Apache License 2.0); modified. Notices: NOTICE.md of the starter's Herdr panels kit.
import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, panes, run, openOverlay, theme, window, shared, layout, settings, focused, nextCommand, notify } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// Tabs that always show a chosen icon, by name, whatever runs in them: the session host's roles tab.
const TAB_ICONS = {
  Lead: "mods/tabs-plus/users.svg",
};

// Pane layouts for the shown tab. The focused terminal is the main one, the rest follow in
// tab order. Each step keeps a parked terminal back beside a placed one: [index, beside, place].
// Splits halve a pane and sizes can't be set, so runs are split in halves (4 → equal quarters).
const LAYOUTS = [
  { id: "zoom", title: "Only this pane", icon: "square" },
  { id: "cols", title: "Columns", icon: "columns-3", steps: (n) => halves(all(n), "right") },
  { id: "rows", title: "Rows", icon: "rows-3", steps: (n) => halves(all(n), "down") },
  { id: "left", title: "Main left", icon: "layout-panel-left", steps: (n) => [[1, 0, "right"], ...halves(all(n).slice(1), "down")] },
  { id: "top", title: "Main top", icon: "layout-panel-top", steps: (n) => [[1, 0, "down"], ...halves(all(n).slice(1), "right")] },
  { id: "grid", title: "Grid", icon: "grid-2x2", steps: (n) => grid(all(n)) },
];
const all = (n) => Array.from({ length: n }, (_, i) => i);
function halves(run, place) {
  if (run.length < 2) return [];
  const a = run.slice(0, Math.floor(run.length / 2)), b = run.slice(a.length);
  return [[b[0], a[0], place], ...halves(a, place), ...halves(b, place)];
}

// Two rows, each split in halves: 4 panes → 2×2, in reading order.
function grid(run) {
  const a = run.slice(0, Math.ceil(run.length / 2)), b = run.slice(a.length);
  return [[b[0], a[0], "down"], ...halves(a, "right"), ...halves(b, "right")];
}

// terminal.park/keep finish in the background: wait until the change shows.
async function until(cx, ok, ms = 4000) {
  for (const end = Date.now() + ms; Date.now() < end; await cx.sleep(80)) if (ok()) return true;
  return false;
}

export default class Tabs extends View {
  init(_props, cx) {
    this.pressed = null;
    this.panels = JSON.parse(localStorage.getItem("panels") ?? "{}");
    // Buttons and keys.json both send "tabs-plus.layout-<id>".
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        const l = LAYOUTS.find(x => `layout-${x.id}` === c);
        if (l && !this.busy) {
          this.busy = true;
          try { await this.arrange(l, cx); } finally { this.busy = false; }
        }
      }
    });
  }

  // Parks every terminal but the main one, then keeps them back in the layout's places.
  // The programs keep running throughout; only their panes are rebuilt.
  async arrange(l, cx) {
    const tab = focused()?.tab;
    const inTab = panes().filter(p => p.tab === tab && p.terminal);
    if (inTab.length < 2) return;
    const zoomed = inTab.find(p => p.zoomed);
    // Zoom toggles: the focused pane alone, or every pane again.
    if (l.id === "zoom") return run("pane.zoom", { pane: (zoomed ?? inTab.find(p => p.focused) ?? inTab[0]).pane });
    if (zoomed) run("pane.zoom", { pane: zoomed.pane });
    const main = (inTab.find(p => p.focused) ?? inTab[0]).terminal;
    const order = [main, ...inTab.map(p => p.terminal).filter(x => x !== main)];
    for (const t of order.slice(1)) run("terminal.park", { terminal: t });
    const has = (t) => panes().some(p => p.terminal === t);
    if (!await until(cx, () => order.slice(1).every(t => !has(t)))) return notify({ title: "Layout: panes did not close", level: "error" });
    for (const [i, beside, place] of l.steps(order.length)) {
      run("pane.focus", { terminal: order[beside] });
      await until(cx, () => focused()?.terminal === order[beside], 1500);
      run("terminal.keep", { terminal: order[i], place });
      if (!await until(cx, () => has(order[i]))) return notify({ title: "Layout: a terminal did not come back", body: "It still runs: open it from Agents.", level: "error" });
    }
    run("pane.focus", { terminal: main });
  }

  // The side panel is remembered per space: switching shows that space's choice
  // (closed if it never had one), and opening or closing it records it.
  syncPanel(space, panel, body, enabled) {
    if (!space || !panel) return;
    const now = panel.hidden ? null : body?.active ?? null;
    if (space.id !== this.space) {
      const first = this.space === undefined;
      this.space = space.id; this.pending = null;
      if (!(first && !(space.id in this.panels))) {
        const stored = this.panels[space.id] ?? null, want = enabled.includes(stored) ? stored : null;
        if (want !== now) {
          this.pending = { want, until: Date.now() + 1000 };
          if (want) { run("layout.select", { stack: "panel-body", child: want }); run("layout.show", { id: "panel" }); }
          else run("layout.hide", { id: "panel" });
          return;
        }
      }
    }
    // Until the restore lands (or something else won), the old state isn't a choice.
    if (this.pending) {
      if (this.pending.want !== now && Date.now() < this.pending.until) return;
      this.pending = null;
    }
    if (this.panels[space.id] === now) return;
    this.panels[space.id] = now;
    localStorage.setItem("panels", JSON.stringify(this.panels));
  }

  render() {
    const t = theme();
    const space = spaces().find(p => p.active);
    const shown = space?.tabs ?? [];
    const stop = (_e, cx) => cx.stop_propagation();
    const button = (id, label, action) => div().id(id).size(26).flex_none().flex().items_center().justify_center().rounded(6).text_color(t.dim).hover(s => s.bg(t.hover).text_color(t.foreground))
      .on_mouse_down("left", stop).on_click(action).child(label);
    const item = (c, i) => {
      const program = panes().find(p => p.tab === c.id && p.program?.agent)?.program ?? panes().find(p => p.tab === c.id)?.program;
      const name = /^tb\d+$/.test(c.name) ? program?.name ?? "Terminal" : c.name;
      return h_flex().id(`tab-${c.id}`).h(29).px(10).gap(7).rounded(7).items_center().flex_none().text_size(12.8)
        .border(1).border_color(c.active ? t.border : t.chrome).bg(c.active ? t.raised : t.chrome).text_color(c.active ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover))
        .on_mouse_down("left", (e, cx) => { cx.stop_propagation(); this.pressed = i; if (e.click_count === 2) run("tab.rename", { id: c.id }); })
        .on_mouse_up("left", () => {
          const from = this.pressed; this.pressed = null;
          if (from !== null && from !== i) run("tab.move", { id: shown[from].id, index: space.tabs.findIndex(x => x.id === c.id) + 1 });
          else run("tab.select", { id: c.id });
        })
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); openOverlay({ mod: "menu", kind: "popup", width: 200, props: { tab: "tab", target: { id: c.id, space: space.id } } }); })
        .when(Boolean(TAB_ICONS[c.name]), el => el.child(svg(TAB_ICONS[c.name]).size(14).text_color(t.muted)))
        .when(!TAB_ICONS[c.name] && Boolean(program?.icon), el => el.child(program.tint ? svg(program.icon).size(14).text_color(t.muted) : image(program.icon).size(14)))
        .child(div().max_w(170).truncate().child(c.zoomed ? `${name} Z` : name))
        .when(c.status === "working", el => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
        .when(c.status === "blocked" || c.status === "done", el => el.child(div().size(6).rounded(3).bg(t[c.status])))
        .when(c.active, el => el.child(div().id(`close-${c.id}`).text_color(t.dim).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); run("tab.close", { id: c.id }); }).child(svg("mods/pane/close.svg").size(12))));
    };
    const root = layout(), sidebar = find(root, "sidebar"), w = window();
    // Old saved rails and a dragged-narrow sidebar can be smaller than the window buttons.
    const lightsPadding = w?.platform === "macos" && w.titlebar === "none" && !w.fullscreen && root?.traffic_lights
      ? Math.max(10, (root.traffic_lights[0] + 64) / settings().zoom - (sidebar?.hidden ? 0 : sidebar?.size?.px ?? 0))
      : 10;
    const panel = find(root, "panel"), body = find(root, "panel-body");
    const enabled = [...(shared("workspace.panels") ?? ["files", "changes"]), "limits", "machines"];
    this.syncPanel(space, panel, body, enabled);
    const panelButton = (id, label, icon) => {
      const on = panel && !panel.hidden && body?.active === id;
      return h_flex().id(`panel-${id}`).h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(on ? t.selected : t.chrome).text_color(on ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => {
          if (on) run("layout.hide", { id: "panel" });
          else { run("layout.select", { stack: "panel-body", child: id }); run("layout.show", { id: "panel" }); }
        }).child(svg(icon).size(14)).child(label);
    };
    const activeTab = space?.tabs.find(x => x.active);
    const terminals = panes().filter(p => p.tab === activeTab?.id && p.terminal).length;
    const rule = () => div().w(1).h(16).flex_none().mx(8).bg(t.border);
    const layoutButton = (l, i) => div().id(`layout-${l.id}`).size(26).flex_none().flex().items_center().justify_center().rounded(6)
      .text_color(t.muted).hover(s => s.bg(t.hover).text_color(t.foreground)).on_mouse_down("left", stop)
      .when(l.id === "zoom" && Boolean(activeTab?.zoomed), el => el.bg(t.selected).text_color(t.foreground))
      .tooltip(`${l.title}  ⌘⌥${i + 1}`)
      .on_click(() => run(`tabs-plus.layout-${l.id}`)).child(svg(`mods/tabs-plus/${l.icon}.svg`).size(15));
    return h_flex().size_full().min_w(0).px(10).pl(lightsPadding).gap(3).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .on_mouse_up("left", () => { this.pressed = null; })
      .on_scroll_wheel(e => { if (Math.abs(e.delta.y) >= 1) run(e.delta.y > 0 ? "tab.prev" : "tab.next"); })
      // Three sections: tabs | layouts (centred: both sides grow alike) | panels.
      .child(h_flex().flex_1().min_w(0).h_full().items_center().gap(3)
        // "+" sits inside the scroll row, right after the last tab.
        .child(h_flex().id("tab-scroll").flex_1().min_w(0).h_full().items_center().gap(3).overflow_x_scrollbar().children(shown.map(item))
          .child(button("tab-new", "+", () => openOverlay({ mod: "new-menu", kind: "popup", width: 250, height: 512 })))))
      .child(rule())
      .child(h_flex().flex_none().gap(2).items_center().when(terminals < 2, el => el.opacity(0.35))
        .children(LAYOUTS.map(layoutButton)))
      .child(rule())
      .child(h_flex().flex_1().h_full().items_center().justify_end().gap(3)
      .when(enabled.includes("files"), el => el.child(panelButton("files", "Files", "mods/files/file.svg")))
      .when(enabled.includes("changes"), el => el.child(panelButton("changes", "Changes", "mods/changes/changes.svg")))
      .child(panelButton("limits", "Limits", "mods/limits/gauge.svg"))
      .child(panelButton("machines", "Machines", "mods/machines/activity.svg"))
      .when(w?.buttons, el => el.child(button("minimize", w.platform === "windows" ? svg("mods/tabs-plus/win-min.svg").size(16) : "−", () => run("window.minimize")))
        .child(button("maximize", w.platform === "windows" ? svg(`mods/tabs-plus/${w.maximized ? "win-restore" : "win-max"}.svg`).size(16) : "□", () => run("window.maximize")))
        .child(button("close-window", w.platform === "windows" ? svg("mods/tabs-plus/win-close.svg").size(16) : svg("mods/pane/close.svg").size(13), () => run("window.close")))));
  }
}
