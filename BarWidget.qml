import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar presence: a chart icon, not a CPU readout. Left click opens the overlay.
// Hover still carries the live CPU and memory figures.
BarWidget {
  id: root
  moduleName: "io.github.murali-lns.task-manager"

  readonly property var taskService: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName)
    : null
  readonly property real cpuPercent: root.taskService ? root.taskService.cpuPercent : -1
  readonly property real memPercent: root.taskService ? root.taskService.memPercent : -1
  readonly property real gpuPercent: root.taskService ? root.taskService.gpuPercent : -1
  readonly property string tooltip: {
    var gpu = root.taskService && root.taskService.gpuTip ? ", " + root.taskService.gpuTip : ""
    if (root.cpuPercent < 0 && !gpu)
      return "Task Manager — Super+Delete"
    var cpu = root.cpuPercent < 0 ? "—" : Math.round(root.cpuPercent) + "%"
    var mem = root.memPercent < 0 ? "—" : Math.round(root.memPercent) + "%"
    return "Task Manager — CPU " + cpu + gpu + ", memory " + mem
  }

  function toggleOverlay() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function") {
      root.bar.shell.toggle(root.moduleName, "{}")
      return
    }
    if (root.bar) root.bar.run("omarchy-shell shell toggle " + root.moduleName)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Font Awesome chart-bar: a task-manager mark, not a CPU chip.
  // Todo already uses the checklist glyph, so this stays distinct beside it.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf080"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    active: root.cpuPercent >= 85 || root.gpuPercent >= 85
    // High load stays in the tooltip. The bar glyph keeps the normal color.
    useActiveColor: false
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggleOverlay()
    }
  }
}
