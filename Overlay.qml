import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "TaskModel.js" as TaskModel

// Windows-style task surface: Processes, Performance, and Startup.
//
// open(payloadJson) / close() / dismiss() / opened match the shell summon contract.
// {"tab":"performance"} opens that tab. End task asks the collector to signal
// the target PID(s) whose start time still matches the row (single PID or group targets).
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.murali-lns.task-manager"
  property bool opened: false
  property string tab: "processes"
  property string query: ""
  property string kind: "all"
  property string sortKey: "cpu"
  property bool sortDesc: true
  property int selectedPid: 0
  property string selectedId: ""
  property var expandedKeys: []
  property bool confirmOpen: false
  property string pendingSignal: "TERM"
  property int pendingPid: 0
  property int pendingStart: -1
  property var pendingTargets: []
  property string pendingGroupKey: ""
  property int armedPid: 0
  property int armedStart: -1
  property string armedGroupKey: ""
  property bool ending: false
  property string actionError: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property color muted: Qt.darker(foreground, 1.55)
  readonly property color danger: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int gap: Style.spacing.md
  readonly property int cardWidth: Math.min(Style.space(980), Math.max(Style.space(360), panel.width - Style.gapsOut * 2))
  readonly property int cardHeight: Math.min(Style.space(680), Math.max(Style.space(320), panel.height - Style.gapsOut * 2))
  readonly property int rowHeight: Math.max(Style.spacing.popupRowHeight, Style.font.body + Style.spacing.sm * 2)

  // Visual tokens. innerRadius follows Hyprland rounding (square theme → square
  // cards); softRadius keeps small chips and avatars slightly rounded.
  readonly property color accent: Color.accent
  readonly property color hairline: Util.alpha(root.foreground, 0.08)
  readonly property color surface: Util.alpha(root.foreground, 0.035)
  readonly property color surfaceHot: Util.alpha(root.foreground, 0.065)
  readonly property int innerRadius: root.cornerRadius > 0 ? Math.round(root.cornerRadius * 0.6) : 0
  readonly property int softRadius: Math.max(root.innerRadius, Style.space(3))
  readonly property int colGap: Style.spacing.lg
  readonly property int listRowHeight: Math.round(root.rowHeight * 1.3)
  readonly property string subtitle: root.host && root.host.memTotal
    ? (root.host.cpuCount || 0) + " cores  ·  " + TaskModel.formatBytes(root.host.memTotal) + " RAM  ·  up " + TaskModel.formatUptime(root.host.uptimeSec)
    : "Reading system…"
  readonly property var gpuTop: {
    var list = (root.host && root.host.gpus) || []
    var best = null
    for (var i = 0; i < list.length; i++) {
      var gpu = list[i]
      if (!gpu || typeof gpu.memUsed !== "number") continue
      if (!best || (gpu.memPercent || 0) > (best.memPercent || 0)) best = gpu
    }
    return best
  }
  readonly property int startupEnabled: {
    var n = 0
    for (var i = 0; i < root.startup.length; i++) if (root.startup[i] && root.startup[i].enabled) n++
    return n
  }

  // Load colour: accent when calm, blends toward urgent past 50%, urgent at 85%.
  function heat(percent) {
    var v = Number(percent) || 0
    if (v >= 85) return root.danger
    if (v >= 50) return Qt.tint(root.accent, Util.alpha(root.danger, 0.5))
    return root.accent
  }

  function stateColor(state) {
    if (state === "R") return root.accent
    if (state === "Z" || state === "T" || state === "t") return root.danger
    if (state === "D") return Qt.tint(root.accent, Util.alpha(root.danger, 0.5))
    return Util.alpha(root.foreground, 0.28)
  }

  function initial(name) {
    var s = String(name || "").replace(/^[^A-Za-z0-9]+/, "")
    return (s.charAt(0) || "?").toUpperCase()
  }

  function cpuShare(value) { return Math.max(0, Math.min(100, Number(value) || 0)) }

  function memShare(bytes) {
    var total = Number(root.host && root.host.memTotal) || 0
    return total > 0 ? Math.min(100, (Number(bytes) || 0) * 100 / total) : 0
  }

  readonly property var host: root.service && root.service.host ? root.service.host : ({})
  readonly property var processes: root.service && root.service.processes ? root.service.processes : []
  readonly property var startup: root.service && root.service.startup ? root.service.startup : []
  readonly property int shownCount: TaskModel.matchCount(root.processes, root.query, root.kind)
  readonly property var rows: TaskModel.visibleRows(root.processes, root.query, root.kind, root.sortKey, root.sortDesc, root.expandedKeys)
  readonly property var selectedEntry: root.findEntry(root.selectedId)
  readonly property var selected: root.selectedEntry && root.selectedEntry.type === "process" ? root.selectedEntry : null
  readonly property bool canEnd: !root.ending && (
    (root.selected && !root.selected.protected) ||
    (root.selectedEntry && root.selectedEntry.type === "group" && !root.selectedEntry.protected && root.selectedEntry.targets && root.selectedEntry.targets.length > 0)
  )
  readonly property bool canForce: root.canEnd && (
    (root.selected && root.armedPid === root.selected.pid && root.armedStart === root.selected.starttime) ||
    (root.selectedEntry && root.selectedEntry.type === "group" && root.armedGroupKey === root.selectedEntry.groupKey)
  )
  readonly property string confirmMessage: {
    if (root.selectedEntry && root.selectedEntry.type === "group") {
      var gName = root.selectedEntry.name
      var count = (root.pendingTargets && root.pendingTargets.length) || root.selectedEntry.count || 0
      if (root.pendingSignal === "KILL")
        return "Force end " + count + " processes for " + gName + "? They will be killed immediately. Unsaved work in those programs will be lost."
      return "End " + count + " processes for " + gName + "? They will be asked to quit. Unsaved work in those programs can be lost."
    }
    var name = root.selected ? root.selected.name : "that task"
    var pid = root.pendingPid
    if (root.pendingSignal === "KILL")
      return "Force end " + name + " (PID " + pid + ")? It will be killed immediately. Unsaved work in that program will be lost."
    return "End " + name + " (PID " + pid + ")? It will be asked to quit. Unsaved work in that program can be lost."
  }

  function colW(share) {
    return Math.max(0, (columns.width - root.colGap * 6) * share)
  }

  function findEntry(id) {
    var list = root.rows
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].id === id) return list[i]
    }
    return null
  }

  function setGroupOpen(key, open) {
    var next = []
    var current = root.expandedKeys || []
    for (var i = 0; i < current.length; i++) {
      if (current[i] !== key) next.push(current[i])
    }
    if (open) next.push(key)
    root.expandedKeys = next
  }

  function toggleGroup(key) {
    var open = false
    var current = root.expandedKeys || []
    for (var i = 0; i < current.length; i++) {
      if (current[i] === key) open = true
    }
    root.setGroupOpen(key, !open)
  }

  function findProcess(pid) {
    var list = root.processes
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].pid === pid) return list[i]
    }
    return null
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var requested = payload && String(payload.tab || "")
    root.tab = (requested === "performance" || requested === "startup" || requested === "processes") ? requested : "processes"
    root.opened = true
    openAnim.restart()
    root.confirmOpen = false
    root.actionError = ""
    root.query = ""
    searchField.text = ""
    if (root.rows.length > 0) {
      root.selectedId = root.rows[0].id
      root.selectedPid = root.rows[0].type === "process" ? root.rows[0].pid : 0
    }
    if (root.service) {
      root.service.detail = true
      root.service.poll()
    }
    Qt.callLater(function() {
      keyHost.forceActiveFocus()
      if (!root.selectedId && root.rows.length > 0) {
        root.selectedId = root.rows[0].id
        root.selectedPid = root.rows[0].type === "process" ? root.rows[0].pid : 0
      }
    })
  }

  function close() {
    root.opened = false
    root.confirmOpen = false
    if (root.service) root.service.detail = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggleSort(key) {
    if (root.sortKey === key) root.sortDesc = !root.sortDesc
    else {
      root.sortKey = key
      root.sortDesc = key === "name" || key === "status" || key === "user" ? false : true
    }
  }

  function moveSelection(delta) {
    var list = root.rows
    if (!list.length) return
    var idx = 0
    var found = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === root.selectedId) { idx = i; found = true; break }
    }
    if (!found) idx = delta > 0 ? 0 : list.length - 1
    else idx = Math.max(0, Math.min(list.length - 1, idx + delta))
    root.selectedId = list[idx].id
    root.selectedPid = list[idx].type === "process" ? list[idx].pid : 0
    processList.positionViewAtIndex(idx, ListView.Contain)
  }

  function moveSelectionTo(targetIdx) {
    var list = root.rows
    if (!list.length) return
    var idx = Math.max(0, Math.min(list.length - 1, targetIdx))
    root.selectedId = list[idx].id
    root.selectedPid = list[idx].type === "process" ? list[idx].pid : 0
    processList.positionViewAtIndex(idx, ListView.Contain)
  }

  function nudgeGroup(open) {
    var entry = root.selectedEntry
    if (!entry || !entry.groupKey) return
    if (entry.type === "process" && entry.depth === 0) return
    if (entry.type === "process" && !open) {
      root.setGroupOpen(entry.groupKey, false)
      root.selectedId = "g:" + entry.groupKey
      root.selectedPid = 0
      return
    }
    if (!entry.expandable && entry.type !== "group") return
    root.setGroupOpen(entry.groupKey, open)
  }

  function askEnd(signalName) {
    if (signalName === "KILL" ? !root.canForce : !root.canEnd) return
    root.pendingSignal = signalName
    if (root.selectedEntry && root.selectedEntry.type === "group") {
      root.pendingTargets = root.selectedEntry.targets || []
      root.pendingGroupKey = root.selectedEntry.groupKey || ""
      root.pendingPid = 0
      root.pendingStart = -1
    } else if (root.selected) {
      root.pendingTargets = []
      root.pendingGroupKey = ""
      root.pendingPid = root.selected.pid
      root.pendingStart = root.selected.starttime
    }
    root.confirmOpen = true
    keyHost.forceActiveFocus()
  }

  function confirmEnd() {
    root.confirmOpen = false
    if (!root.service) return
    var status = "fail"
    if (root.pendingTargets && root.pendingTargets.length > 0) {
      status = root.service.requestEnd(0, 0, root.pendingSignal, root.pendingTargets)
    } else {
      status = root.service.requestEnd(root.pendingPid, root.pendingStart, root.pendingSignal)
    }
    if (status !== "ok") {
      root.actionError = "Already ending a task."
      return
    }
    root.ending = true
    root.actionError = ""
  }

  function onEndFinished() {
    root.ending = false
    if (!root.service) return
    root.actionError = root.service.endError || ""
    if (!root.service.endError && root.pendingSignal === "TERM") {
      if (root.pendingTargets && root.pendingTargets.length > 0) {
        root.armedGroupKey = root.pendingGroupKey
        root.armedPid = 0
        root.armedStart = -1
      } else {
        root.armedPid = root.pendingPid
        root.armedStart = root.pendingStart
        root.armedGroupKey = ""
      }
    }
    if (!root.service.endError && root.pendingSignal === "KILL") {
      root.armedPid = 0
      root.armedStart = -1
      root.armedGroupKey = ""
    }
  }

  Connections {
    target: root.service
    function onEndRevisionChanged() { root.onEndFinished() }
    function onRevisionChanged() {
      if (root.selectedId && !root.findEntry(root.selectedId)) {
        if (root.rows.length > 0) {
          root.selectedId = root.rows[0].id
          root.selectedPid = root.rows[0].type === "process" ? root.rows[0].pid : 0
        } else {
          root.selectedId = ""
          root.selectedPid = 0
        }
      } else if (!root.selectedId && root.rows.length > 0) {
        root.selectedId = root.rows[0].id
        root.selectedPid = root.rows[0].type === "process" ? root.rows[0].pid : 0
      }
      if (root.armedPid && !root.findProcess(root.armedPid)) {
        root.armedPid = 0
        root.armedStart = -1
      }
      if (root.armedGroupKey) {
        var groupFound = false
        for (var g = 0; g < root.rows.length; g++) {
          if (root.rows[g].type === "group" && root.rows[g].groupKey === root.armedGroupKey) {
            groupFound = true
            break
          }
        }
        if (!groupFound) root.armedGroupKey = ""
      }
    }
  }

  // ── Visual building blocks ─────────────────────────────────────────────
  // Every color derives from the live theme (accent, urgent, foreground), so
  // the panel follows `omarchy theme set` without edits here.

  component Glyph: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon
    color: root.muted
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
  }

  // Thin horizontal usage bar (0–100).
  component Meter: Rectangle {
    id: meter
    property real value: 0
    property color ink: root.accent
    height: Math.max(2, Style.space(3))
    radius: height / 2
    color: Util.alpha(root.foreground, 0.08)
    Rectangle {
      width: meter.value > 0 ? Math.max(meter.height, meter.width * Math.min(100, meter.value) / 100) : 0
      height: parent.height
      radius: parent.radius
      color: meter.ink
      Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    }
  }

  // Pill-style segmented control: [{ value, label, glyph }].
  component Segmented: Rectangle {
    id: seg
    property var options: []
    property string value: ""
    property real fontSize: Style.font.bodySmall
    readonly property int pad: Style.spacing.xxs
    signal picked(string value)
    implicitWidth: segRow.implicitWidth + seg.pad * 2
    implicitHeight: Style.spacing.controlHeight + seg.pad * 2
    radius: root.innerRadius
    color: root.surface
    border.width: 1
    border.color: root.hairline

    Row {
      id: segRow
      anchors.centerIn: parent
      spacing: seg.pad
      Repeater {
        model: seg.options
        Rectangle {
          id: segItem
          required property var modelData
          readonly property bool chosen: seg.value === modelData.value
          height: Style.spacing.controlHeight
          width: segLabel.implicitWidth + Style.spacing.controlPaddingX * 2
          radius: Math.max(0, root.innerRadius - 1)
          color: segItem.chosen ? Util.alpha(root.accent, 0.18) : (segMouse.containsMouse ? root.surfaceHot : "transparent")
          Behavior on color { ColorAnimation { duration: 140 } }
          Row {
            id: segLabel
            anchors.centerIn: parent
            spacing: Style.spacing.md
            Glyph {
              anchors.verticalCenter: parent.verticalCenter
              visible: !!segItem.modelData.glyph
              text: segItem.modelData.glyph || ""
              font.pixelSize: seg.fontSize
              color: segItem.chosen ? root.accent : root.muted
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: segItem.modelData.label
              color: segItem.chosen ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: seg.fontSize
              font.bold: segItem.chosen
            }
          }
          MouseArea {
            id: segMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.picked(segItem.modelData.value)
          }
        }
      }
    }
  }

  // Sortable column header; numeric columns align right like their cells.
  component Head: Item {
    id: head
    property string key: ""
    property string text: ""
    property bool alignRight: false
    property int inset: 0
    readonly property bool active: root.sortKey === head.key
    height: root.rowHeight

    Row {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: head.alignRight ? parent.right : undefined
      anchors.left: head.alignRight ? undefined : parent.left
      anchors.leftMargin: head.inset
      spacing: Style.spacing.xs
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: head.text.toUpperCase()
        color: head.active ? root.accent : (headMouse.containsMouse ? root.foreground : root.muted)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: head.active
        font.letterSpacing: Style.space(1)
      }
      Glyph {
        anchors.verticalCenter: parent.verticalCenter
        visible: head.active
        text: root.sortDesc ? "\uf0d7" : "\uf0d8"
        color: root.accent
        font.pixelSize: Style.font.caption
      }
    }
    MouseArea {
      id: headMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleSort(head.key)
    }
  }

  // Summary tile above the process list.
  component StatTile: Rectangle {
    id: tile
    property string glyph: ""
    property string label: ""
    property string value: ""
    property string sub: ""
    property real meter: -1
    property color ink: root.accent
    height: tileCol.implicitHeight + Style.spacing.lg * 2
    radius: root.innerRadius
    color: root.surface
    border.width: 1
    border.color: root.hairline

    Column {
      id: tileCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.lg + Style.spacing.xs
      spacing: Style.spacing.sm
      Row {
        spacing: Style.spacing.md
        Glyph {
          anchors.verticalCenter: parent.verticalCenter
          text: tile.glyph
          color: tile.ink
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: tile.label.toUpperCase()
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: Style.space(1)
        }
      }
      Row {
        width: parent.width
        spacing: Style.spacing.md
        Text {
          id: tileValue
          anchors.verticalCenter: parent.verticalCenter
          text: tile.value
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - tileValue.implicitWidth - parent.spacing)
          text: tile.sub
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
      Meter {
        width: parent.width
        value: Math.max(0, tile.meter)
        ink: tile.ink
        opacity: tile.meter >= 0 ? 1 : 0
      }
    }
  }

  // Smooth area chart. `values` is filled; `values2` draws as a second line.
  // maxValue 0 autoscales (rates); otherwise values are percentages.
  component AreaChart: Canvas {
    id: chart
    property var values: []
    property var values2: []
    property real maxValue: 100
    property int capacity: 48
    property color ink: root.accent
    property color ink2: root.foreground
    readonly property real scaleMax: {
      if (chart.maxValue > 0) return chart.maxValue
      var top = 0
      var lists = [chart.values || [], chart.values2 || []]
      for (var l = 0; l < lists.length; l++)
        for (var i = 0; i < lists[l].length; i++) top = Math.max(top, Number(lists[l][i]) || 0)
      return Math.max(top * 1.2, 100 * 1024)
    }
    antialiasing: true
    onValuesChanged: requestPaint()
    onValues2Changed: requestPaint()
    onInkChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onAvailableChanged: requestPaint()

    function css(c, a) {
      return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
    }

    function trace(ctx, list) {
      var step = chart.width / Math.max(1, chart.capacity - 1)
      var x0 = chart.width - (list.length - 1) * step
      ctx.beginPath()
      for (var i = 0; i < list.length; i++) {
        var ratio = Math.max(0, Math.min(1, (Number(list[i]) || 0) / chart.scaleMax))
        var x = x0 + i * step
        var y = chart.height - 1 - ratio * (chart.height - 3)
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      return x0
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (chart.width <= 0 || chart.height <= 0) return
      ctx.lineWidth = 1
      ctx.strokeStyle = chart.css(root.foreground, 0.06)
      for (var g = 1; g < 4; g++) {
        var gy = Math.round(chart.height * g / 4) + 0.5
        ctx.beginPath()
        ctx.moveTo(0, gy)
        ctx.lineTo(chart.width, gy)
        ctx.stroke()
      }
      var main = chart.values || []
      if (main.length > 1) {
        var x0 = chart.trace(ctx, main)
        ctx.lineTo(chart.width, chart.height)
        ctx.lineTo(x0, chart.height)
        ctx.closePath()
        var fill = ctx.createLinearGradient(0, 0, 0, chart.height)
        fill.addColorStop(0, chart.css(chart.ink, 0.32))
        fill.addColorStop(1, chart.css(chart.ink, 0.02))
        ctx.fillStyle = fill
        ctx.fill()
        chart.trace(ctx, main)
        ctx.lineWidth = 1.6
        ctx.lineJoin = "round"
        ctx.strokeStyle = chart.css(chart.ink, 1)
        ctx.stroke()
      }
      var second = chart.values2 || []
      if (second.length > 1) {
        chart.trace(ctx, second)
        ctx.lineWidth = 1.2
        ctx.lineJoin = "round"
        ctx.strokeStyle = chart.css(chart.ink2, 0.55)
        ctx.stroke()
      }
    }
  }

  component TabButton: Button {
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    accent: Color.accent
    bordered: true
  }

  component PerfCard: Rectangle {
    id: perf
    property string glyph: ""
    property string title: ""
    property string value: ""
    property string detail: ""
    property string detail2: ""
    property var history: []
    property var history2: []
    property var cores: []
    property real maxValue: 100
    property color ink: root.accent
    // Compact cards (three per row) stack the legend and use a smaller value.
    property bool compact: false
    height: Style.space(perf.cores.length ? 210 : 164)
    radius: root.innerRadius
    color: root.surface
    border.width: 1
    border.color: root.hairline

    Item {
      id: perfHead
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.xl
      height: Math.max(perfIcon.height, perfValue.implicitHeight, perfText.implicitHeight)

      Rectangle {
        id: perfIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: width
        radius: root.softRadius
        color: Util.alpha(perf.ink, 0.16)
        Glyph {
          anchors.centerIn: parent
          text: perf.glyph
          color: perf.ink
          font.pixelSize: Style.font.body
        }
      }
      Column {
        id: perfText
        anchors.left: perfIcon.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: perfValue.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs
        Text {
          width: parent.width
          text: perf.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        Flow {
          width: parent.width
          spacing: Style.spacing.xs
          Row {
            id: legendA
            width: perf.compact ? parent.width : implicitWidth
            spacing: Style.spacing.md
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: perf.history2.length > 0
              width: Style.space(6); height: width; radius: width / 2
              color: perf.ink
            }
            Text {
              width: perf.compact ? Math.max(0, legendA.width - Style.space(12)) : implicitWidth
              elide: Text.ElideRight
              text: perf.detail
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Item { width: Style.spacing.lg; height: 1; visible: perf.detail2 !== "" && !perf.compact }
          Row {
            id: legendB
            visible: perf.detail2 !== ""
            width: perf.compact ? parent.width : implicitWidth
            spacing: Style.spacing.md
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: perf.history2.length > 0
              width: Style.space(6); height: width; radius: width / 2
              color: Util.alpha(root.foreground, 0.55)
            }
            Text {
              width: perf.compact ? Math.max(0, legendB.width - Style.space(12)) : implicitWidth
              elide: Text.ElideRight
              text: perf.detail2
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Text {
        id: perfValue
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: perf.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: perf.compact ? Style.font.heading : Style.font.display
        font.bold: true
      }
    }

    AreaChart {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: perfHead.bottom
      anchors.bottom: coresStrip.visible ? coresStrip.top : parent.bottom
      anchors.leftMargin: Style.spacing.xl
      anchors.rightMargin: Style.spacing.xl
      anchors.topMargin: Style.spacing.lg
      anchors.bottomMargin: Style.spacing.xl
      values: perf.history
      values2: perf.history2
      maxValue: perf.maxValue
      ink: perf.ink
    }

    // Per-core load, one bar per logical CPU.
    Row {
      id: coresStrip
      visible: perf.cores.length > 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.spacing.xl
      height: Style.space(30)
      spacing: Style.space(3)
      Repeater {
        model: perf.cores
        Rectangle {
          required property real modelData
          width: (coresStrip.width - coresStrip.spacing * Math.max(0, perf.cores.length - 1)) / Math.max(1, perf.cores.length)
          height: coresStrip.height
          radius: Math.min(root.softRadius, Style.space(2))
          color: Util.alpha(root.foreground, 0.06)
          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.max(Style.space(2), parent.height * Math.max(0, Math.min(100, modelData)) / 100)
            radius: parent.radius
            color: root.heat(modelData)
          }
        }
      }
    }
  }

  NumberAnimation { id: tabFade; target: body; property: "opacity"; from: 0.0; to: 1.0; duration: 160; easing.type: Easing.OutCubic }
  onTabChanged: tabFade.restart()

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-task-manager"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin + Style.spacing.xs

      ParallelAnimation {
        id: openAnim
        NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 170; easing.type: Easing.OutCubic }
        NumberAnimation { target: card; property: "scale"; from: 0.975; to: 1; duration: 210; easing.type: Easing.OutCubic }
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyHost
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: root.opened && !searchField.activeFocus
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.confirmOpen) {
            event.accepted = confirm.handleKey(event)
            return
          }
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.moveSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.moveSelection(-8)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.moveSelection(8)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.moveSelectionTo(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.moveSelectionTo(root.rows.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
            root.nudgeGroup(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            root.nudgeGroup(false)
            event.accepted = true
          } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.selectedEntry && root.selectedEntry.expandable) {
              root.toggleGroup(root.selectedEntry.groupKey)
              event.accepted = true
            }
          } else if (event.key === Qt.Key_Slash) {
            searchField.forceActiveFocus()
            event.accepted = true
          } else if (event.key === Qt.Key_T || event.text === "t" || event.text === "T" || event.key === Qt.Key_Delete) {
            if (root.canEnd) {
              root.askEnd(root.canForce ? "KILL" : "TERM")
              event.accepted = true
            }
          } else if (event.key === Qt.Key_Tab) {
            if (root.tab === "processes") {
              searchField.forceActiveFocus()
              event.accepted = true
            }
          }
        }

        // ── Header: identity, live subtitle, tabs, close ──
        Column {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: root.gap

          Item {
            width: parent.width
            height: Math.max(titleBlock.implicitHeight, tabSeg.implicitHeight)

            Row {
              id: titleBlock
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xl
              Rectangle {
                width: Style.space(40)
                height: width
                radius: root.softRadius
                color: Util.alpha(root.accent, 0.16)
                border.width: 1
                border.color: Util.alpha(root.accent, 0.35)
                Glyph {
                  anchors.centerIn: parent
                  text: "\uf201"
                  color: root.accent
                  font.pixelSize: Style.font.iconLarge
                }
              }
              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs
                Text {
                  text: "Task Manager"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  text: root.subtitle
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.lg
              Segmented {
                id: tabSeg
                value: root.tab
                fontSize: Style.font.bodySmall
                options: [
                  { value: "processes", label: "Processes", glyph: "\uf0ae" },
                  { value: "performance", label: "Performance", glyph: "\uf1fe" },
                  { value: "startup", label: "Startup", glyph: "\uf135" }
                ]
                onPicked: function(value) { root.tab = value }
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: tabSeg.implicitHeight
                height: width
                radius: root.innerRadius
                color: closeMouse.containsMouse ? Util.alpha(root.danger, 0.18) : root.surface
                border.width: 1
                border.color: closeMouse.containsMouse ? Util.alpha(root.danger, 0.5) : root.hairline
                Behavior on color { ColorAnimation { duration: 140 } }
                Glyph {
                  anchors.centerIn: parent
                  text: "\uf00d"
                  color: closeMouse.containsMouse ? root.danger : root.muted
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: closeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.dismiss()
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: errorText.implicitHeight + Style.spacing.md * 2
            visible: (root.service && root.service.errorText) || root.actionError !== ""
            radius: root.innerRadius
            color: Util.alpha(root.danger, 0.12)
            border.width: 1
            border.color: Util.alpha(root.danger, 0.4)
            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.lg
              anchors.rightMargin: Style.spacing.lg
              spacing: Style.spacing.md
              Glyph {
                height: parent.height
                text: "\uf071"
                color: root.danger
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: errorText
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(24)
                text: root.actionError || (root.service ? root.service.errorText : "")
                color: root.danger
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        Item {
          id: body
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.bottom: root.tab === "processes" ? footer.top : parent.bottom
          anchors.topMargin: root.gap + Style.spacing.sm
          anchors.bottomMargin: root.tab === "processes" ? root.gap : 0

          // ── Processes ──
          Item {
            anchors.fill: parent
            visible: root.tab === "processes"

            Row {
              id: statRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: root.gap
              readonly property int count: root.gpuTop ? 4 : 3
              readonly property real tileW: (width - spacing * (count - 1)) / count

              StatTile {
                width: statRow.tileW
                glyph: "\uf2db"
                label: "CPU"
                value: TaskModel.formatCpu(root.host.cpuPercent)
                sub: (root.host.cpuCount || 0) + " cores"
                meter: Number(root.host.cpuPercent) || 0
                ink: root.heat(root.host.cpuPercent)
              }
              StatTile {
                width: statRow.tileW
                glyph: "\uf1c0"
                label: "Memory"
                value: TaskModel.formatBytes(root.host.memUsed)
                sub: "of " + TaskModel.formatBytes(root.host.memTotal)
                meter: Number(root.host.memPercent) || 0
                ink: root.heat(root.host.memPercent)
              }
              StatTile {
                visible: !!root.gpuTop
                width: statRow.tileW
                glyph: "\uf108"
                label: root.gpuTop ? "GPU · " + (root.gpuTop.shortName || "VRAM") : "GPU"
                value: root.gpuTop ? TaskModel.formatBytes(root.gpuTop.memUsed) : "—"
                sub: root.gpuTop && root.gpuTop.memTotal ? "of " + TaskModel.formatBytes(root.gpuTop.memTotal) : ""
                meter: root.gpuTop ? (Number(root.gpuTop.memPercent) || 0) : -1
                ink: root.heat(root.gpuTop ? root.gpuTop.memPercent : 0)
              }
              StatTile {
                width: statRow.tileW
                glyph: "\uf0ae"
                label: "Processes"
                value: String(root.shownCount)
                sub: root.shownCount !== root.processes.length
                  ? "of " + root.processes.length + " shown"
                  : "up " + TaskModel.formatUptime(root.host.uptimeSec)
                meter: -1
              }
            }

            Item {
              id: toolbar
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: statRow.bottom
              anchors.topMargin: root.gap + Style.spacing.sm
              height: Math.max(searchField.implicitHeight, kindSeg.implicitHeight)

              TextField {
                id: searchField
                anchors.left: parent.left
                anchors.right: kindSeg.left
                anchors.rightMargin: root.gap
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(32)
                placeholderText: "Search name, PID, or window"
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                foreground: root.foreground
                accent: Color.accent
                text: root.query
                onTextChanged: root.query = text
                Keys.onDownPressed: function(event) {
                  keyHost.forceActiveFocus()
                  root.moveSelection(1)
                  event.accepted = true
                }
                Keys.onUpPressed: function(event) {
                  keyHost.forceActiveFocus()
                  root.moveSelection(-1)
                  event.accepted = true
                }
                Keys.onReturnPressed: function(event) {
                  keyHost.forceActiveFocus()
                  event.accepted = true
                }
                Keys.onEnterPressed: function(event) {
                  keyHost.forceActiveFocus()
                  event.accepted = true
                }
                Keys.onTabPressed: function(event) {
                  keyHost.forceActiveFocus()
                  event.accepted = true
                }
                Keys.onEscapePressed: function(event) {
                  if (text.length > 0) {
                    text = ""
                  } else {
                    keyHost.forceActiveFocus()
                  }
                  event.accepted = true
                }
              }
              Glyph {
                anchors.left: searchField.left
                anchors.leftMargin: Style.spacing.xl
                anchors.verticalCenter: searchField.verticalCenter
                text: "\uf002"
                color: searchField.activeFocus ? root.accent : root.muted
                font.pixelSize: Style.font.bodySmall
              }

              Segmented {
                id: kindSeg
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                value: root.kind
                options: [
                  { value: "all", label: "All", glyph: "\uf03a" },
                  { value: "app", label: "Apps", glyph: "\uf2d0" },
                  { value: "background", label: "Background", glyph: "\uf013" }
                ]
                onPicked: function(value) { root.kind = value }
              }
            }

            Item {
              id: columnsBox
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: toolbar.bottom
              anchors.topMargin: root.gap
              height: root.rowHeight

              Row {
                id: columns
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.xl
                anchors.rightMargin: Style.spacing.xl
                spacing: root.colGap

                Head { key: "name"; text: "Name"; width: root.colW(0.30) }
                Head { key: "status"; text: "Status"; width: root.colW(0.12) }
                Head { key: "cpu"; text: "CPU"; alignRight: true; width: root.colW(0.10) }
                Head { key: "gpu"; text: "GPU"; alignRight: true; width: root.colW(0.15) }
                Head { key: "memBytes"; text: "Memory"; alignRight: true; width: root.colW(0.13) }
                Head { key: "pid"; text: "PID"; alignRight: true; width: root.colW(0.09) }
                Head { key: "user"; text: "User"; inset: Style.spacing.xl; width: root.colW(0.11) }
              }
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: root.hairline
              }
            }

            ListView {
              id: processList
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: columnsBox.bottom
              anchors.bottom: detailLine.top
              anchors.topMargin: Style.spacing.xs
              anchors.bottomMargin: Style.spacing.md
              clip: true
              model: root.rows
              boundsBehavior: Flickable.StopAtBounds
              delegate: Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool isSel: modelData.id === root.selectedId
                readonly property bool isGroup: modelData.type === "group"
                readonly property bool isChild: !!modelData.depth
                width: processList.width
                height: root.listRowHeight

                Rectangle {
                  anchors.fill: parent
                  anchors.topMargin: 1
                  anchors.bottomMargin: 1
                  radius: root.innerRadius
                  color: rowItem.isSel ? Util.alpha(root.accent, 0.13)
                    : (rowMouse.containsMouse ? root.surfaceHot : "transparent")
                }
                Rectangle {
                  visible: rowItem.isSel
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.topMargin: Style.spacing.md
                  anchors.bottomMargin: Style.spacing.md
                  width: Style.space(3)
                  radius: width / 2
                  color: root.accent
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.xl
                  anchors.rightMargin: Style.spacing.xl
                  spacing: root.colGap

                  // Name: chevron, avatar, name, group count
                  Item {
                    id: nameCell
                    width: root.colW(0.30)
                    height: parent.height
                    Row {
                      anchors.left: parent.left
                      anchors.leftMargin: rowItem.isChild ? Style.space(20) : 0
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.md
                      Glyph {
                        id: chevron
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(10)
                        text: rowItem.modelData.expandable ? "\uf105" : ""
                        rotation: rowItem.modelData.expanded ? 90 : 0
                        color: rowItem.isSel ? root.accent : root.muted
                        font.pixelSize: Style.font.bodySmall
                        Behavior on rotation { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                      }
                      Rectangle {
                        id: avatar
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(rowItem.isChild ? 18 : 22)
                        height: width
                        radius: root.softRadius
                        color: Util.alpha(rowItem.isChild ? root.foreground : root.accent, rowItem.isChild ? 0.07 : 0.16)
                        Text {
                          anchors.centerIn: parent
                          text: root.initial(rowItem.modelData.name)
                          color: rowItem.isChild ? root.muted : root.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, nameCell.width - (rowItem.isChild ? Style.space(20) : 0)
                          - chevron.width - avatar.width - Style.spacing.md * 2
                          - (countBadge.visible ? countBadge.width + Style.spacing.md : 0))
                        text: rowItem.modelData.name
                        color: rowItem.isChild ? Qt.darker(root.foreground, 1.15) : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: rowItem.isSel
                        elide: Text.ElideRight
                      }
                      Rectangle {
                        id: countBadge
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rowItem.isGroup && (rowItem.modelData.count || 0) > 1
                        height: Style.space(16)
                        width: countText.implicitWidth + Style.spacing.md * 2
                        radius: root.softRadius
                        color: Util.alpha(root.foreground, 0.08)
                        Text {
                          id: countText
                          anchors.centerIn: parent
                          text: rowItem.modelData.count || ""
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }

                  // Status: dot + label
                  Item {
                    width: root.colW(0.12)
                    height: parent.height
                    Row {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.md
                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(7)
                        height: width
                        radius: width / 2
                        color: root.stateColor(rowItem.modelData.state)
                      }
                      Text {
                        text: rowItem.modelData.status
                        color: rowItem.modelData.state === "R" ? root.accent : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  // CPU: value + heat bar
                  Column {
                    width: root.colW(0.10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xs
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: TaskModel.formatCpu(rowItem.modelData.cpu)
                      color: (rowItem.modelData.cpu || 0) >= 50 ? root.heat(rowItem.modelData.cpu) : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Meter {
                      width: Math.min(parent.width, Style.space(64))
                      x: parent.width - width
                      value: root.cpuShare(rowItem.modelData.cpu)
                      ink: root.heat(rowItem.modelData.cpu)
                    }
                  }

                  Text {
                    width: root.colW(0.15)
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    text: TaskModel.formatGpu(rowItem.modelData)
                    color: (rowItem.modelData.gpuMemBytes || 0) > 0 ? root.foreground : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                  }

                  // Memory: value + share of total RAM
                  Column {
                    width: root.colW(0.13)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xs
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: TaskModel.formatBytes(rowItem.modelData.memBytes)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Meter {
                      width: Math.min(parent.width, Style.space(64))
                      x: parent.width - width
                      value: root.memShare(rowItem.modelData.memBytes)
                      ink: Util.alpha(root.accent, 0.75)
                    }
                  }

                  Text {
                    width: root.colW(0.09)
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    text: rowItem.isGroup ? "" : rowItem.modelData.pid
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    verticalAlignment: Text.AlignVCenter
                  }
                  Text {
                    width: root.colW(0.11)
                    height: parent.height
                    leftPadding: Style.spacing.xl
                    text: rowItem.modelData.user
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: {
                    root.selectedId = rowItem.modelData.id
                    root.selectedPid = rowItem.modelData.type === "process" ? rowItem.modelData.pid : 0
                    if (rowItem.modelData.expandable) root.toggleGroup(rowItem.modelData.groupKey)
                    keyHost.forceActiveFocus()
                  }
                }
              }

              Column {
                anchors.centerIn: parent
                visible: root.rows.length === 0
                spacing: Style.spacing.lg
                Glyph {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.service && root.service.detail ? "\uf002" : "\uf110"
                  color: root.muted
                  font.pixelSize: Style.font.displayLarge
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.service && root.service.detail ? "No matching processes." : "Reading processes…"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            // Slim scroll indicator
            Rectangle {
              visible: processList.contentHeight > processList.height
              x: processList.x + processList.width - width
              y: processList.y + processList.visibleArea.yPosition * processList.height
              width: Style.space(3)
              height: Math.max(Style.space(24), processList.visibleArea.heightRatio * processList.height)
              radius: width / 2
              color: Util.alpha(root.foreground, 0.22)
            }

            Rectangle {
              id: detailLine
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: root.rowHeight + Style.spacing.md
              radius: root.innerRadius
              color: root.surface
              border.width: 1
              border.color: root.hairline
              readonly property bool isProtected: (root.selected && root.selected.protected) || (root.selectedEntry && root.selectedEntry.protected)
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.xl
                anchors.rightMargin: Style.spacing.xl
                spacing: Style.spacing.md
                Glyph {
                  id: detailGlyph
                  height: parent.height
                  text: detailLine.isProtected ? "\uf023"
                    : (root.selectedEntry && root.selectedEntry.type === "group" ? "\uf247" : "\uf120")
                  color: detailLine.isProtected ? root.danger : root.accent
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width - detailGlyph.width - parent.spacing
                  height: parent.height
                  text: root.selected
                    ? (root.selected.protectReason
                        || ((root.selected.gpuNote ? root.selected.gpuNote + "  ·  " : "") + (root.selected.cmdline || root.selected.name)))
                    : (root.selectedEntry && root.selectedEntry.type === "group"
                       ? (root.selectedEntry.protectReason || (root.selectedEntry.count + " processes. End task to stop group."))
                       : root.shownCount + " processes")
                  color: detailLine.isProtected ? root.danger : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                }
              }
            }
          }

          // ── Performance ──
          Flickable {
            id: perfTab
            anchors.fill: parent
            visible: root.tab === "performance"
            contentHeight: perfColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: perfColumn
              width: perfTab.width
              spacing: root.gap + Style.spacing.xs

              PerfCard {
                width: perfColumn.width
                glyph: "\uf2db"
                title: "CPU"
                value: TaskModel.formatCpu(root.host.cpuPercent)
                detail: (root.host.cpuCount || 0) + " cores  ·  load " + (root.host.load && root.host.load.length === 3
                  ? Number(root.host.load[0]).toFixed(2) + "  " + Number(root.host.load[1]).toFixed(2) + "  " + Number(root.host.load[2]).toFixed(2)
                  : "—")
                history: root.service ? root.service.cpuHistory : []
                cores: root.host.cores || []
                ink: root.heat(root.host.cpuPercent)
              }

              Grid {
                id: gpuGrid
                visible: (root.host.gpus || []).length > 0
                width: perfColumn.width
                columns: Math.max(1, Math.min((root.host.gpus || []).length, 3))
                spacing: root.gap + Style.spacing.xs
                // Qualified: a bare `columns` resolves to the process table's id.
                readonly property real cellW: (width - spacing * (gpuGrid.columns - 1)) / gpuGrid.columns

                Repeater {
                  model: root.host.gpus || []
                  PerfCard {
                    required property var modelData
                    required property int index
                    width: gpuGrid.cellW
                    glyph: "\uf108"
                    title: modelData.name || "GPU"
                    value: (modelData.memUsed === null || modelData.memUsed === undefined) ? "—" : TaskModel.formatBytes(modelData.memUsed)
                    detail: TaskModel.gpuDetail(modelData)
                    history: (root.service && root.service.gpuHistories && index < root.service.gpuHistories.length)
                      ? root.service.gpuHistories[index]
                      : []
                    ink: root.heat(modelData.memPercent)
                  }
                }
              }

              Row {
                id: ioRow
                width: perfColumn.width
                spacing: root.gap + Style.spacing.xs
                readonly property real cellW: (width - spacing * 2) / 3

                PerfCard {
                  width: ioRow.cellW
                  compact: true
                  glyph: "\uf1c0"
                  title: "Memory"
                  value: TaskModel.formatBytes(root.host.memUsed)
                  detail: TaskModel.formatCpu(root.host.memPercent) + " of " + TaskModel.formatBytes(root.host.memTotal)
                  detail2: root.host.swapTotal > 0 ? "swap " + TaskModel.formatBytes(root.host.swapUsed) : ""
                  history: root.service ? root.service.memHistory : []
                  ink: root.heat(root.host.memPercent)
                }
                PerfCard {
                  width: ioRow.cellW
                  compact: true
                  glyph: "\uf0a0"
                  title: "Disk"
                  value: TaskModel.formatRate((Number(root.host.diskReadBps) || 0) + (Number(root.host.diskWriteBps) || 0))
                  detail: "read " + TaskModel.formatRate(root.host.diskReadBps)
                  detail2: "write " + TaskModel.formatRate(root.host.diskWriteBps)
                  history: root.service && root.service.diskReadHistory ? root.service.diskReadHistory : []
                  history2: root.service && root.service.diskWriteHistory ? root.service.diskWriteHistory : []
                  maxValue: 0
                }
                PerfCard {
                  width: ioRow.cellW
                  compact: true
                  glyph: "\uf0ec"
                  title: "Network"
                  value: TaskModel.formatRate((Number(root.host.netRxBps) || 0) + (Number(root.host.netTxBps) || 0))
                  detail: "down " + TaskModel.formatRate(root.host.netRxBps)
                  detail2: "up " + TaskModel.formatRate(root.host.netTxBps)
                  history: root.service && root.service.netRxHistory ? root.service.netRxHistory : []
                  history2: root.service && root.service.netTxHistory ? root.service.netTxHistory : []
                  maxValue: 0
                }
              }
            }
          }

          // ── Startup ──
          ListView {
            anchors.fill: parent
            visible: root.tab === "startup"
            clip: true
            spacing: Style.spacing.md
            model: root.startup
            boundsBehavior: Flickable.StopAtBounds
            header: Item {
              width: ListView.view ? ListView.view.width : 0
              height: startupHead.implicitHeight + root.gap + Style.spacing.sm
              Row {
                id: startupHead
                spacing: Style.spacing.md
                Glyph {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\uf05a"
                  color: root.accent
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.startupEnabled + " of " + root.startup.length + " enabled  ·  XDG autostart, read only. A user Hidden entry overrides the system copy."
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
            delegate: Rectangle {
              id: startRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: root.listRowHeight + Style.spacing.lg
              radius: root.innerRadius
              color: startMouse.containsMouse ? root.surfaceHot : root.surface
              border.width: 1
              border.color: root.hairline

              MouseArea { id: startMouse; anchors.fill: parent; hoverEnabled: true }

              Rectangle {
                id: startAvatar
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(28)
                height: width
                radius: root.softRadius
                color: Util.alpha(startRow.modelData.enabled ? root.accent : root.foreground, startRow.modelData.enabled ? 0.16 : 0.07)
                Text {
                  anchors.centerIn: parent
                  text: root.initial(startRow.modelData.name)
                  color: startRow.modelData.enabled ? root.accent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
              Column {
                anchors.left: startAvatar.right
                anchors.leftMargin: Style.spacing.xl
                anchors.right: startTags.left
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs
                Text {
                  width: parent.width
                  text: startRow.modelData.name
                  color: startRow.modelData.enabled ? root.foreground : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: startRow.modelData.exec || startRow.modelData.file
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Row {
                id: startTags
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(20)
                  width: sourceText.implicitWidth + Style.spacing.lg * 2
                  radius: root.softRadius
                  color: Util.alpha(root.foreground, 0.06)
                  Text {
                    id: sourceText
                    anchors.centerIn: parent
                    text: String(startRow.modelData.source || "").toUpperCase()
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: Style.space(1)
                  }
                }
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(20)
                  width: stateRow.implicitWidth + Style.spacing.lg * 2
                  radius: root.softRadius
                  color: startRow.modelData.enabled ? Util.alpha(root.accent, 0.16) : "transparent"
                  border.width: 1
                  border.color: startRow.modelData.enabled ? Util.alpha(root.accent, 0.45) : root.hairline
                  Row {
                    id: stateRow
                    anchors.centerIn: parent
                    spacing: Style.spacing.sm
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(6); height: width; radius: width / 2
                      color: startRow.modelData.enabled ? root.accent : root.muted
                    }
                    Text {
                      text: startRow.modelData.enabled ? "Enabled" : "Disabled"
                      color: startRow.modelData.enabled ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }
        }

        // ── Footer: key hints + actions (Processes only) ──
        Item {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: endButton.implicitHeight
          visible: root.tab === "processes"

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xl
            Repeater {
              model: [
                { k: "↑↓", t: "select" },
                { k: "Enter", t: "expand" },
                { k: "/", t: "search" },
                { k: "Del", t: "end" },
                { k: "Esc", t: "close" }
              ]
              Row {
                required property var modelData
                spacing: Style.spacing.sm
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(18)
                  width: Math.max(height, keyText.implicitWidth + Style.spacing.md * 2)
                  radius: root.softRadius
                  color: Util.alpha(root.foreground, 0.06)
                  border.width: 1
                  border.color: root.hairline
                  Text {
                    id: keyText
                    anchors.centerIn: parent
                    text: modelData.k
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.t
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md
            TabButton {
              id: forceButton
              text: "Force end"
              iconText: "\uf0e7"
              visible: root.armedPid !== 0 || root.armedGroupKey !== ""
              enabled: root.canForce
              opacity: enabled ? 1 : 0.4
              accent: root.danger
              foreground: root.danger
              onClicked: root.askEnd("KILL")
            }
            TabButton {
              id: endButton
              text: "End task"
              iconText: "\uf011"
              enabled: root.canEnd
              opacity: enabled ? 1 : 0.4
              accent: root.danger
              foreground: root.danger
              onClicked: root.askEnd("TERM")
            }
          }
        }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.confirmOpen
          message: root.confirmMessage
          confirmText: root.pendingSignal === "KILL" ? "Force end" : "End task"
          cancelText: "Cancel"
          foreground: root.foreground
          background: root.background
          fontFamily: root.fontFamily
          onCanceled: root.confirmOpen = false
          onConfirmed: root.confirmEnd()
        }
      }
    }
  }
}
