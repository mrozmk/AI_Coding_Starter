// A file editor that fills its own tab: ⌘S (Ctrl+S elsewhere) saves. Opened by files-plus with
// tab.new { name, mod: "file-view", props: { file, on, preview? } }: file is absolute, on is the
// machine (null: this computer), preview: true renders Markdown instead of showing its source.
// Reloads when the file changes (this computer only); unsaved edits are kept and the header says so.
// Read-only where a save could lose data: another machine's file, a truncated (over LIMIT) file.
// Files without a text preview (images, PDFs) get a button to open them in their macOS app.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, Editor, EditorState, TextView } from "gpui-base";
import { props, readTextFile, writeTextFile, watchFolder, exec, theme, settings, notify } from "herdr";

const LANG = { md: "markdown", ts: "js", tsx: "js", mts: "js", cts: "js", jsx: "js", mjs: "js", toml: "yaml", jsonc: "json", svelte: "html", vue: "html" };
const LIMIT = 400000;

export default class FileView extends View {
  init(_props, cx) {
    this.code = null;
    this.markdown = null;
    this.error = null;
    this.disk = null;      // the text last read from or written to the file; null: not editable
    this.dirty = false;
    this.stale = false;    // the file changed on disk under unsaved edits
    this.load(cx);
    const p = props();
    if (p?.file && !p.on) cx.spawn(async (cx) => {
      const dir = p.file.slice(0, p.file.lastIndexOf("/")) || "/";
      for (;;) {
        const changed = await watchFolder(dir).catch(() => null);
        if (!changed) return;
        if (changed.includes(p.file) || changed.includes(dir)) this.load(cx);
      }
    });
  }

  load(cx) {
    const p = props();
    if (!p?.file) { this.error = "No file"; return; }
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(p.file, { on: p.on ?? null });
        // Our own save, or a change elsewhere in the folder: keep the editor and its cursor.
        if (this.code && text !== null && text === this.disk) return;
        if (this.code && this.dirty && text !== null) { this.stale = true; return; }
        this.code?.release(); this.code = null; this.markdown = null; this.error = null;
        this.disk = null; this.dirty = false; this.stale = false;
        if (text === null) this.error = "This file is no longer available";
        else if (text.includes("\0")) this.error = "binary";
        else if (p.preview) this.markdown = text.length > LIMIT ? text.slice(0, LIMIT) + "\n\n… (file truncated)" : text;
        else {
          const t = theme(), name = p.file.split("/").pop(), ext = name.includes(".") ? name.split(".").pop() : "txt";
          const editable = !p.on && text.length <= LIMIT;
          if (editable) this.disk = text;
          this.code = EditorState.new({ language: LANG[ext] ?? ext, readonly: !editable, soft_wrap: true,
            value: text.length > LIMIT ? text.slice(0, LIMIT) + "\n… (file truncated)" : text,
            font_family: settings().font_family, font_size: 13,
            syntax: { keyword: t.ansi5, string: t.ansi2, comment: t.dim, function: t.ansi4, type: t.ansi3, number: t.ansi1, constant: t.ansi6 } });
          if (editable) this.code.on("change", (_e, cx) => {
            const dirty = this.code.value() !== this.disk;
            if (dirty !== this.dirty) { this.dirty = dirty; cx.notify(); }
          });
        }
      } catch { this.code = null; this.error = "binary"; }
      finally { cx.notify(); }
    });
  }

  // writeTextFile rejects when the file no longer matches this.disk, so a save never overwrites
  // a change made elsewhere.
  save(cx) {
    const p = props();
    if (!this.code || this.disk === null || !this.dirty) return;
    const text = this.code.value();
    cx.spawn(async (cx) => {
      try {
        await writeTextFile(p.file, text, this.disk);
        this.disk = text; this.dirty = this.code.value() !== text; this.stale = false;
      } catch (e) {
        this.stale = true;
        notify({ title: `Cannot save ${p.file.split("/").pop()}`, body: "The file changed on disk. Reload it from the header (your edits are lost) or copy them out first.", level: "error" });
      } finally { cx.notify(); }
    });
  }

  reload(cx) {
    this.code?.release(); this.code = null; this.disk = null; this.dirty = false; this.stale = false;
    this.load(cx);
  }

  render(cx) {
    const t = theme(), p = props() ?? {};
    const status = this.stale ? "Changed on disk — click to reload" : this.dirty ? "● Unsaved" : this.code && this.disk === null ? "Read-only" : "";
    const openButton = h_flex().id("fv-open").h(32).px(14).items_center().rounded(8).cursor_pointer()
      .bg(t.solid).text_color(t.solid_foreground).text_size(12.5).font_medium().hover(s => s.opacity(0.88))
      .on_click(() => exec("open", [p.file])).child("Open in default app");
    return v_flex().id("file-view").on_key_down((e, cx) => {
        if (e.key === "s" && (e.modifiers.platform || e.modifiers.control) && !e.modifiers.shift && !e.modifiers.alt) { this.save(cx); cx.stop_propagation(); }
      }).size_full().min_h(0).bg(t.background).text_color(t.foreground).text_size(13)
      .child(h_flex().h(34).flex_none().px(14).items_center().border_b(1).border_color(t.border)
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(p.file ?? ""))
        .when(Boolean(status), el => el.child(div().id("fv-status").flex_none().ml(12).text_size(12)
          .text_color(this.stale ? t.ansi1 : t.dim).when(this.stale, s => s.cursor_pointer().on_click((_e, cx) => this.reload(cx)))
          .child(status))))
      .child(this.markdown !== null ? div().id("fv-md-scroll").flex_1().min_h(0).overflow_y_scrollbar().px(32).py(24)
          .child(div().max_w(860).text_size(14).child(TextView.markdown("fv-md", this.markdown).selectable(true)))
        : this.code ? Editor.new(this.code).flex_1().min_h(0)
        : v_flex().flex_1().items_center().justify_center().gap(12).text_color(t.dim)
          .child(div().child(this.error === "binary" ? "No text preview for this file" : this.error ?? "Loading file…"))
          .when(this.error === "binary" && !p.on, el => el.child(openButton)));
  }
}
