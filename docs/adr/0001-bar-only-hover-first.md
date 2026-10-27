# ADR-0001: Bar-only, hover-first, config-only SysMon

Status: Proposed
Date: 2026-10-27

## Context

SysMon currently ships a bar widget plus a full panel (`Panel.qml`, `tabs/`,
`components/`, `MemRing.qml`, `collector.py`). Argus already covers the deep
panel comprehensively — persistent history, alerts with context snapshots,
MangoHud, battery/power tabs, SMART via udisks2, fixture-tested parsing.
Maintaining a thinner duplicate panel costs upkeep and dilutes SysMon's
identity. Meanwhile SysMon's bar already has hover tooltips and threshold
coloring (`stateColor`: ≥60 amber, ≥80 red).

## Decision

Reduce SysMon to the bar surface only:

- Keep `SysMon.qml`, `SysMonCore.qml`, `Model.js`, `manifest.json`.
- Remove panel loading and the panel/tab/component/collector files.
- Hover tooltips are the primary detail surface; click is optional.
- All configuration comes from the manifest schema
  (`~/.config/omarchy/shell.json`), no in-app settings UI.
- Optional rich hover (sparklines) via a small `PopupWindow`, only if needed.

## Consequences

Positive:

- Small, auditable codebase (4 files); cheap to maintain.
- Clear niche versus Argus: minimal, hover-first, no panel.
- Bar sampling stays fork-light and in-process; no Python.

Negative:

- Users lose disk/SMART/process detail in SysMon; Argus owns that depth.
- Rich hover graphs need a custom popup; Wayland hover UX is finicky
  (edge clamping, dismiss-on-leave).
- Migration cost: document the removal; keep the panel in git history.

## Alternatives considered

1. Keep the panel and compete with Argus — rejected: duplication and upkeep.
2. Ship panel as optional second mode — rejected for v1: two code paths,
   unclear identity; revisit only if bar-only gets traction.
3. Contribute panel features upstream to Argus — pursued separately as a
   narrow PR (segmented pills + config schema); does not fix SysMon identity.

## Validation

- Default install renders identically to current bar.
- Hover tooltips still show CPU model, mem used/total, temp °C/°F, disk used/total.
- No extra processes or sampling ticks; `show: []` renders nothing.
- Every bar setting is readable from `shell.json` and listed in `manifest.json`.