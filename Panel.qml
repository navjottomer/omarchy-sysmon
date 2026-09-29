import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Grouped CPU / memory / disk / network module. Fed by
// bin/omarchy-bar-sysmon (next to this file), which streams one JSON
// object per tick from a single long-lived, fork-free process. The bar shows
// the compact 2x2 label; clicking opens the breakdown, so this behaves like
// omarchy.audio and omarchy.bluetooth rather than a hover tooltip, and picks up
// the bar's accent open-panel mark for free.
Panel {
  id: root

  moduleName: "navjottomer.sysmon"
  ipcTarget: "navjottomer.sysmon"

  property string label: ""

  // Last payload off the stream. Nothing binds to it, so a tick costs one
  // property write while the panel is closed — the detail properties below are
  // only refreshed when there is something on screen to refresh.
  property var snapshot: null

  property var cpu: ({})
  property var mem: ({})
  property var net: ({})
  property var disk: ({})
  property int uptime: 0
  property var cores: []
  property var ifaces: []
  property var mounts: []
  property var gpus: []

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(barForeground, 1.4)

  // The label is a two-row block in a padded slot, so the open-panel mark would
  // otherwise span the whole slot. Point it at the painted text.
  readonly property real openPanelIndicatorWidth: button.vertical ? 0 : labelText.implicitWidth

  implicitWidth: label === "" ? 0 : button.implicitWidth
  implicitHeight: label === "" ? 0 : button.implicitHeight

  function num(obj, key, fallback) {
    var v = obj ? obj[key] : undefined
    return v === undefined || v === null ? fallback : v
  }

  // Mirrors rate() in the feeding script: four characters at most, so a column
  // of figures stays put instead of reflowing every time a number grows.
  // One decimal only where it carries information: 4.2G is worth saying, 30.0G
  // is not. Units sit tight against the figure, matching what df already
  // returns for the mount rows so the two read as one column.
  function scaled(v, unit) {
    return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + unit
  }

  function fmtRate(bytes) {
    var v = Number(bytes) || 0
    if (v < 1024) return v + "B/s"
    if (v < 1024 * 1024) return scaled(v / 1024, "K/s")
    if (v < 1024 * 1024 * 1024) return scaled(v / 1048576, "M/s")
    return scaled(v / 1073741824, "G/s")
  }

  function fmtBytes(bytes) {
    var v = Number(bytes) || 0
    if (v < 1024) return v + "B"
    if (v < 1024 * 1024) return scaled(v / 1024, "K")
    if (v < 1024 * 1024 * 1024) return scaled(v / 1048576, "M")
    return scaled(v / 1073741824, "G")
  }

  // "32%  ·  41°C  ·  12W", skipping any figure the driver did not report.
  function gpuSummary(g) {
    var parts = [(g.pct === null || g.pct === undefined ? "—" : g.pct) + "%"]
    if (g.temp !== null && g.temp !== undefined) parts.push(g.temp + "°C")
    if (g.power) parts.push(g.power + "W")
    return parts.join("  ·  ")
  }

  function fmtUptime(seconds) {
    var s = Number(seconds) || 0
    var d = Math.floor(s / 86400)
    var h = Math.floor((s % 86400) / 3600)
    var m = Math.floor((s % 3600) / 60)
    if (d > 0) return "up " + d + "d " + h + "h"
    if (h > 0) return "up " + h + "h " + m + "m"
    return "up " + m + "m"
  }

  function applySnapshot() {
    var d = snapshot
    if (!d) return
    cpu = d.cpu || ({})
    mem = d.mem || ({})
    net = d.net || ({})
    disk = d.disk || ({})
    uptime = d.uptime || 0
    cores = (d.cpu && d.cpu.cores) || []
    ifaces = (d.net && d.net.ifaces) || []
    mounts = (d.disk && d.disk.mounts) || []
    gpus = d.gpus || []
  }

  onOpenedChanged: if (opened) applySnapshot()

  function openProcessMonitor() {
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
    close()
  }

  // One "icon key .... value" line. The icon column is a fixed width so the
  // keys line up whether or not a row has a glyph.
  component StatRow: Item {
    id: statRow

    property string icon: ""
    property string key: ""
    property string value: ""
    property color valueColor: root.barForeground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(leftGroup.implicitHeight, valueText.implicitHeight)

    Row {
      id: leftGroup
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        width: Style.space(13)
        horizontalAlignment: Text.AlignHCenter
        text: statRow.icon
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        text: statRow.key
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: statRow.value
      color: statRow.valueColor
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }

  Process {
    running: true
    command: [String(Qt.resolvedUrl("bin/omarchy-bar-sysmon")).replace(/^file:\/\//, "")]
    stdout: SplitParser {
      onRead: function (line) {
        var data
        try {
          data = JSON.parse(String(line))
        } catch (e) {
          return
        }
        if (!data || !data.label) return
        root.label = String(data.label).replace(/\v/g, "\n")
        root.snapshot = data
        if (root.opened) root.applySnapshot()
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.label !== ""
    horizontalMargin: 7.5
    fixedWidth: vertical ? -1 : Math.ceil(labelText.implicitWidth + scaledHorizontalMargin * 2)
    tooltipText: ""
    onPressed: function (b) {
      if (b === Qt.RightButton) root.openProcessMonitor()
      else root.toggle()
    }

    Text {
      id: labelText
      anchors.centerIn: parent
      // Lift the block clear of the bar's open-panel mark, which is painted
      // over the bottom few pixels of the slot and would otherwise sit on the
      // descenders of the second row.
      anchors.verticalCenterOffset: -Style.space(2)
      text: root.label
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: 9
      lineHeight: 0.98
      horizontalAlignment: Text.AlignHCenter
      renderType: Text.NativeRendering
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: root.openProcessMonitor()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- CPU: the headline figure and its per-core breakdown ----------
        Column {
          width: parent.width
          spacing: Style.space(9)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroLeft.implicitHeight, heroMeta.implicitHeight)

            Column {
              id: heroLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                text: root.num(root.cpu, "pct", 0) + "%"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.display
              }

              Text {
                text: root.fmtUptime(root.uptime)
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              id: heroMeta
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                anchors.right: parent.right
                text: "󰻠  CPU · " + root.num(root.cpu, "threads", 0) + " threads"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.right: parent.right
                text: "󰓅  " + root.num(root.cpu, "load", "—")
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                visible: root.num(root.cpu, "temp", null) !== null
                text: "󰔏  " + root.num(root.cpu, "temp", 0) + "°C"
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- Per-core load ----------
          // Sits tight under the hero: it is the same measurement, resolved.
          // Modelled on the core count rather than the array, so the delegates
          // survive a tick and only their heights animate.
          Row {
            id: coreRow
            width: parent.width
            spacing: Style.space(3)
            visible: root.cores.length > 0

            readonly property real cellWidth: root.cores.length > 0
              ? (width - spacing * (root.cores.length - 1)) / root.cores.length
              : 0

            Repeater {
              model: root.cores.length

              Item {
                required property int index
                readonly property real load: Math.max(0, Math.min(100, Number(root.cores[index]) || 0))

                width: coreRow.cellWidth
                height: Style.space(11)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(2)
                  color: root.barForeground
                  opacity: 0.06
                }

                Rectangle {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Math.max(Style.space(2), parent.height * parent.load / 100)
                  radius: Style.space(2)
                  // A pinned core is worth spotting at a glance, and the bar
                  // already owns a colour that means exactly that.
                  color: parent.load >= 85
                    ? (root.bar ? root.bar.urgent : Color.urgent)
                    : Color.accent
                  opacity: 0.85

                  Behavior on height {
                    NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
                  }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- Memory ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MEMORY"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          StatRow {
            icon: "󰍛"
            key: "In use"
            value: root.fmtBytes(root.num(root.mem, "used", 0)) + " / "
                   + root.fmtBytes(root.num(root.mem, "total", 0))
                   + "   " + root.num(root.mem, "pct", 0) + "%"
          }

          StatRow {
            icon: "󰓡"
            key: "Swap"
            visible: root.num(root.mem, "swapTotal", 0) > 0
            value: root.fmtBytes(root.num(root.mem, "swapUsed", 0)) + " / "
                   + root.fmtBytes(root.num(root.mem, "swapTotal", 0))
                   + "   " + root.num(root.mem, "swapPct", 0) + "%"
          }
        }

        PanelSeparator {
          visible: root.gpus.length > 0
          foreground: root.barForeground
        }

        // ---------- GPU ----------
        // One pair of rows per GPU: load, temperature and power on the first,
        // video memory on the second.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.gpus.length > 0

          PanelSectionHeader {
            text: "GPU"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Repeater {
            model: root.gpus.length

            Column {
              required property int index
              readonly property var gpu: root.gpus[index] || ({})
              width: parent.width
              spacing: Style.space(6)

              StatRow {
                icon: "󰢮"
                key: String(gpu.name || "GPU")
                value: root.gpuSummary(gpu)
                valueColor: Number(gpu.pct) >= 85 ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground
              }

              StatRow {
                icon: "󰍛"
                key: "VRAM"
                visible: Number(gpu.memTotal) > 0
                value: root.fmtBytes(gpu.memUsed) + " / " + root.fmtBytes(gpu.memTotal)
                       + "   " + Math.round(100 * Number(gpu.memUsed) / Number(gpu.memTotal)) + "%"
                valueColor: root.dimForeground
              }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- Network ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "NETWORK"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          StatRow { icon: "󰇚"; key: "Download"; value: root.fmtRate(root.num(root.net, "rx", 0)) }
          StatRow { icon: "󰕒"; key: "Upload";   value: root.fmtRate(root.num(root.net, "tx", 0)) }

          // The feeding script only sends these once more than one link is
          // live, since otherwise they just repeat the totals above.
          Repeater {
            model: root.ifaces.length
            StatRow {
              required property int index
              icon: "󰌗"
              key: root.ifaces[index].name
              value: "↓ " + root.fmtRate(root.ifaces[index].rx)
                     + "   ↑ " + root.fmtRate(root.ifaces[index].tx)
              valueColor: root.dimForeground
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- Disk ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "DISK"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          StatRow { icon: "󰇚"; key: "Read";  value: root.fmtRate(root.num(root.disk, "read", 0)) }
          StatRow { icon: "󰕒"; key: "Write"; value: root.fmtRate(root.num(root.disk, "write", 0)) }

          Repeater {
            model: root.mounts.length
            StatRow {
              required property int index
              icon: "󰉋"
              key: root.mounts[index].target
              value: root.mounts[index].used + " / " + root.mounts[index].size
                     + "   " + root.mounts[index].pct + "%"
              valueColor: root.dimForeground
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Button {
          width: parent.width
          iconText: "󰞷"
          iconSize: Style.font.icon
          text: "Process monitor"
          fontSize: Style.font.bodySmall
          foreground: root.barForeground
          fontFamily: root.ff
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          onClicked: root.openProcessMonitor()
        }
      }
    }
  }
}
