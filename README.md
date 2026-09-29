# navjottomer.sysmon

CPU / memory / GPU / disk / network for the Omarchy bar. Click the bar label to open
the breakdown; right-click (or Enter in the panel) jumps straight to btop.

## Install

    omarchy plugin add https://github.com/navjottomer/omarchy-sysmon.git --enable

This clones it into `~/.config/omarchy/plugins/navjottomer.sysmon/`, validates it, and puts
it on the bar. Update later with `omarchy plugin update navjottomer.sysmon`, remove with
`omarchy plugin remove navjottomer.sysmon`.

## Shape

- `Panel.qml` — the whole widget. Extends `qs.Ui/Panel`, so it registers as a
  bar popout and the bar paints its `Color.accent` open-panel mark for free.
  That mark is the *only* reason the widget looks "selected" — `WidgetButton`
  and `BarIconButton` draw no hover border, so a plain custom module can never
  match the built-ins by styling alone. It has to own a panel.
- `bin/omarchy-bar-sysmon` — the data source. One
  long-lived process streaming a JSON line every 2s.

## Cost

The script's hot path only reads `/proc` and `/sys` and writes results through
`printf -v`, so a steady-state tick forks nothing — no `$( )` subshells, no
external binaries. `df` runs every 15th tick and `sleep` once per tick; that is
all. Measured over a 12s window: ~0ms CPU, against ~10ms for the earlier
version that used command substitution.

GPU: AMD load, VRAM and sensors are sysfs reads like the rest. NVIDIA has no
sysfs counters, so one long-lived `nvidia-smi -lms 2000` runs alongside
(~27 MB, ~0ms CPU per 12s) and the loop drains its latest line each tick,
still without forking. It is started with the script and killed with it.
With GPU sampling the script measures ~10ms CPU per 12s.

On the QML side, a tick while the panel is **closed** costs one property write.
`snapshot` holds the payload with nothing bound to it, and the detail
properties are only refreshed from it when the panel is open (see
`applySnapshot`). Repeaters are modelled on array *lengths*, not the arrays, so
delegates survive a tick and only their bindings re-evaluate — otherwise every
row would be destroyed and rebuilt every 2 seconds.

## Gotchas

- Glyphs are supplementary-plane (U+F0000+). Write them with `chr(0x…)` from a
  script; pasting them through a shell heredoc can split them into a BMP
  private-use char plus a hex digit and you get tofu.
- The bar label is two rows in a 26px slot. `verticalCenterOffset` lifts it
  clear of the open-panel mark, which is painted over the bottom 4px — without
  it the mark sits on the second row's descenders.
- Editing `Panel.qml` usually hot-reloads, but if a change does not appear run
  `omarchy restart shell`.
