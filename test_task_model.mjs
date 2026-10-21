import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { test } from "node:test"

const require = createRequire(import.meta.url)
const TaskModel = require("./TaskModel.js")

const rows = [
  { pid: 2, name: "sleep", user: "alpha", status: "Sleeping", kind: "background", cpu: 0.2, memBytes: 1000, windowTitle: "", cmdline: "/usr/bin/sleep 30" },
  { pid: 9, name: "firefox", user: "alpha", status: "Running", kind: "app", cpu: 12.5, memBytes: 500000000, windowTitle: "Docs", cmdline: "/usr/bin/firefox" },
  { pid: 4, name: "quickshell", user: "alpha", status: "Sleeping", kind: "background", cpu: null, memBytes: 80000000, windowTitle: "", cmdline: "quickshell" }
]

test("formatBytes and rates stay readable", () => {
  assert.equal(TaskModel.formatBytes(0), "0 B")
  assert.equal(TaskModel.formatBytes(1536), "1.50 KB")
  assert.equal(TaskModel.formatBytes(1024 * 1024 * 1024), "1.00 GB")
  assert.equal(TaskModel.formatRate(null), "—")
  assert.equal(TaskModel.formatRate(2048), "2.00 KB/s")
  assert.equal(TaskModel.formatCpu(null), "—")
  assert.equal(TaskModel.formatCpu(3.26), "3.3%")
})

test("gpu header and detail name each card", () => {
  assert.equal(TaskModel.gpuHeader([]), "")
  assert.equal(TaskModel.gpuHeader([{ memUsed: 180 * 1024 * 1024, shortName: "AMD" }]), "GPU 180 MB")
  assert.equal(TaskModel.gpuHeader([
    { memUsed: 180 * 1024 * 1024, shortName: "AMD" },
    { memUsed: null, shortName: "NVIDIA" }
  ]), "AMD 180 MB   NVIDIA —")
  assert.equal(TaskModel.gpuDetail({
    busyPercent: 0,
    memUsed: 511 * 1024 * 1024,
    memTotal: 4 * 1024 * 1024 * 1024,
    tempC: 66
  }), "Busy 0.0% of 4.00 GB   66°C")
  assert.equal(TaskModel.gpuDetail({ memTotal: null, tempC: null }), "Busy —")
  assert.equal(TaskModel.formatGpu(null), "—")
  assert.equal(TaskModel.formatGpu({ gpu: 25, gpuKnown: true, gpuMemBytes: 12 * 1024 }), "12.0 KB")
  assert.equal(TaskModel.formatGpu({ gpu: null, gpuKnown: false, gpuMemBytes: 508 * 1024 * 1024 }), "508 MB")
  assert.equal(TaskModel.formatGpu({ gpu: 0, gpuKnown: true, gpuMemBytes: 0 }), "—")
  const ranked = TaskModel.visibleRows([
    { pid: 1, name: "idle", user: "a", status: "Sleeping", kind: "background", cpu: 9, gpu: 80, gpuKnown: true, gpuMemBytes: 1024, memBytes: 1 },
    { pid: 2, name: "holder", user: "a", status: "Sleeping", kind: "background", cpu: 0, gpu: null, gpuKnown: false, gpuMemBytes: 508 * 1024 * 1024, memBytes: 1 }
  ], "", "all", "gpu", true, [])
  assert.deepEqual(ranked.map((row) => row.pid), [2, 1])
})

test("formatUptime uses the largest useful unit", () => {
  assert.equal(TaskModel.formatUptime(90), "1m")
  assert.equal(TaskModel.formatUptime(3700), "1h 1m")
  assert.equal(TaskModel.formatUptime(90000), "1d 1h")
})

test("same-name processes collapse until the group is expanded", () => {
  const hermes = [
    { pid: 10, name: "Hermes", user: "alpha", status: "Running", state: "R", kind: "background", cpu: 3.5, memBytes: 100, windowTitle: "", cmdline: "hermes", starttime: 100 },
    { pid: 11, name: "hermes", user: "alpha", status: "Sleeping", state: "S", kind: "background", cpu: 0.2, memBytes: 50, windowTitle: "", cmdline: "hermes", starttime: 101 },
    { pid: 12, name: "Hermes", user: "alpha", status: "Running", state: "R", kind: "app", cpu: 0.6, memBytes: 80, windowTitle: "Hermes", cmdline: "hermes", starttime: 102 },
    { pid: 9, name: "firefox", user: "alpha", status: "Running", state: "R", kind: "app", cpu: 1, memBytes: 10, windowTitle: "Docs", cmdline: "firefox", starttime: 90 }
  ]
  const collapsed = TaskModel.visibleRows(hermes, "", "all", "cpu", true, [])
  assert.equal(collapsed.filter((row) => row.groupKey === "hermes" && row.type === "group").length, 1)
  assert.equal(collapsed.filter((row) => row.groupKey === "hermes" && row.type === "process").length, 0)
  const group = collapsed.find((row) => row.id === "g:hermes")
  assert.equal(group.expandable, true)
  assert.equal(group.expanded, false)
  assert.equal(group.count, 3)
  assert.equal(group.cpu, 4.3)
  assert.equal(group.memBytes, 230)
  assert.equal(group.name, "Hermes")
  assert.equal(group.pid, 0)
  assert.deepEqual(group.targets, [
    { pid: 10, starttime: 100 },
    { pid: 12, starttime: 102 },
    { pid: 11, starttime: 101 }
  ])

  const open = TaskModel.visibleRows(hermes, "", "all", "cpu", true, ["hermes"])
  assert.deepEqual(
    open.filter((row) => row.groupKey === "hermes" && row.type === "process").map((row) => row.pid),
    [10, 12, 11]
  )
  assert.equal(open.find((row) => row.pid === 10).depth, 1)

  const searched = TaskModel.visibleRows(hermes, "docs", "all", "cpu", true, [])
  assert.deepEqual(searched.map((row) => row.pid), [9])
})

test("visibleRows filters kind and search, and sorts cpu with nulls last", () => {
  const apps = TaskModel.visibleRows(rows, "", "app", "cpu", true)
  assert.deepEqual(apps.map((row) => row.pid), [9])

  const found = TaskModel.visibleRows(rows, "docs", "all", "name", false)
  assert.deepEqual(found.map((row) => row.pid), [9])

  const byCpu = TaskModel.visibleRows(rows, "", "all", "cpu", true)
  assert.deepEqual(byCpu.map((row) => row.pid), [9, 2, 4])
})
