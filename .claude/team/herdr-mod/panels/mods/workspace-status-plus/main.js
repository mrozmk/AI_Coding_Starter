// Derived from Herdr's shipped "workspace-status" mod (Apache License 2.0); modified. Notices: NOTICE.md of the starter's Herdr panels kit.
// Status bar: machine, the shown space's branch (click it to switch branch), agent count.
// The branch list is this mod again, opened as a dialog with props { branches: true, space }.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { spaces, agents, panes, theme, run, window, keys, exec, props, openOverlay, closeOverlay } from "herdr";

const SEP = "\u001f";
const FORMAT = ["%(refname)", "%(refname:short)", "%(upstream:track,nobracket)", "%(committerdate:relative)",
  "%(authorname)", "%(objectname:short)", "%(subject)"].join(SEP);

// The space's tabs' panes; where its git is: its first terminal's live folder, else where it was made.
const ownPanes = (s) => { const tabs = new Set(s.tabs.map((t) => t.id)); return panes().filter((p) => tabs.has(p.tab)); };
const place = (s) => ownPanes(s).find((p) => p.cwd)?.cwd || s.folder;
// Switching changes files under any agent working in that tree, so it waits until none is.
const busy = (s) => ownPanes(s).some((p) => p.status === "working");

// Local branches, then remote ones that have no local branch of the same name; newest commit first.
function parse(stdout) {
  const rows = stdout.split("\n").filter(Boolean).map((line) => {
    const [ref, name, track, when, author, sha, subject] = line.split(SEP);
    return {
      ref, name, when, author, sha, subject,
      remote: ref.startsWith("refs/remotes/"),
      ahead: Number(/ahead (\d+)/.exec(track)?.[1] ?? 0),
      behind: Number(/behind (\d+)/.exec(track)?.[1] ?? 0),
      gone: track === "gone",
    };
  });
  const local = new Set(rows.filter((r) => !r.remote).map((r) => r.name));
  return rows.filter((r) => !r.remote || (!r.ref.endsWith("/HEAD") && !local.has(r.name.replace(/^[^/]+\//, ""))));
}

export default class WorkspaceStatus extends View {
  init(_props, cx) {
    if (!props()?.branches) return;
    this.state = "loading"; // loading | ready | none
    this.error = null;
    this.switching = null;
    cx.spawn(async (cx) => {
      const s = spaces().find((x) => x.id === props().space);
      try {
        const r = await exec("git", ["for-each-ref", "--sort=-committerdate", `--format=${FORMAT}`, "refs/heads", "refs/remotes"], { cwd: place(s), on: s?.machine ?? null });
        this.branches = r.code === 0 ? parse(r.stdout) : [];
        this.state = r.code === 0 ? "ready" : "none";
      } catch { this.state = "none"; }
      cx.notify();
    });
  }

  // The palette key as actually bound, not a hardcoded one; without a
  // binding the hint stays useful ("commands") instead of lying.
  hint(t) {
    const mac = window()?.platform === "macos";
    const mod = { cmd: mac ? "⌘" : "Ctrl+", ctrl: mac ? "⌃" : "Ctrl+", shift: mac ? "⇧" : "Shift+", alt: mac ? "⌥" : "Alt+", option: mac ? "⌥" : "Alt+" };
    const b = keys().find((k) => k.section === "global" && k.action === "app.palette");
    const parts = b && b.keys.endsWith("--") ? [...b.keys.slice(0, -2).split("-"), "-"] : b?.keys.split("-");
    const key = parts && parts.map((p) => mod[p.toLowerCase()] ?? p.toUpperCase()).join("");
    return key ? `${key}  commands` : "commands";
  }

  switchTo(b, s, cx) {
    if (busy(s)) { this.error = "An agent is working in this space. Switch when it stops."; cx.notify(); return; }
    // A remote branch: "origin/x" -> "x", which git creates as a local branch tracking it.
    const target = b.remote ? b.name.replace(/^[^/]+\//, "") : b.name;
    this.switching = b.ref;
    this.error = null;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("git", ["switch", target], { cwd: place(s), on: s.machine ?? null });
        if (r.code === 0) { closeOverlay(props().overlay); return; }
        // git's own words: uncommitted changes in the way, and so on. Nothing is stashed.
        this.error = (r.stderr || r.stdout).trim().split("\n").slice(0, 6).join("\n");
      } catch (e) { this.error = String(e?.message ?? e); }
      this.switching = null;
      cx.notify();
    });
  }

  branchRow(t, b, s, current, locked) {
    const on = !b.remote && b.name === current;
    const can = !on && !locked && !this.switching;
    return v_flex()
      .id(`br-${b.ref}`)
      .px(10).py(6).gap(2).rounded(7).flex_none()
      .when(on, (el) => el.bg(t.selected))
      .when(can, (el) => el.cursor_pointer().hover((x) => x.bg(t.hover)).on_click((_e, cx) => this.switchTo(b, s, cx)))
      .when(this.switching === b.ref, (el) => el.opacity(0.6))
      .child(h_flex().gap(7).items_center()
        .child(svg(`mods/workspace-chrome/${on ? "check" : "branch"}.svg`).size(13).flex_none().text_color(on ? t.foreground : t.muted))
        .child(div().min_w(0).truncate().text_color(t.foreground).when(on, (el) => el.font_semibold()).child(b.name))
        .when(b.behind > 0 || b.ahead > 0, (el) => el.child(div().flex_none().text_color(t.muted).child(`${b.behind}↓ ${b.ahead}↑`)))
        .when(b.gone, (el) => el.child(div().flex_none().text_color(t.dim).child("gone")))
        .child(div().flex_none().text_color(t.dim).child(b.when)))
      .child(div().pl(20).truncate().text_size(11.5).text_color(t.dim).child(`${b.author} • ${b.sha} • ${b.subject}`));
  }

  branchList(t) {
    const s = spaces().find((x) => x.id === props().space);
    if (!s) return div().p(16).child("This space is gone.");
    const locked = busy(s);
    const body = this.state === "loading" ? [div().p(12).text_color(t.dim).child("Loading branches…")]
      : this.state === "none" ? [div().p(12).text_color(t.dim).child("Not a git repository.")]
      : this.branches.map((b) => this.branchRow(t, b, s, s.branch, locked));
    return v_flex().size_full().min_h(0).bg(t.popover).text_size(13).p(8).gap(6)
      .child(h_flex().px(10).pt(4).gap(8).items_center()
        .child(div().font_semibold().text_color(t.foreground).child("Switch branch"))
        .child(div().flex_1().truncate().text_color(t.dim).child(s.name))
        .child(div().id("br-close").px(6).rounded(5).text_color(t.muted).cursor_pointer()
          .hover((x) => x.bg(t.hover).text_color(t.foreground))
          .on_click(() => closeOverlay(props().overlay)).child("✕")))
      .when(locked, (el) => el.child(div().mx(10).text_size(12).text_color(t.blocked)
        .child("An agent is working in this space. Branches can be switched once it stops.")))
      .when(Boolean(this.error), (el) => el.child(div().mx(10).p(8).rounded(6).bg(t.blocked + "1a")
        .text_size(12).text_color(t.blocked).whitespace_normal().child(this.error)))
      .child(v_flex().id("br-list").flex_1().min_h(0).overflow_y_scrollbar().mode("always").children(body));
  }

  render() {
    const t = theme();
    if (props()?.branches) return this.branchList(t);
    const space = spaces().find(s => s.active);
    const list = agents();
    const needs = list.filter(a => a.status === "blocked").length;
    const label = (icon, text) => h_flex().gap(6).items_center().child(svg(`mods/workspace-chrome/${icon}.svg`).size(13)).child(text);
    return h_flex().size_full().px(14).gap(16).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(label(space?.machine ? "server" : "monitor", space?.machine ?? "This computer"))
      .when(Boolean(space?.branch), el => el.child(div().id("branch").px(4).rounded(4).cursor_pointer()
        .hover(s => s.bg(t.hover).text_color(t.foreground))
        .tooltip("Switch branch")
        .on_click(() => openOverlay({ mod: "workspace-status-plus", kind: "dialog", width: 640, height: 0.6, props: { branches: true, space: space.id } }))
        .child(label("branch", space.branch))))
      .child(h_flex().gap(6).items_center().child(div().size(6).rounded(3).bg(t.dim)).child(`${list.length} agents`)
        .when(needs > 0, el => el.child(div().text_color(t.blocked).child(`· ${needs} needs you`))))
      .child(div().flex_1())
      .child(div().id("palette").text_color(t.dim).on_click(() => run("app.palette")).child(this.hint(t)));
  }
}
