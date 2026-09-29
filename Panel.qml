import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Grouped CPU / memory / GPU / disk / network module. Fed by
// bin/omarchy-bar-sysmon (next to this file), which streams one JSON
// object per tick from a single long-lived, fork-free process. The bar shows
// a compact two-row block chosen in the settings, turning the urgent colour
// when something runs hot or fills up; clicking opens the breakdown, so this
// behaves like omarchy.audio and omarchy.bluetooth rather than a hover
// tooltip, and picks up the bar's accent open-panel mark for free.
Panel {
  id: root

  moduleName: "navjottomer.sysmon"
  ipcTarget: "navjottomer.sysmon"

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
  property var drives: []
  property var topCpu: []
  property var topMem: []

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  // ---------- Settings ----------
  readonly property var metricKeys: ["cpu", "memory", "gpu", "disk", "temperature"]
  function metricSetting(name, fallback) {
    var v = settings ? String(settings[name] || "") : ""
    return metricKeys.indexOf(v) >= 0 ? v : fallback
  }
  function intSetting(name, fallback, lo, hi) {
    var v = settings ? Number(settings[name]) : NaN
    return isNaN(v) || settings[name] === "" ? fallback : Math.max(lo, Math.min(hi, Math.round(v)))
  }
  readonly property var layoutKeys: ["stacked", "line", "compact"]
  readonly property string barLayout: {
    var v = settings ? String(settings.barLayout || "") : ""
    return layoutKeys.indexOf(v) >= 0 ? v : "stacked"
  }
  readonly property string barTop: metricSetting("barTop", "cpu")
  readonly property string barBottom: metricSetting("barBottom", "disk")
  readonly property bool barNetwork: !(settings && (settings.barNetwork === false || settings.barNetwork === "false"))
  readonly property int warnTemp: intSetting("warnTemp", 85, 50, 110)
  readonly property int warnUsage: intSetting("warnUsage", 90, 50, 100)
  // Compact shows the top metric only; the other layouts show both.
  readonly property var shownMetrics: barLayout === "compact" ? [barTop] : [barTop, barBottom]
  readonly property bool gpuOnBar: shownMetrics.indexOf("gpu") >= 0

  // ---------- History ----------
  // The last two minutes (60 ticks) of CPU, network and GPU load, kept even
  // while the panel is closed so the graphs are full the moment it opens.
  readonly property int historyLength: 60
  property var histCpu: []
  property var histRx: []
  property var histTx: []
  property var histGpu: ({})

  function pushed(list, value) {
    var out = list.length >= historyLength ? list.slice(list.length - historyLength + 1) : list.slice()
    out.push(Math.max(0, Number(value) || 0))
    return out
  }

  // The label is a two-row block in a padded slot, so the open-panel mark would
  // otherwise span the whole slot. Point it at the painted text.
  readonly property real openPanelIndicatorWidth: button.vertical ? 0 : activeLabel.implicitWidth
  readonly property Item activeLabel: barLayout === "stacked" ? labelBlock : lineBlock

  implicitWidth: snapshot === null ? 0 : button.implicitWidth
  implicitHeight: snapshot === null ? 0 : button.implicitHeight

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

  // Bar rates are four characters at most, always two significant digits, so
  // the block keeps its width as the figure changes: 9.9K, 99K, then the next
  // unit up as .34M rather than 345K.
  function rateShort(bytes) {
    var units = ["B", "K", "M", "G", "T"]
    var v = Math.max(0, Number(bytes) || 0)
    var i = 0
    while (v >= 99.5 && i < units.length - 1) {
      v /= 1024
      i++
    }
    var u = units[i]
    if (i > 0 && v < 0.995) return "." + String(Math.max(1, Math.round(v * 100))).padStart(2, "0") + u
    if (i > 0 && v < 9.95) return v.toFixed(1) + u
    return Math.round(v) + u
  }

  function pad(value, n) {
    return String(value).padStart(n)
  }

  // ---------- Bar ----------
  readonly property var metricIcons: ({
    cpu: "\u{f0ee0}", memory: "\u{f035b}", gpu: "\u{f08ae}", disk: "\u{f02ca}", temperature: "\u{f050f}"
  })

  function metricValue(key) {
    var d = snapshot
    if (!d) return "—"
    var v
    if (key === "cpu") v = d.cpu ? d.cpu.pct : null
    else if (key === "memory") v = d.mem ? d.mem.pct : null
    else if (key === "disk") v = d.disk ? d.disk.pct : null
    else if (key === "gpu") v = d.gpus && d.gpus.length ? d.gpus[0].pct : null
    else if (key === "temperature") v = d.cpu ? d.cpu.temp : null
    return (v === null || v === undefined ? "—" : v) + (key === "temperature" ? "°" : "%")
  }

  function metricText(key) {
    return snapshot ? metricIcons[key] + " " + pad(metricValue(key), 4) : ""
  }

  // The stock bar button's side margin (WidgetButton's default). Two stock
  // icons sit two margins apart, so the one-line layouts space their items
  // the same way; Style.spaceReal applies the theme's [spacing] scale, so a
  // change to it moves these gaps along with the rest of the bar.
  readonly property real stockMargin: 8.5
  readonly property real barItemGap: Style.spaceReal(stockMargin) * 2

  // Pieces of the one-line layouts, each coloured on its own. `sample` is
  // the widest usual value, reserved so the line keeps its width; a rarer
  // wider one (100%) grows its slot for as long as it lasts.
  readonly property var lineSegments: {
    var d = snapshot
    var out = [{ key: barTop, icon: metricIcons[barTop], value: metricValue(barTop), sample: "99%" }]
    if (barLayout === "compact") return out
    out.push({ key: barBottom, icon: metricIcons[barBottom], value: metricValue(barBottom), sample: "99%" })
    if (barNetwork && d && d.net) {
      out.push({ key: "", icon: "↓", value: rateShort(d.net.rx), sample: "8.8M" })
      out.push({ key: "", icon: "↑", value: rateShort(d.net.tx), sample: "8.8M" })
    }
    return out
  }

  function barRow(key, arrow, rate) {
    return metricText(key) + (barNetwork ? "  " + arrow + pad(rateShort(rate), 4) : "")
  }

  // ---------- Warnings ----------
  // Each warning names the bar metric it belongs to, so that row can turn
  // the urgent colour; one whose metric is not on the bar colours the block.
  readonly property var warnings: {
    var d = snapshot
    var out = []
    if (!d) return out
    if (d.cpu && d.cpu.temp !== null && d.cpu.temp >= warnTemp)
      out.push({ metric: "temperature", text: "CPU at " + d.cpu.temp + "°C" })
    if (d.mem && d.mem.pct >= warnUsage)
      out.push({ metric: "memory", text: "Memory " + d.mem.pct + "% full" })
    var mounts = (d.disk && d.disk.mounts) || []
    for (var i = 0; i < mounts.length; i++)
      if (mounts[i].pct >= warnUsage)
        out.push({ metric: "disk", text: mounts[i].target + " " + mounts[i].pct + "% full" })
    var drv = (d.disk && d.disk.drives) || []
    for (var j = 0; j < drv.length; j++)
      if (drv[j].temp !== null && drv[j].temp >= (drv[j].max || 70))
        out.push({ metric: "disk", text: drv[j].name + " at " + drv[j].temp + "°C" })
    var g = d.gpus || []
    for (var k = 0; k < g.length; k++)
      if (g[k].temp !== null && g[k].temp !== undefined && g[k].temp >= warnTemp)
        out.push({ metric: "gpu", text: (g[k].name || "GPU") + " at " + g[k].temp + "°C" })
    return out
  }

  function rowWarns(key) {
    for (var i = 0; i < warnings.length; i++) {
      var m = warnings[i].metric
      if (m === key || (key === "cpu" && m === "temperature")) return true
    }
    return false
  }

  readonly property bool hiddenWarning: {
    for (var i = 0; i < warnings.length; i++) {
      var m = warnings[i].metric
      var shown = shownMetrics
      if (shown.indexOf(m) < 0 && !(m === "temperature" && shown.indexOf("cpu") >= 0)) return true
    }
    return false
  }

  function rowColor(key) {
    return hiddenWarning || rowWarns(key) ? urgent : button.foreground
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
    drives = (d.disk && d.disk.drives) || []
    topCpu = (d.top && d.top.cpu) || []
    topMem = (d.top && d.top.mem) || []
  }

  function record(d) {
    histCpu = pushed(histCpu, d.cpu ? d.cpu.pct : 0)
    histRx = pushed(histRx, d.net ? d.net.rx : 0)
    histTx = pushed(histTx, d.net ? d.net.tx : 0)
    var next = {}
    var g = d.gpus || []
    for (var i = 0; i < g.length && i < 8; i++) {
      var name = String(g[i].name || "GPU")
      next[name] = pushed(histGpu[name] || [], g[i].pct)
    }
    histGpu = next
  }

  // The script only samples processes and the NVIDIA GPU while told the
  // panel is open, so a closed panel costs no process scan and no nvidia-smi.
  function tellFeed() {
    if (feed.running) feed.write(opened ? "open\n" : "close\n")
  }

  onOpenedChanged: {
    tellFeed()
    if (opened) applySnapshot()
    else showSettings = false
    cursor = -1
  }

  function openProcessMonitor() {
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
    close()
  }

  // ---------- Settings screen ----------
  // The panel swaps its stats for a settings screen. Changes are written to
  // this widget's shell.json entry through the shell's own API, the same way
  // the stock clock and Tailscale panels save theirs, and apply at once.
  property bool showSettings: false
  // Keyboard cursor, -1 until a key moves it so the mouse user sees no
  // highlight. Stats screen: 0 = Process monitor, 1 = Settings. Settings
  // screen: an index into settingRows.
  property int cursor: -1
  readonly property var settingRows: barLayout === "compact"
    ? ["barLayout", "barTop", "warnTemp", "warnUsage", "back"]
    : ["barLayout", "barTop", "barBottom", "barNetwork", "warnTemp", "warnUsage", "back"]
  readonly property var layoutOptions: [
    { value: "stacked", label: "Stacked" },
    { value: "line", label: "One line" },
    { value: "compact", label: "Compact" }
  ]
  readonly property var metricOptions: [
    { value: "cpu", label: "CPU" },
    { value: "memory", label: "RAM" },
    { value: "gpu", label: "GPU" },
    { value: "disk", label: "Disk" },
    { value: "temperature", label: "CPU °C" }
  ]

  onShowSettingsChanged: cursor = -1

  function saveSetting(key, value) {
    var entry = { id: moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function stepChoice(key, keys, current, dx) {
    var i = keys.indexOf(current)
    var n = keys.length
    saveSetting(key, keys[((i < 0 ? 0 : i) + dx + n) % n])
  }

  function moveCursor(dx, dy) {
    if (!showSettings) {
      if (dx !== 0) cursor = cursor < 0 ? (dx > 0 ? 1 : 0) : Math.max(0, Math.min(1, cursor + dx))
      return
    }
    if (dy !== 0 || cursor < 0) {
      cursor = cursor < 0 ? 0 : Math.max(0, Math.min(settingRows.length - 1, cursor + dy))
      return
    }
    var row = settingRows[cursor]
    if (row === "barLayout") stepChoice("barLayout", layoutKeys, barLayout, dx)
    else if (row === "barTop") stepChoice("barTop", metricKeys, barTop, dx)
    else if (row === "barBottom") stepChoice("barBottom", metricKeys, barBottom, dx)
    else if (row === "barNetwork") saveSetting("barNetwork", dx > 0)
    else if (row === "warnTemp") saveSetting("warnTemp", Math.max(50, Math.min(110, warnTemp + dx)))
    else if (row === "warnUsage") saveSetting("warnUsage", Math.max(50, Math.min(100, warnUsage + dx)))
  }

  function activateCursor() {
    if (!showSettings) {
      if (cursor === 1) {
        showSettings = true
        cursor = 0
      } else {
        openProcessMonitor()
      }
      return
    }
    if (cursor < 0) {
      cursor = 0
      return
    }
    var row = settingRows[cursor]
    if (row === "barNetwork") saveSetting("barNetwork", !barNetwork)
    else if (row === "back") showSettings = false
    else moveCursor(1, 0)
  }

  function rowHasCursor(name) {
    return showSettings && settingRows[cursor] === name
  }

  // A labelled settings row: the label on the left, its control on the right.
  component SettingRow: Item {
    id: settingRow

    property string label: ""
    property string hint: ""
    default property alias control: controlSlot.data

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labels.implicitHeight, controlSlot.childrenRect.height)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: controlSlot.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: settingRow.label
        elide: Text.ElideRight
        color: root.barForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        visible: settingRow.hint !== ""
        textFormat: Text.PlainText
        text: settingRow.hint
        elide: Text.ElideRight
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }
    }

    Item {
      id: controlSlot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
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
        textFormat: Text.PlainText
        width: Style.space(13)
        horizontalAlignment: Text.AlignHCenter
        text: statRow.icon
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        text: statRow.key
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      textFormat: Text.PlainText
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
    id: feed
    running: true
    command: [String(Qt.resolvedUrl("bin/omarchy-bar-sysmon")).replace(/^file:\/\//, "")]
             .concat(root.gpuOnBar ? ["--gpu-always"] : [])
    stdinEnabled: true
    onRunningChanged: if (running && root.opened) root.tellFeed()
    stdout: SplitParser {
      onRead: function (line) {
        // The script caps each record well below this; anything longer is
        // not ours to parse.
        if (line.length > 65536) return
        var data
        try {
          data = JSON.parse(String(line))
        } catch (e) {
          return
        }
        if (!data || !data.cpu) return
        root.snapshot = data
        root.record(data)
        if (root.opened) root.applySnapshot()
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.snapshot !== null
    // Stacked hugs its two tight rows; the one-line layouts use the stock bar
    // button margin so their outer padding matches the icons beside them.
    horizontalMargin: root.barLayout === "stacked" ? 7.5 : root.stockMargin
    fixedWidth: vertical ? -1 : Math.ceil(root.activeLabel.implicitWidth + scaledHorizontalMargin * 2)
    // Only a warning earns a tooltip; otherwise a click opens the panel.
    tooltipText: root.warnings.map(function (w) { return w.text }).join("\n")
    onPressed: function (b) {
      if (b === Qt.RightButton) root.openProcessMonitor()
      else root.toggle()
    }

    // Two rows, each its own Text so a warning can colour just its row.
    Column {
      id: labelBlock
      visible: root.barLayout === "stacked"
      anchors.centerIn: parent
      // Lift the block clear of the bar's open-panel mark, which is painted
      // over the bottom few pixels of the slot and would otherwise sit on the
      // descenders of the second row.
      anchors.verticalCenterOffset: -Style.space(2)
      spacing: -1

      // Modelled on a count, not an array rebuilt every tick, so the two
      // rows are created once and only their text changes.
      Repeater {
        model: root.barLayout === "stacked" ? 2 : 0

        Text {
          required property int index
          readonly property string key: index === 0 ? root.barTop : root.barBottom
          readonly property var net: root.snapshot && root.snapshot.net ? root.snapshot.net : null
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.barRow(key, index === 0 ? "↓" : "↑", net ? (index === 0 ? net.rx : net.tx) : 0)
          color: root.rowColor(key)
          font.family: button.fontFamily
          font.pixelSize: 9
          renderType: Text.NativeRendering
        }
      }
    }

    // One line, a size below the bar's own text: both metrics and the rates
    // ("line"), or just the top metric ("compact"). Each value sits
    // left-aligned in a slot as wide as its widest possible value.
    Row {
      id: lineBlock
      visible: root.barLayout !== "stacked"
      anchors.centerIn: parent
      spacing: root.barItemGap

      FontMetrics {
        id: lineMetrics
        font.family: button.fontFamily
        font.pixelSize: lineBlock.fontSize
      }

      readonly property real fontSize: Math.max(9, Math.round(button.fontSize * 0.85))

      Repeater {
        model: root.barLayout === "stacked" ? 0 : root.lineSegments.length

        Row {
          required property int index
          readonly property var modelData: root.lineSegments[index] || ({ key: "", icon: "", value: "", sample: "" })
          spacing: Style.space(modelData.key === "" ? 1 : 4)

          Text {
            textFormat: Text.PlainText
            text: modelData.icon
            color: root.rowColor(modelData.key)
            font.family: button.fontFamily
            font.pixelSize: lineBlock.fontSize
          }

          Text {
            width: Math.max(implicitWidth, Math.ceil(lineMetrics.advanceWidth(modelData.sample)))
            textFormat: Text.PlainText
            text: modelData.value
            color: root.rowColor(modelData.key)
            font.family: button.fontFamily
            font.pixelSize: lineBlock.fontSize
          }
        }
      }
    }
  }

  // Filled line graph of the last two minutes. With `values2` set it is drawn
  // mirrored: `values` above the midline, `values2` below.
  component Graph: Canvas {
    id: graph

    property var values: []
    property var values2: []
    property real maxValue: 0
    property color lineColor: Color.accent
    property color lineColor2: root.dimForeground

    width: parent ? parent.width : 0
    height: Style.space(values2.length > 0 ? 34 : 26)

    onValuesChanged: if (root.opened) requestPaint()
    onWidthChanged: requestPaint()

    Connections {
      target: root
      function onOpenedChanged() { if (root.opened) graph.requestPaint() }
    }

    function peak(list) {
      var m = 0
      for (var i = 0; i < list.length; i++) m = Math.max(m, list[i])
      return m
    }

    function series(ctx, list, base, span, top, color) {
      if (list.length < 2) return
      var step = width / (root.historyLength - 1)
      var x0 = width - (list.length - 1) * step
      ctx.beginPath()
      ctx.moveTo(x0, base)
      for (var i = 0; i < list.length; i++)
        ctx.lineTo(x0 + i * step, base - span * Math.min(1, list[i] / top))
      ctx.lineTo(width, base)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, 0.22)
      ctx.fill()
      ctx.beginPath()
      for (var j = 0; j < list.length; j++) {
        var y = base - span * Math.min(1, list[j] / top)
        if (j === 0) ctx.moveTo(x0, y)
        else ctx.lineTo(x0 + j * step, y)
      }
      ctx.strokeStyle = color
      ctx.lineWidth = 1.2
      ctx.stroke()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.05)
      ctx.fillRect(0, 0, width, height)
      var mirrored = values2.length > 0
      var top = maxValue > 0 ? maxValue : Math.max(1, peak(values), mirrored ? peak(values2) : 0)
      if (mirrored) {
        series(ctx, values, height / 2, height / 2 - 1, top, lineColor)
        series(ctx, values2, height / 2, -(height / 2 - 1), top, lineColor2)
      } else {
        series(ctx, values, height, height - 1, top, lineColor)
      }
    }
  }

  // One column of the process list: name on the left, figure on the right.
  component ProcessList: Column {
    id: plist

    property string title: ""
    property var items: []
    property var format: function (item) { return "" }

    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: plist.title
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: plist.items.length

      Item {
        required property int index
        width: plist.width
        implicitHeight: procValue.implicitHeight

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: procValue.left
          anchors.rightMargin: Style.space(6)
          text: String(plist.items[index].name || "")
          elide: Text.ElideRight
          color: root.barForeground
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          id: procValue
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: plist.format(plist.items[index])
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
        }
      }
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
    contentHeight: panel.fittedContentHeight(root.showSettings ? settingsColumn.implicitHeight : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Esc on the settings screen goes back to the stats first.
      onCloseRequested: root.showSettings ? root.showSettings = false : root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTextKey: function (t) {
        if (t !== "s" && t !== "S") return
        root.showSettings = !root.showSettings
        if (root.showSettings) root.cursor = 0
      }

      // ---------- Settings screen ----------
      Column {
        id: settingsColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)
        visible: root.showSettings

        PanelSectionHeader {
          text: "BAR"
          foreground: root.barForeground
          fontFamily: root.ff
        }

        SettingRow {
          label: "Layout"
          ButtonGroup {
            options: root.layoutOptions
            value: root.barLayout
            foreground: root.barForeground
            fontFamily: root.ff
            fontSize: Style.font.caption
            focusable: false
            cursorIndex: root.rowHasCursor("barLayout") ? root.layoutKeys.indexOf(root.barLayout) : -1
            onChanged: function (v) { root.saveSetting("barLayout", v) }
          }
        }

        SettingRow {
          label: root.barLayout === "compact" ? "Shows" : "Top row"
          ButtonGroup {
            options: root.metricOptions
            value: root.barTop
            foreground: root.barForeground
            fontFamily: root.ff
            fontSize: Style.font.caption
            focusable: false
            cursorIndex: root.rowHasCursor("barTop") ? root.metricKeys.indexOf(root.barTop) : -1
            onChanged: function (v) { root.saveSetting("barTop", v) }
          }
        }

        SettingRow {
          visible: root.barLayout !== "compact"
          label: root.barLayout === "line" ? "Second" : "Bottom row"
          ButtonGroup {
            options: root.metricOptions
            value: root.barBottom
            foreground: root.barForeground
            fontFamily: root.ff
            fontSize: Style.font.caption
            focusable: false
            cursorIndex: root.rowHasCursor("barBottom") ? root.metricKeys.indexOf(root.barBottom) : -1
            onChanged: function (v) { root.saveSetting("barBottom", v) }
          }
        }

        SettingRow {
          visible: root.barLayout !== "compact"
          label: "Network speed"
          hint: "Download and upload"
          ToggleSwitch {
            checked: root.barNetwork
            foreground: root.barForeground
            hasCursor: root.rowHasCursor("barNetwork")
            onToggled: root.saveSetting("barNetwork", !root.barNetwork)
          }
        }

        PanelSeparator { foreground: root.barForeground }

        PanelSectionHeader {
          text: "WARN AT OR ABOVE"
          foreground: root.barForeground
          fontFamily: root.ff
        }

        SettingRow {
          label: "Temperature"
          hint: "CPU or GPU, in °C"
          NumberField {
            value: root.warnTemp
            from: 50
            to: 110
            foreground: root.barForeground
            fontFamily: root.ff
            fontSize: Style.font.bodySmall
            hasCursor: root.rowHasCursor("warnTemp")
            onModified: function (v) { root.saveSetting("warnTemp", v) }
          }
        }

        SettingRow {
          label: "Memory or disk"
          hint: "Percent full"
          NumberField {
            value: root.warnUsage
            from: 50
            to: 100
            foreground: root.barForeground
            fontFamily: root.ff
            fontSize: Style.font.bodySmall
            hasCursor: root.rowHasCursor("warnUsage")
            onModified: function (v) { root.saveSetting("warnUsage", v) }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Button {
          width: parent.width
          iconText: "\u{f004d}"
          iconSize: Style.font.icon
          text: "Back"
          fontSize: Style.font.bodySmall
          foreground: root.barForeground
          fontFamily: root.ff
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          hasCursor: root.rowHasCursor("back")
          onClicked: root.showSettings = false
        }
      }

      // ---------- Stats screen ----------
      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)
        visible: !root.showSettings

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
                textFormat: Text.PlainText
                text: root.num(root.cpu, "pct", 0) + "%"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.display
              }

              Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: "󰻠  CPU · " + root.num(root.cpu, "threads", 0) + " threads"
                color: root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: "󰓅  " + root.num(root.cpu, "load", "—")
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                visible: root.num(root.cpu, "temp", null) !== null
                text: "󰔏  " + root.num(root.cpu, "temp", 0) + "°C"
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- Warnings ----------
          Repeater {
            model: root.opened ? root.warnings.length : 0
            Text {
              required property int index
              readonly property var modelData: root.warnings[index] || ({ text: "" })
              width: parent.width
              textFormat: Text.PlainText
              text: "\u{f0026}  " + modelData.text
              elide: Text.ElideRight
              color: root.urgent
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }
          }

          Graph { values: root.histCpu; maxValue: 100 }

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
                  color: parent.load >= 85 ? root.urgent : Color.accent
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
                valueColor: gpu.temp !== null && gpu.temp >= root.warnTemp ? root.urgent : root.barForeground
              }

              Graph {
                values: root.histGpu[String(gpu.name || "GPU")] || []
                maxValue: 100
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
          StatRow { icon: "󰕒"; key: "Upload";   value: root.fmtRate(root.num(root.net, "tx", 0)); valueColor: root.dimForeground }

          // Download above the line in the accent, upload below it, dimmed.
          Graph { values: root.histRx; values2: root.histTx }

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
              valueColor: root.num(root.mounts[index], "pct", 0) >= root.warnUsage ? root.urgent : root.dimForeground
            }
          }

          Repeater {
            model: root.drives.length
            StatRow {
              required property int index
              readonly property var drive: root.drives[index]
              icon: "\u{f050f}"
              key: String(drive.name || "Drive")
              value: drive.temp === null ? "—" : drive.temp + "°C"
              valueColor: drive.temp !== null && drive.temp >= (drive.max || 70) ? root.urgent : root.dimForeground
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- Processes ----------
        // Sampled by the script only while this panel is open.
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "PROCESSES"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Row {
            width: parent.width
            spacing: Style.space(16)

            ProcessList {
              width: (parent.width - parent.spacing) / 2
              title: "CPU"
              items: root.topCpu
              format: function (p) { return p.pct + "%" }
            }

            ProcessList {
              width: (parent.width - parent.spacing) / 2
              title: "Memory"
              items: root.topMem
              format: function (p) { return root.fmtBytes(p.mem) }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            iconText: "󰞷"
            iconSize: Style.font.icon
            text: "Process monitor"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            hasCursor: !root.showSettings && root.opened && root.cursor === 0
            onClicked: root.openProcessMonitor()
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            iconText: "\u{f0493}"
            iconSize: Style.font.icon
            text: "Settings"
            fontSize: Style.font.bodySmall
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            hasCursor: !root.showSettings && root.opened && root.cursor === 1
            onClicked: root.showSettings = true
          }
        }
      }
    }
  }
}
