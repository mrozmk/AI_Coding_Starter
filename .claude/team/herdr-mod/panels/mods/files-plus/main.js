// Derived from Herdr's shipped "files" mod (Apache License 2.0); modified. Notices: NOTICE.md of the starter's Herdr panels kit.
// A lazy file browser for the focused pane's folder, with bounded read-only previews.
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, Editor, EditorState } from "gpui-base";
import { spaces, panes, focused, exec, readTextFile, watchFolder, theme, settings, window, openOverlay, run, notify } from "herdr";

// A focused mod pane (a file-view tab) has no folder: keep showing the last one in that space.
const lastLocation = new Map();
function location() {
  const loc = currentLocation();
  if (loc.mod) return lastLocation.get(loc.space) ?? { cwd: loc.cwd, on: loc.on, space: loc.space };
  lastLocation.set(loc.space, loc);
  return loc;
}
function currentLocation() {
  const space = spaces().find(s => s.active), f = focused();
  const pane = f?.pane ? panes().find(p => p.pane === f.pane) : null;
  if (pane?.mod) {
    // Fallback before anything was remembered: a terminal's live folder in this space.
    const tabs = new Set((space?.tabs ?? []).map(c => c.id));
    const shell = panes().find(p => tabs.has(p.tab) && p.cwd);
    return { mod: true, cwd: shell?.cwd || space?.folder, on: space?.machine ?? null, space: space?.id };
  }
  const on = f?.pane === null ? (f.terminal?.includes("/") ? f.terminal.split("/")[0] : null) : space?.machine ?? null;
  return { cwd: pane?.cwd || f?.cwd || space?.folder, on, space: space?.id };
}
const key = () => JSON.stringify(location());
const LANG = { ts: "js", tsx: "js", mts: "js", cts: "js", jsx: "js", mjs: "js", toml: "yaml", jsonc: "json", svelte: "html", vue: "html" };
const PER_FOLDER = 500, TOTAL = 5000;

// File-type icons (Lucide) and their colors; colors come from the theme's ANSI palette.
const ORANGE = "#d19a66";
const BY_EXT = {
  md: ["file-text", "ansi6"], markdown: ["file-text", "ansi6"],
  py: ["file-code", "ansi3"], js: ["file-code", "ansi3"], mjs: ["file-code", "ansi3"], cjs: ["file-code", "ansi3"], jsx: ["file-code", "ansi3"],
  ts: ["file-code", "ansi4"], tsx: ["file-code", "ansi4"], mts: ["file-code", "ansi4"],
  html: ["file-code", ORANGE], css: ["file-code", "ansi4"],
  json: ["file-json", ORANGE], jsonc: ["file-json", ORANGE],
  sh: ["file-terminal", "ansi2"], bash: ["file-terminal", "ansi2"], zsh: ["file-terminal", "ansi2"], fish: ["file-terminal", "ansi2"],
  env: ["file-lock", "ansi1"],
  toml: ["file-cog", "ansi5"], yaml: ["file-cog", "ansi5"], yml: ["file-cog", "ansi5"], ini: ["file-cog", "ansi5"], cfg: ["file-cog", "ansi5"], conf: ["file-cog", "ansi5"],
  gitignore: ["file-cog", "ansi5"], editorconfig: ["file-cog", "ansi5"], gitattributes: ["file-cog", "ansi5"],
  png: ["file-image", "ansi5"], jpg: ["file-image", "ansi5"], jpeg: ["file-image", "ansi5"], gif: ["file-image", "ansi5"], webp: ["file-image", "ansi5"], svg: ["file-image", "ansi5"], ico: ["file-image", "ansi5"],
  pdf: ["file-text", "ansi1"],
  zip: ["file-archive", ORANGE], tar: ["file-archive", ORANGE], gz: ["file-archive", ORANGE], tgz: ["file-archive", ORANGE], "7z": ["file-archive", ORANGE], rar: ["file-archive", ORANGE],
};
// Opens a file in its own tab (file-view), or shows the tab already showing it in this space.
// A tab is matched by name (the file name) and by holding a file-view pane.
// Files dropped from Finder are copied, never moved. A taken name becomes "name copy.ext",
// then "name copy 2.ext" (as in Finder and files-plus-menu's Paste); prints the final name.
const COPY_INTO = `src=$1 dir=$2; name=\${src##*/}; base=$name; ext=
if [ ! -d "$src" ]; then case "$name" in ?*.*) ext=".\${name##*.}"; base=\${name%.*};; esac; fi
dest="$dir/$name"; n=1
while [ -e "$dest" ] || [ -L "$dest" ]; do
  if [ $n = 1 ]; then dest="$dir/$base copy$ext"; else dest="$dir/$base copy $n$ext"; fi; n=$((n+1))
done
cp -Rp -- "$src" "$dest" && printf %s "\${dest##*/}"`;

