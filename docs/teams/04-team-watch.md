# 04 — Signals and monitoring

> **Stub.** This page waits for the team-watch layer (daemon, routing, wake loops). Its names are
> not frozen yet, so it holds no prose. It is written when that layer merges.

TODO:

- signal kinds and the open-interval rule
- routing `split` / `single Supervisor` (the single-window flow) and the atomic handover
- receivers, `ack` first / `done` last, the alarms (`UNPICKED`, `STALLED`, `RECEIVER down`,
  `UNDELIVERED`, `MONITOR`) and the terminal rule
- the delivery boundary: a transport success is not a pickup
- wake loops, pause/start, the overnight routine
- env knobs regenerated from the scripts, never copied from the source list

Until then: [README](README.md) · [Team pipeline](03-team-pipeline.md).
