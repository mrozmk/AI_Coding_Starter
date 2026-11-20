// Name dialog for files-plus: rename an entry, or create a file or folder.
// Opened as a dialog with props { mode: "rename" | "file" | "folder", folder, name?, on }:
// folder is the absolute parent folder, name the current name (rename only), on the machine
// (null: this computer). Enter saves, Esc cancels. Never overwrites an existing name.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { props, closeOverlay, theme, exec, notify } from "herdr";

const EXISTS = '{ [ -e "$1" ] || [ -L "$1" ]; } && { echo "A file or folder with that name already exists" >&2; exit 3; };';
const SCRIPTS = {
  rename: `set -- "$2" "$1"; ${EXISTS} mv -- "$2" "$1"`,
  file: `${EXISTS} : > "$1"`,
  folder: `${EXISTS} mkdir -- "$1"`,
};
const TITLES = { rename: (n) => `Rename ${n}`, file: () => "New file", folder: () => "New folder" };
const BUTTONS = { rename: "Rename", file: "Create", folder: "Create" };
const DONE = { rename: (n) => `Renamed to ${n}`, file: (n) => `Created ${n}`, folder: (n) => `Created folder ${n}` };

export default class FilesName extends View {
  init(_props, cx) {
    const name = props()?.name ?? "";
    this.text = name;
    this.error = null;
    this.busy = false;
    this.input = InputState.new({ value: name });
    // Like Finder: select the name without its extension (all of it for dotfiles).
    const dot = name.lastIndexOf(".");
    if (name) this.input.set_selected_range({ start: 0, end: dot > 0 ? dot : name.length });
    this.input.on("change", (_e, cx) => { this.text = this.input.value(); this.error = null; cx.notify(); });
    this.input.on("submit", (_e, cx) => this.submit(cx));
    this.input.focus();
    cx.timer.after(600, () => this.input.focus());
    this.handle = cx.focus_handle();
  }

  submit(cx) {
    const p = props(), mode = p.mode ?? "rename", name = this.text.trim();
    if (this.busy) return;
    if (!name || (mode === "rename" && name === p.name)) { closeOverlay(p.overlay); return; }
    if (name.includes("/") || name === "." || name === "..") { this.error = "Name cannot contain / or be . or .."; cx.notify(); return; }
    const folder = p.folder.replace(/\/+$/, "");
    const args = mode === "rename" ? [`${folder}/${p.name}`, `${folder}/${name}`] : [`${folder}/${name}`];
    this.busy = true;
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", SCRIPTS[mode], "files-plus", ...args], { on: p.on ?? null });
      this.busy = false;
      if (r.code === 0) {
        closeOverlay(p.overlay);
        notify({ title: DONE[mode](name), level: "success", timeout: 3000 });
      } else {
        this.error = (r.stderr || "Failed").trim();
        cx.notify();
      }
    });
  }

  render(cx) {
    const t = theme(), p = props() ?? {}, mode = p.mode ?? "rename";
    const button = (id, text, primary, action) => h_flex().id(id).h(32).px(14).items_center().rounded(8)
      .border_1().border_color(primary ? t.solid : t.input).bg(primary ? t.solid : t.raised)
      .text_color(primary ? t.solid_foreground : t.foreground).text_size(12.5).font_medium().cursor_pointer()
      .hover(s => s.opacity(0.88)).on_click(action).child(text);
    return v_flex().id("files-name").track_focus(this.handle)
      .on_key_down((e, cx) => { if (e.key === "escape") { closeOverlay(p.overlay); cx.stop_propagation(); } })
      .w_full().min_h(0).p(18).bg(t.popover).text_color(t.foreground)
      .child(h_flex().items_center()
        .child(div().flex_1().min_w(0).truncate().text_size(15).font_semibold().child(TITLES[mode](p.name ?? "")))
        .child(div().text_size(11).text_color(t.dim).child("Esc")))
      .child(div().pt(16).pb(7).text_size(11.5).text_color(t.dim).truncate()
        .child(mode === "rename" ? "New name" : `In ${p.folder?.split("/").pop() || "/"}`))
      .child(Input.new(this.input).h(36).px(10).rounded(9).border_1().border_color(this.error ? t.ansi1 : t.accent).bg(t.background).text_size(12.8).text_color(t.foreground))
      .when(Boolean(this.error), el => el.child(div().pt(6).text_size(11.5).text_color(t.ansi1).child(this.error)))
      .child(h_flex().pt(20).gap(8).justify_end()
        .child(button("fn-cancel", "Cancel", false, () => closeOverlay(p.overlay)))
        .child(button("fn-save", BUTTONS[mode], true, (_e, cx) => this.submit(cx))));
  }
}