let lastDrop = { paths: "", at: 0 };
async function dropInto(dir, paths, on) {
  // A drop can reach both a row and the tree under it; copy it once (the row comes first).
  const key = paths.join("\n"), now = Date.now();
  if (key === lastDrop.paths && now - lastDrop.at < 1000) return;
  lastDrop = { paths: key, at: now };
  if (on) { notify({ title: "Drop works only for folders on this computer", level: "error" }); return; }
  const done = [], failed = [];
  for (const src of paths) {
    const name = src.split("/").pop();
    if (dir === src || dir.startsWith(`${src}/`)) { failed.push(`${name}: cannot copy a folder into itself`); continue; }
    const r = await exec("sh", ["-c", COPY_INTO, "drop", src, dir]);
    if (r.code === 0) done.push(r.stdout.trim()); else failed.push(`${name}: ${(r.stderr || "failed").trim()}`);
  }
  const where = dir.split("/").pop() || "/";
  if (done.length) notify({ title: done.length === 1 ? `Copied ${done[0]}` : `Copied ${done.length} items`, body: `Into ${where}`, level: "success", timeout: 3000 });
  if (failed.length) notify({ title: "Some items were not copied", body: failed.join("\n"), level: "error" });
}

function openFileTab(file, on) {
  const name = file.split("/").pop(), space = spaces().find(s => s.active);
  const viewers = new Set(panes().filter(p => p.mod === "file-view").map(p => p.tab));
  const open = space?.tabs.find(tab => tab.name === name && viewers.has(tab.id));
  if (open) run("tab.select", { id: open.id });
  else run("tab.new", { name, mod: "file-view", props: { file, on: on ?? null } });
}

// A folder's mark is the most serious one among the changed files anywhere inside it.
const SEVERITY = { A: 1, M: 2, D: 3, U: 4 };
function folderMarks(marks, top) {
  const out = {};
  for (const [file, mark] of Object.entries(marks)) {
    for (let dir = file.slice(0, file.lastIndexOf("/")); top && dir.length > top.length; dir = dir.slice(0, dir.lastIndexOf("/"))) {
      if ((SEVERITY[out[dir]] ?? 0) < SEVERITY[mark]) out[dir] = mark;
    }
  }
  return out;
}
const markColor = (mark, t) => mark === "A" ? t.ansi2 : mark === "D" || mark === "U" ? t.ansi1 : t.blocked;

