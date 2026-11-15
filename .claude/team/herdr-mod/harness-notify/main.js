// harness-notify: the Herdr channel of the harness's Operator notifications (notify.sh writes the
// spool). It shows each new entry of ~/.agent-comms/outbox/herdr/new/ once as a toast through
// Herdr's own `toast` mod, keeps the ones not yet clicked in this strip, and moves the entry to
// done/. A click runs the entry's focus action (agent.focus on the answering session); "clear"
// drops every item (dealt with elsewhere); an item older than a day falls off by itself.
// It touches nothing else: no setting, no sound, no other mod. Logic: spool.js. README.md.
import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify, run, exec, readTextFile, watchFolder, home, theme } from "herdr";
import * as fs from "fs/promises";
import * as spool from "./spool.js";

const KEY = "harness-notify.waiting";

export default class HarnessNotify extends View {
  init(_props, cx) {
    this.d = spool.dirs(home());
    let saved = null;
    try { saved = localStorage.getItem(KEY); } catch { saved = null; }
    this.list = spool.expire(spool.load(saved ?? "[]"), Date.now());
    this.bad = new Set();   // ids already reported as unreadable, so a scan does not log them again
    this.scan(cx);
    this.beat();
    cx.timer.every(30000, (cx) => { this.scan(cx); this.watch(cx); });   // the fallback; restarts the watch
    cx.timer.every(60000, () => this.beat());       // notify.sh --check reads this heartbeat
    this.watch(cx);
  }

  // A failed watchFolder (new/ not there yet) ends this loop; the 30 s timer starts it again.
  watch(cx) {
    if (this.watching) return;
    this.watching = true;
    cx.spawn(async (cx) => {
      try {
        for (;;) { await watchFolder(this.d.new); this.scan(cx); }
      } catch { /* retried by the timer */ } finally { this.watching = false; }
    });
  }

  beat() { exec("touch", [this.d.alive]).catch(() => {}); }

  save() { try { localStorage.setItem(KEY, JSON.stringify(this.list)); } catch { /* per copy only */ } }

  async scan(cx) {
    // A change seen mid-scan is not dropped: the running scan goes round once more.
    if (this.scanning) { this.again = true; return; }
    this.scanning = true;
    try {
      do {
        this.again = false;
        let names = [];
        try { names = await fs.readdir(this.d.new); } catch { names = []; }
        const now = Date.now();
        for (const name of names.sort()) {
          const id = spool.idOf(name);
          if (!id) continue;
          let text = null;
          try { text = await readTextFile(`${this.d.new}/${name}`); } catch { text = null; }
          if (text === null) continue;   // gone meanwhile (another copy of the strip took it)
          const r = spool.parse(id, text, now);
          if (r.error && !this.bad.has(id)) { this.bad.add(id); console.log(`harness-notify: ${id} skipped — ${r.error}`); }
          // Move first, toast only on a move that worked: exec resolves on a failed mv too, and a
          // second copy of the strip (another layout or window) loses the race instead of toasting.
          const [cmd, args] = spool.moveArgs(home(), id);
          const moved = await exec(cmd, args).then((x) => x.code === 0, () => false);
          if (moved && !r.error && !r.stale) { notify(spool.toast(r.item)); this.list = spool.add(this.list, r.item); }
        }
        this.list = spool.expire(this.list, now);
      } while (this.again);
      this.save();
      cx.notify();
    } finally { this.scanning = false; }
  }

  open(item, cx) {
    if (item.action) run(item.action.name, item.action.args);
    this.list = spool.ack(this.list, item.id);
    this.save();
    cx.notify();
  }

  clear(cx) {
    this.list = [];   // dealt with elsewhere: in the stage's window, by iMessage
    this.save();
    cx.notify();
  }

  render(cx) {
    const t = theme();
    const strip = h_flex().id("harness-notify").size_full().px(10).gap(8).items_center().bg(t.panel ?? t.popover);
    if (!this.list.length) return strip.child(div().text_size(12).text_color(t.muted).child(spool.stripText([])));
    const first = this.list[0];
    // Two siblings, not nested, so a click on "clear" never also opens the first item.
    const item = h_flex().id("harness-notify-open").flex_1().gap(8).items_center().cursor_pointer()
      .hover((s) => s.bg(t.hover)).on_click((_e, cx) => this.open(first, cx))
      .child(div().size(8).rounded(4).flex_none().bg(t.working ?? t.accent))
      .child(div().flex_1().truncate().text_size(12).text_color(t.foreground).child(spool.stripText(this.list)));
    const clear = div().id("harness-notify-clear").flex_none().px(6).cursor_pointer().text_size(12)
      .text_color(t.muted).hover((s) => s.text_color(t.foreground)).on_click((_e, cx) => this.clear(cx))
      .child("clear");
    return strip.child(item).child(clear);
  }
}
