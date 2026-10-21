import Quickshell
import Quickshell.Io
import QtQuick

// Keeps one local snapshot for the bar and the overlay.
// The bar reads host totals through the plugin service facade. The overlay
// sets `detail` so the same poller also walks processes — no second sampler.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.murali-lns.task-manager"
  readonly property string python: "/usr/bin/python3"
  readonly property string script: Qt.resolvedUrl("bin/taskman.py").toString().replace(/^file:\/\//, "")

  property bool detail: false
  property int revision: 0
  property int endRevision: 0
  property string errorText: ""
  property string endError: ""
  property var host: ({})
  property var processes: []
  property var startup: []
  property var cpuHistory: []
  property var memHistory: []
  property var gpuHistories: []
  property var diskReadHistory: []
  property var diskWriteHistory: []
  property var netRxHistory: []
  property var netTxHistory: []
  property bool pollQueued: false

  readonly property real cpuPercent: (root.host && typeof root.host.cpuPercent === "number") ? root.host.cpuPercent : -1
  readonly property real memPercent: (root.host && typeof root.host.memPercent === "number") ? root.host.memPercent : -1
  readonly property real gpuPercent: {
    var list = (root.host && root.host.gpus) ? root.host.gpus : []
    var max = -1
    for (var i = 0; i < list.length; i++) {
      var value = list[i] && list[i].memPercent
      if (typeof value === "number" && isFinite(value) && value > max) max = value
    }
    return max
  }
  readonly property string gpuTip: {
    var list = (root.host && root.host.gpus) ? root.host.gpus : []
    if (!list.length) return ""
    var parts = []
    for (var i = 0; i < list.length; i++) {
      var gpu = list[i] || {}
      var label = list.length === 1 ? "GPU" : (gpu.shortName || "GPU")
      var used = gpu.memUsed
      var text = (typeof used === "number" && isFinite(used)) ? Math.round(used / (1024 * 1024)) + " MB" : "—"
      parts.push(label + " " + text)
    }
    return parts.join(", ")
  }

  Timer {
    interval: root.detail ? 2000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  function poll() {
    if (pollProcess.running) {
      root.pollQueued = true
      return
    }
    var cmd = [root.python, root.script, "snapshot"]
    if (root.detail) cmd.push("--detail")
    pollProcess.command = cmd
    pollProcess.running = true
  }

  function pushHistory(current, value) {
    if (typeof value !== "number" || !isFinite(value)) return current
    var next = (current || []).concat([value])
    if (next.length > 48) next = next.slice(next.length - 48)
    return next
  }

  function pushGpuHistories(gpus) {
    var list = gpus || []
    var next = []
    var prev = root.gpuHistories || []
    for (var i = 0; i < list.length; i++) {
      var used = list[i] ? list[i].memPercent : null
      next.push(root.pushHistory(prev[i] || [], used))
    }
    return next
  }

  function handleSnapshot(raw) {
    var payload = null
    try { payload = JSON.parse(raw || "") } catch (e) { payload = null }
    if (!payload || payload.ok !== true) {
      root.errorText = payload && payload.error ? String(payload.error) : "Could not read process snapshot."
      console.warn("task-manager snapshot failed")
      return
    }
    root.errorText = ""
    root.host = payload.host || ({})
    if (payload.detail) {
      root.processes = payload.processes || []
      root.startup = payload.startup || []
    }
    root.cpuHistory = root.pushHistory(root.cpuHistory, root.host.cpuPercent)
    root.memHistory = root.pushHistory(root.memHistory, root.host.memPercent)
    root.gpuHistories = root.pushGpuHistories(root.host.gpus)
    root.diskReadHistory = root.pushHistory(root.diskReadHistory, root.host.diskReadBps)
    root.diskWriteHistory = root.pushHistory(root.diskWriteHistory, root.host.diskWriteBps)
    root.netRxHistory = root.pushHistory(root.netRxHistory, root.host.netRxBps)
    root.netTxHistory = root.pushHistory(root.netTxHistory, root.host.netTxBps)
    root.revision += 1
  }

  function requestEnd(pid, starttime, signalName, targets) {
    if (endProcess.running) return "busy"
    var sig = signalName === "KILL" ? "KILL" : "TERM"
    var cmd = [root.python, root.script, "end", "--signal", sig]
    if (targets && targets.length > 0) {
      cmd.push("--targets", JSON.stringify(targets))
    } else {
      cmd.push("--pid", String(pid), "--starttime", String(starttime))
    }
    endProcess.command = cmd
    endProcess.running = true
    return "ok"
  }

  function handleEnd(raw) {
    var payload = null
    try { payload = JSON.parse(raw || "") } catch (e) { payload = null }
    if (!payload || payload.ok !== true) {
      root.endError = payload && payload.error ? String(payload.error) : "Could not end that task."
      console.warn("task-manager end refused")
    } else {
      root.endError = ""
    }
    root.endRevision += 1
    root.poll()
  }

  Process {
    id: pollProcess
    stdout: StdioCollector {
      id: pollOut
      waitForEnd: true
      onStreamFinished: {
        root.handleSnapshot(pollOut.text)
        if (root.pollQueued) {
          root.pollQueued = false
          root.poll()
        }
      }
    }
  }

  Process {
    id: endProcess
    stdout: StdioCollector {
      id: endOut
      waitForEnd: true
      onStreamFinished: root.handleEnd(endOut.text)
    }
  }

  IpcHandler {
    target: root.pluginId

    function ping(): string { return "ok" }

    function pollNow(): string {
      root.poll()
      return "ok"
    }
  }
}
