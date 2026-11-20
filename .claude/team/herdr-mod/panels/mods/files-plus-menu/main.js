// Right-click menu for a files-plus tree row. Opened as a popup with
// props { root, path?, name?, dir?, on }: root is the tree's folder, path the absolute path of
// the clicked entry (absent: empty space was clicked), on the machine (null: this computer).
// Enter runs the selected item, Esc closes. Files go to the macOS Trash, never rm.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { props, closeOverlay, openOverlay, theme, exec, notify, spaces, panes, run } from "herdr";

async function moveToTrash(p) {
  const r = await exec("/usr/bin/trash", [p.path], { on: p.on ?? null });
  if (r.code === 0) notify({ title: `Moved to Trash: ${p.name}`, level: "success", timeout: 4000 });
  else notify({ title: `Cannot move ${p.name} to Trash`, body: (r.stderr || r.stdout || "").trim(), level: "error" });
}

async function reveal(p) {
  const r = await exec("open", ["-R", p.path]);
  if (r.code !== 0) notify({ title: `Cannot reveal ${p.name}`, body: (r.stderr || "").trim(), level: "error" });
}

// The clipboard is always this computer's, even for a file on another machine.
async function copyPath(p) {
  const r = await exec("sh", ["-c", 'printf %s "$1" | pbcopy', "copy-path", p.path]);
  if (r.code === 0) notify({ title: "Path copied", body: p.path, level: "info", timeout: 3000 });
  else notify({ title: "Cannot copy path", body: (r.stderr || "").trim(), level: "error" });
}

const parentOf = (path) => path.slice(0, path.lastIndexOf("/")) || "/";
const nameDialog = (dialogProps) => openOverlay({ mod: "files-plus-name", kind: "dialog", width: 420, height: 230, props: dialogProps });

function rename(p) {
  nameDialog({ mode: "rename", folder: parentOf(p.path), name: p.name, on: p.on ?? null });
}

// New entries go inside a right-clicked folder, beside a right-clicked file, or in the root.
const targetFolder = (p) => !p.path ? p.root : p.dir ? p.path : parentOf(p.path);

function create(mode) {
  return (p) => nameDialog({ mode, folder: targetFolder(p), on: p.on ?? null });
}

// Puts a file URL on the macOS pasteboard, as Finder's Copy does, so ⌘V works in Finder.
const PASTEBOARD = 'ObjC.import("AppKit"); function run(argv) { const pb = $.NSPasteboard.generalPasteboard; pb.clearContents; return pb.writeObjects($(argv.map(p => $.NSURL.fileURLWithPath(p)))); }';

async function copyEntry(p) {
  const r = await exec("osascript", ["-l", "JavaScript", "-e", PASTEBOARD, p.path]);
  if (r.code === 0) notify({ title: `Copied ${p.name}`, body: "Paste with ⌘V in Finder", level: "info", timeout: 3000 });
  else notify({ title: `Cannot copy ${p.name}`, body: (r.stderr || "").trim(), level: "error" });
}

// Finder only sees this computer, so Reveal is hidden for remote files.
// Without a path (right-click on empty space) only the New items apply.
const items = (p) => {
  const preview = p?.path && !p.dir ? previewFor(p) : null;
  return [
    ...(preview ? [{ label: "Preview", icon: "eye", run: preview }] : []),
    ...baseItems(p, Boolean(preview)),
  ];
};

// Markdown renders in a herdr tab; HTML needs CSS and scripts, so it goes to the default browser.
function previewFor(p) {
  const ext = p.name.toLowerCase().split(".").pop();
  if (ext === "md" || ext === "markdown") return previewMarkdown;
  if ((ext === "html" || ext === "htm") && !p.on) return previewHtml;
  return null;
}

function previewMarkdown(p) {
  const name = `Preview ${p.name}`, space = spaces().find(s => s.active);
  const viewers = new Set(panes().filter(x => x.mod === "file-view").map(x => x.tab));
  const open = space?.tabs.find(tab => tab.name === name && viewers.has(tab.id));
  if (open) run("tab.select", { id: open.id });
  else run("tab.new", { name, mod: "file-view", props: { file: p.path, on: p.on ?? null, preview: true } });
}

async function previewHtml(p) {
  const r = await exec("open", [p.path]);
  if (r.code !== 0) notify({ title: `Cannot open ${p.name}`, body: (r.stderr || "").trim(), level: "error" });
}

const baseItems = (p, afterPreview) => [
  { label: "New file", icon: "file-plus", separator: afterPreview, run: create("file") },
  { label: "New folder", icon: "folder-plus", run: create("folder") },
  ...(!p?.path ? [] : [
    // Finder can't reach another machine's files: Reveal and Copy are for this computer only.
    ...(p.on ? [] : [
      { label: "Reveal in Finder", icon: "folder-search", separator: true, run: reveal },
      { label: "Copy", icon: "files", run: copyEntry },
    ]),
    { label: "Copy path", icon: "copy", separator: Boolean(p.on), run: copyPath },
    { label: "Rename", icon: "pencil", run: rename },
    { label: "Move to Trash", icon: "trash-2", danger: true, separator: true, run: moveToTrash },
  ]),
];

export default class FilesMenu extends View {
  init(_props, cx) {
    this.at = 0;
    this.handle = cx.focus_handle();
    this.handle.focus();
  }

  choose(i) {
    const p = props(), it = items(p)[i];
    closeOverlay(p?.overlay);
    if (it && (p?.path || p?.root)) it.run(p);
  }

  render(cx) {
    const t = theme(), ITEMS = items(props());
    return v_flex().id("files-menu").track_focus(this.handle).w_full().min_h(0).p(5).bg(t.popover).text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % ITEMS.length;
        else if (e.key === "up") this.at = (this.at + ITEMS.length - 1) % ITEMS.length;
        else if (e.key === "enter") this.choose(this.at);
        else if (e.key === "escape") closeOverlay(props()?.overlay);
        else return;
        cx.notify();
      })
      .children(ITEMS.flatMap((it, i) => [
        ...(it.separator && i > 0 ? [div().mx(7).my(4).h(1).bg(t.border)] : []),
        h_flex().id(`fmi-${i}`).h(31).px(8).gap(9).rounded(7).items_center()
        .text_color(it.danger ? t.ansi1 : t.foreground)
        .when(i === this.at, el => el.bg(t.selected))
        .hover(s => s.bg(t.hover))
        .on_click(() => this.choose(i))
        .child(svg(`mods/files-plus-menu/${it.icon}.svg`).size(14).flex_none().text_color(it.danger ? t.ansi1 : t.muted))
        .child(div().flex_1().child(it.label))]));
  }
}
