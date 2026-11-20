// The Spaces "+" menu (spaces-plus). Opened as a popup with no props.
// Open: pick a folder in macOS's folder picker and open it as a space (or show the space
// already there). Create: a new space in ~/Desktop. ↑/↓ move, Enter runs, Esc closes.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { props, closeOverlay, theme, run } from "herdr";

// The work runs in spaces-plus: this popup closes before a folder is picked.
const openFolder = () => run("spaces-plus.open");
const createOnDesktop = () => run("spaces-plus.create");

const ITEMS = [
  { label: "Open…", icon: "folder-open", run: openFolder },
  { label: "Create", icon: "folder-plus", run: createOnDesktop },
];

export default class SpacesMenu extends View {
  init(_props, cx) {
    this.at = 0;
    this.handle = cx.focus_handle();
    this.handle.focus();
  }

  choose(i) {
    closeOverlay(props()?.overlay);
    ITEMS[i]?.run();
  }

  render(cx) {
    const t = theme();
    return v_flex().id("spaces-menu").track_focus(this.handle).w_full().min_h(0).p(5).bg(t.popover).text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % ITEMS.length;
        else if (e.key === "up") this.at = (this.at + ITEMS.length - 1) % ITEMS.length;
        else if (e.key === "enter") this.choose(this.at);
        else if (e.key === "escape") closeOverlay(props()?.overlay);
        else return;
        cx.notify();
      })
      .children(ITEMS.map((it, i) => h_flex().id(`smi-${i}`).h(31).px(8).gap(9).rounded(7).items_center()
        .text_color(t.foreground)
        .when(i === this.at, el => el.bg(t.selected))
        .hover(s => s.bg(t.hover))
        .on_click(() => this.choose(i))
        .child(svg(`mods/spaces-plus-menu/${it.icon}.svg`).size(14).flex_none().text_color(t.muted))
        .child(div().flex_1().child(it.label))));
  }
}
