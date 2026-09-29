# Omarchy System Monitor

CPU, memory, GPU, disk and network at a glance in the Omarchy bar. A compact
two-row label lives in the bar; click it for the full breakdown.

<p align="center"><img src="preview.png" alt="System monitor panel in the Omarchy bar" width="480"></p>

## Features

- **Bar label you choose.** Three layouts:
  - **Stacked** (default): two small rows in one bar slot, each showing CPU,
    memory, GPU, root disk or CPU temperature, with download and upload
    beside them
  - **One line**: both figures and the rates on one line at the bar's font
    size
  - **Compact**: just the top figure
- **Settings screen in the panel.** Press **Settings** (or `s`) to choose the
  layout, the figures, the network rates and the warning limits. Changes
  save at once and the bar updates live.
- **Warnings on the bar.** A row turns your theme's urgent colour when its
  part runs hot or fills up; if the problem is not on the bar, the whole
  block does. Hover it to see what is wrong. It warns on:
  - CPU or GPU temperature at or above `warnTemp` (85 °C)
  - memory, or any filesystem, at or above `warnUsage` (90%) full
  - an NVMe drive at or above its own rated temperature limit
- **Panel breakdown.**
  - **CPU:** total load, a 2-minute history graph, per-core bars, load
    average, temperature, uptime
  - **Memory:** RAM and swap in use
  - **GPU:** load, temperature, power, VRAM and a 2-minute history graph for
    NVIDIA and AMD cards, including integrated Radeon graphics
  - **Network:** download and upload, a 2-minute graph (download up, upload
    down), per interface when more than one is up
  - **Disk:** read and write rates, space used per filesystem, NVMe
    temperatures
  - **Processes:** the top 5 by CPU and by memory
- **Busy cores turn red** above 85%.
- **One step to btop.** The **Process monitor** button, Enter in the panel, or
  right-clicking the bar label opens btop.
- **Follows your theme.** Built from the stock Omarchy panel parts.
- **Close to free.** The data script reads `/proc` and `/sys` without starting
  a process each tick. With the panel closed it uses about 60 ms of CPU per
  minute and runs no `nvidia-smi` and no process scan.

## Requirements

- [Omarchy](https://omarchy.org) with the Quickshell-based Omarchy shell
- `bash`, `coreutils`, `gawk` (present on every Omarchy install)
- Optional: `nvidia-utils` for NVIDIA GPU stats (`nvidia-smi`). AMD GPUs need
  nothing extra. Intel GPUs are not shown.
- Optional: `btop` for the **Process monitor** button (ships with Omarchy)

## Install

```sh
omarchy plugin add https://github.com/navjottomer/omarchy-sysmon.git --enable
```

This clones the plugin into `~/.config/omarchy/plugins/navjottomer.sysmon/`,
validates it and puts it on the bar.

## Update

```sh
omarchy plugin update navjottomer.sysmon
```

## Remove

```sh
omarchy plugin remove navjottomer.sysmon
```

Nothing else is left behind.

## Usage

| Action | Result |
|---|---|
| click the bar label | open or close the panel |
| right-click the bar label | open btop |
| Enter in the panel | open btop |
| ← → then Enter | pick **Process monitor** or **Settings** |
| s | open or close the settings screen |
| ↑ ↓ on Settings | pick a setting |
| ← → on Settings | change it |
| Tab / Shift+Tab | switch to the next bar panel |
| Esc | close (on Settings: back to the stats) |

## Settings

Change them on the panel's **Settings** screen, or with
`omarchy bar set navjottomer.sysmon <key> <value>`:

| Key | Default | Meaning |
|---|---|---|
| `barLayout` | `stacked` | `stacked`, `line` or `compact` |
| `barTop` | `cpu` | top bar row: `cpu`, `memory`, `gpu`, `disk` or `temperature` |
| `barBottom` | `disk` | bottom bar row, same choices |
| `barNetwork` | `true` | show download and upload rates on the bar |
| `warnTemp` | `85` | CPU or GPU temperature (°C) that turns the bar red |
| `warnUsage` | `90` | memory or disk use (%) that turns the bar red |

`disk` is the root filesystem. `gpu` is the first GPU found (NVIDIA first).
Showing `gpu` on the bar keeps `nvidia-smi` running with the panel closed.

## How it works

`bin/omarchy-bar-sysmon` is one long-lived Bash process. Every 2 seconds it
prints one JSON line of raw numbers; the panel builds the bar label, the
warnings and the graphs from them. It waits between ticks with a timed read
on its input instead of `sleep`, and exits when the panel goes away.

- **CPU, memory, network, disk I/O, NVMe temperatures, AMD GPUs** come from
  `/proc` and `/sys`, read with Bash built-ins. A normal tick starts no new
  process. Rates use the measured time between ticks.
- **Disk space** comes from `df`, run about every 30 seconds.
- **Only while the panel is open.** The panel tells the script when it opens
  and closes. While open, the script also:
  - reads `/proc/<pid>/stat` for the top processes (about 0.7 s of CPU per
    minute, only while open);
  - runs one `nvidia-smi` in its own loop mode for NVIDIA GPUs, which have no
    `/sys` counters. It stops 60 seconds after the panel closes, which saves
    about 28 MB. Put `gpu` on the bar to keep it running.
- **History** for the graphs is 60 samples (2 minutes) kept in the panel, so
  the graphs are full as soon as it opens.
- **No double counting.** VPN, container and bridge interfaces are
  skipped so traffic is not counted twice; only whole disks count toward I/O.

- **Bounded records.** At most 16 mounts, 16 interfaces, 8 GPUs, 8 drives and
  5 processes per list, names clipped to 64 characters, and each record
  capped at 32 KB (lists are dropped from a record that would exceed it). All system-supplied text is
  shown as plain text, never as markup.

While the panel is closed, a tick costs the shell the bar label and three
short history lists; the detail rows update only while the panel is open.

## Development notes

- `Panel.qml` is the whole widget. It extends `qs.Ui/Panel`, which is what
  makes the bar paint its accent open-panel mark under it — a plain bar module
  cannot get that mark by styling alone.
- Glyphs are supplementary-plane (U+F0000+). Write them with `chr(0x…)` from a
  script; pasting them through a shell heredoc can split them and give tofu.
- The label is two rows (one `Text` each, so a warning can colour one row)
  in a 26 px slot. `verticalCenterOffset` lifts it clear of the open-panel
  mark painted over the bottom 4 px.
- If an edit does not show up, run `omarchy restart shell`.

## License

[MIT](LICENSE)