const SUFFIXES = new Set(["example", "sample", "template", "tmpl", "dist", "bak", "orig", "old"]);
// Returns { icon, color, opacity } for one tree row.
function fileIcon(entry, open, t) {
  if (entry.dir) return { icon: open ? "folder-open" : "folder", color: t.ansi4, opacity: entry.name.startsWith(".") ? 0.55 : 1 };
  const name = entry.name.toLowerCase();
  if (name === ".ds_store") return { icon: "file", color: t.dim, opacity: 0.5 };
  if (name === "license" || name.startsWith("license.")) return { icon: "file-badge", color: t.ansi3, opacity: 1 };
  if (name === ".env" || name.startsWith(".env.")) return { icon: "file-lock", color: t.ansi1, opacity: 1 };
  // `.mcp.json.example` takes its icon from `.json`.
  const parts = name.split(".").slice(1);
  if (parts.length > 1 && SUFFIXES.has(parts[parts.length - 1])) parts.pop();
  const ext = parts.length ? parts[parts.length - 1] : "";
  const hit = BY_EXT[ext];
  if (!hit) return { icon: "file", color: t.muted, opacity: 1 };
  return { icon: hit[0], color: hit[1].startsWith("#") ? hit[1] : t[hit[1]], opacity: 1 };
}

