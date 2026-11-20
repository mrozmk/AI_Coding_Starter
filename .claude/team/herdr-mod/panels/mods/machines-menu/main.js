// Right-click menu for an orphaned process in Machines. Opened as a popup with
// props { pid, command, on }: on is the machine (null: this computer).
// Kill sends SIGTERM (the process may clean up), Force kill SIGKILL. Enter runs, Esc closes.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { props, closeOverlay, theme, exec, notify, run } from "herdr";

async function signal(p, name) {
  const r = await exec("kill", [`-${name}`, String(p.pid)], { on: p.on ?? null });
  if (r.code === 0) notify({ title: `Sent ${name} to ${p.pid}`, body: p.command, level: "success", timeout: 4000 });
  else notify({ title: `Cannot kill ${p.pid}`, body: (r.stderr || "").trim(), level: "error" });
  run("machines.refresh");
}

async function copyPid(p) {
  await exec("sh", ["-c", 'printf %s "$1" | pbcopy', "copy-pid", String(p.pid)]);
}

const ITEMS = [
  { label: "Kill", icon: "circle-x", run: (p) => signal(p, "TERM") },
  { label: "Force kill", icon: "skull", danger: true, run: (p) => signal(p, "KILL") },
  { label: "Copy PID", icon: "copy", separator: true, run: copyPid },
];

export default class MachinesMenu extends View {
  init(_props, cx) {
    this.at = 0;
    this.handle = cx.focus_handle();
    this.handle.focus();
  }

  // The signal goes out before the popup closes: a closed popup's work may not finish.
  async choose(i) {
    const p = props();
    if (p?.pid) await ITEMS[i]?.run(p);
    closeOverlay(p?.overlay);
  }

  render(cx) {
    const t = theme();
    return v_flex().id("machines-menu").track_focus(this.handle).w_full().min_h(0).p(5).bg(t.popover).text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % ITEMS.length;
        else if (e.key === "up") this.at = (this.at + ITEMS.length - 1) % ITEMS.length;
        else if (e.key === "enter") this.choose(this.at);
        else if (e.key === "escape") closeOverlay(props()?.overlay);
        else return;
        cx.notify();
      })
      .child(div().px(8).pt(4).pb(6).text_size(11).text_color(t.dim).truncate().child(`PID ${props()?.pid ?? ""}`))
      .children(ITEMS.flatMap((it, i) => [
        ...(it.separator ? [div().mx(7).my(4).h(1).bg(t.border)] : []),
        h_flex().id(`mmi-${i}`).h(31).px(8).gap(9).rounded(7).items_center()
          .text_color(it.danger ? t.ansi1 : t.foreground)
          .when(i === this.at, el => el.bg(t.selected))
          .hover(s => s.bg(t.hover))
          .on_click(() => this.choose(i))
          .child(svg(`mods/machines-menu/${it.icon}.svg`).size(14).flex_none().text_color(it.danger ? t.ansi1 : t.muted))
          .child(div().flex_1().child(it.label))]));
  }
}