async function directory(path, on) {
  const windowsDirectory = async () => {
    // Windows PowerShell otherwise uses the console code page; exec decodes UTF-8.
    // Links keep directory attributes even when dangling; check their target.
    // Other reparse points (OneDrive's folders) have no LinkType and are folders.
    // PowerShell reads curly single quotes as quotes too, so they're doubled like '.
    const r = await exec("powershell", ["-NoProfile", "-Command", "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); & { param($p) @(Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop | Where-Object Name -ne '.git' | Select-Object -First 501 | ForEach-Object { @{ name=$_.Name; dir=($_.PSIsContainer -and (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $_.LinkType -or ($_.Target -and [IO.Directory]::Exists(([IO.Path]::Combine([IO.Path]::GetDirectoryName($_.FullName), $_.Target[0])))))) } }) | ConvertTo-Json -Compress } '" + path.replace(/['‘’‚‛]/g, "$&$&") + "'"], { on });
    if (r.code !== 0) throw new Error(r.stderr || "Cannot list this folder");
    const result = JSON.parse(r.stdout || "[]");
    return Array.isArray(result) ? result : [result];
  };
  if (!on && window()?.platform === "windows") return windowsDirectory();
  const script = 'n=0; for p in "$1"/* "$1"/.[!.]* "$1"/..?*; do [ -e "$p" ] || [ -L "$p" ] || continue; name=${p##*/}; [ "$name" = .git ] && continue; if [ -d "$p" ]; then kind=d; else kind=f; fi; printf "%s\\0%s\\0" "$kind" "$name"; n=$((n+1)); [ "$n" -gt 500 ] && break; done; test -d "$1"';
  let r;
  try { r = await exec("sh", ["-c", script, "files", path], { on }); }
  catch (e) {
    if (on && String(e).includes("cannot start sh: program not found")) return windowsDirectory();
    throw e;
  }
  if (r.code !== 0) throw new Error(r.stderr || "Cannot list this folder");
  const fields = r.stdout.split("\0"), out = [];
  for (let i = 0; i + 1 < fields.length; i += 2) out.push({ name: fields[i + 1], dir: fields[i] === "d" });
  return out;
}

export default class Files extends View {
  init(_props, cx) {
    this.saved = new Map();
    this.entries = new Map(); this.folders = new Set(); this.pending = new Set(); this.marks = {};
    this.refresh(cx);
    cx.timer.every(10000, cx => this.refresh(cx));
  }

  watch(root, cx) {
    if (this.on || this.watched === root) return;
    this.watched = root;
    const context = this.context;
    cx.spawn(async cx => {
      try { while (this.context === context) { await watchFolder(root); if (this.current(context)) this.refresh(cx); } }
      catch { if (this.context === context) this.watched = null; }
    });
  }

  current(context) {
    return this.context === context && key() === context.key;
  }

  async loadFolder(path, context) {
    const { on, cwd: root } = context;
    const entries = await directory(path ? `${root}/${path}` : root, on);
    if (!this.current(context) || (path && !this.folders.has(path))) return;
    const used = [...this.entries.entries()].filter(([p]) => p !== path).reduce((n, [, e]) => n + e.length, 0);
    this.entries.set(path, entries.slice(0, Math.max(0, Math.min(PER_FOLDER, TOTAL - used))).sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name)));
    if (entries.length > PER_FOLDER || used + entries.length > TOTAL) this.limited = true;
  }

  refresh(cx) {
    const { cwd, on } = location(), next = key();
    if (next !== this.context?.key) {
      if (this.context) this.saved.set(this.context.key, { folders: this.folders, file: this.file });
      const saved = this.saved.get(next);
      this.context = { key: next, cwd, on }; this.root = cwd; this.on = on; this.entries = new Map(); this.folders = new Set(saved?.folders);
      this.pending = new Set(); this.marks = {}; this.show(null); this.watched = null; this.error = null; this.limited = false;
      this.loading = false;
      if (saved?.file) this.show(saved.file, cx);
    }
    if (!cwd || this.loading) return;
    const context = this.context;
    this.loading = true;
    this.limited = false;
    cx.spawn(async cx => {
      try {
        for (const path of ["", ...this.folders]) {
          if (!this.current(context)) return;
          await this.loadFolder(path, context);
        }
        const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd, on }).catch(() => null);
        const marks = {};
        if (top?.code === 0) {
          // Writes nothing under .git (index lock, fsmonitor cookie): the folder watch would refresh again.
          const status = await exec("git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"], { cwd, on }).catch(() => null);
          if (status?.code === 0) for (const entry of status.stdout.split("\0").filter(Boolean).slice(0, TOTAL)) {
            const xy = entry.slice(0, 2);
            marks[`${top.stdout.trim()}/${entry.slice(3)}`] = xy === "??" || xy.includes("A") ? "A" : xy.includes("U") ? "U" : xy.includes("D") ? "D" : "M";
          }
        }
        if (!this.current(context)) return;
        this.marks = marks; this.dirMarks = folderMarks(marks, top?.stdout.trim()); this.error = null; this.watch(cwd, cx);
      } catch (e) { if (this.current(context)) this.error = String(e); }
      finally { if (this.context === context) this.loading = false; cx.notify(); }
    });
  }

  toggle(path, cx) {
    if (this.folders.has(path)) {
      for (const folder of [...this.folders]) if (folder === path || folder.startsWith(path + "/")) {
        this.folders.delete(folder);
        this.entries.delete(folder);
      }
    } else {
      this.folders.add(path);
      if (!this.entries.has(path) && !this.pending.has(path)) {
        const context = this.context;
        this.pending.add(path);
        cx.spawn(async cx => {
          try { await this.loadFolder(path, context); }
          catch (e) { if (this.current(context)) this.error = String(e); }
          finally { if (this.context === context) this.pending.delete(path); cx.notify(); }
        });
      }
    }
    cx.notify();
  }

  show(path, cx) {
    this.code?.release(); this.code = null; this.file = path; this.fileError = null;
    if (!path || !cx) return;
    const context = this.context, root = this.root, on = this.on;
    cx.spawn(async cx => {
      try {
        const text = await readTextFile(`${root}/${path}`, { on });
        if (this.file !== path || !this.current(context)) return;
        if (text === null) { this.fileError = "This file is no longer available"; return; }
        if (text.includes("\0")) { this.fileError = "Binary file · no text preview"; return; }
        const t = theme(), ext = path.includes(".") ? path.split(".").pop() : "txt";
        this.code = EditorState.new({ language: LANG[ext] ?? ext, readonly: true,
          value: text.length > 400000 ? text.slice(0, 400000) + "\n… (file truncated)" : text,
          font_family: settings().font_family, font_size: 12,
          syntax: { keyword: t.ansi5, string: t.ansi2, comment: t.dim, function: t.ansi4, type: t.ansi3, number: t.ansi1, constant: t.ansi6 } });
      } catch { if (this.file === path && this.current(context)) this.fileError = "Cannot preview this file (binary, too large, or unreadable)"; }
      finally { cx.notify(); }
    });
  }

  rows(prefix, depth, out, t) {
    if (out.length >= TOTAL || depth > 40) return out;
    for (const entry of this.entries.get(prefix) ?? []) {
      if (out.length >= TOTAL) break;
      const path = prefix ? `${prefix}/${entry.name}` : entry.name, open = this.folders.has(path), mark = this.marks[`${this.root}/${path}`];
      const ic = fileIcon(entry, open, t), dirMark = this.dirMarks?.[`${this.root}/${path}`];
      out.push(h_flex().id(`file-${path}`).h(28).flex_none().pl(8 + depth * 18).pr(8).gap(7).items_center().rounded(7).cursor_pointer().hover(s => s.bg(t.hover))
        .on_click((_e, cx) => entry.dir ? this.toggle(path, cx) : openFileTab(`${this.root}/${path}`, this.on))
        .on_drop((e, cx) => {
          cx.stop_propagation();
          dropInto(entry.dir ? `${this.root}/${path}` : `${this.root}/${prefix}`.replace(/\/$/, ""), e.paths, this.on);
        })
        .on_mouse_down("right", (_e, cx) => {
          cx.stop_propagation();
          openOverlay({ mod: "files-plus-menu", kind: "popup", width: 190, props: { root: this.root, path: `${this.root}/${path}`, name: entry.name, dir: entry.dir, on: this.on } });
        })
        .child(entry.dir ? svg(`mods/files-plus/chevron-${open ? "down" : "right"}.svg`).size(12).flex_none().text_color(t.dim) : div().w(12).flex_none())
        .child(svg(`mods/files-plus/${ic.icon}.svg`).size(14).flex_none().text_color(ic.color).opacity(ic.opacity))
        .child(div().flex_1().min_w(0).truncate().child(entry.name))
        .when(Boolean(mark), el => el.child(div().text_size(11).text_color(markColor(mark, t)).child(mark)))
        .when(entry.dir && Boolean(dirMark), el => el.child(div().size(6).mr(2).flex_none().rounded(3).bg(markColor(dirMark, t)))));
      if (entry.dir && open) this.rows(path, depth + 1, out, t);
    }
    return out;
  }

  render(cx) {
    if (key() !== this.context?.key) this.refresh(cx);
    const t = theme();
    return v_flex().id("files").size_full().min_h(0).rounded(10).overflow_hidden().bg(t.background).border_1().border_color(t.border).text_color(t.foreground).text_size(13)
      .child(h_flex().h(42).flex_none().px(14).gap(8).items_center().border_b(1).border_color(t.border)
        .when(Boolean(this.file), el => el.child(div().id("files-back").w(20).cursor_pointer().text_color(t.muted).on_click((_e, cx) => { this.show(null); cx.notify(); }).child("←")))
        .child(div().font_semibold().child("Files"))
        .child(div().flex_1().min_w(0).truncate().text_right().text_size(12).text_color(t.dim).child(this.file ?? this.root?.split(/[\\/]/).pop() ?? "")))
      .when(!this.file, el => el.child(v_flex().id("files-tree").flex_1().min_h(0).overflow_y_scrollbar().p(6)
        .on_drop((e) => { if (this.root) dropInto(this.root, e.paths, this.on); })
        .on_mouse_down("right", () => { if (this.root) openOverlay({ mod: "files-plus-menu", kind: "popup", width: 190, props: { root: this.root, on: this.on } }); })
        .children(this.rows("", 0, [], t))
        .when(Boolean(this.error) || !this.entries.get("")?.length, el => el.child(div().p(8).text_size(12).text_color(t.dim).child(this.error || (this.loading ? "Loading files…" : this.root ? "No files" : "No folder"))))
        .when(this.limited, el => el.child(div().p(8).text_size(11).text_color(t.dim).child("File list limited to 500 entries per folder and 5,000 total")))))
      .when(Boolean(this.file), el => el.child(this.code ? Editor.new(this.code).flex_1().min_h(0) : div().p(12).text_color(t.dim).child(this.fileError || "Loading file…")));
  }
}
