// Sort, filter, and display helpers for the Task Manager overlay.
// Pure on purpose: node tests this file, and the QML only renders the result.

var SORT_KEYS = {
  name: true,
  status: true,
  cpu: true,
  gpu: true,
  memBytes: true,
  pid: true,
  user: true
}

function formatBytes(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) n = 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  var digits = i === 0 || n >= 100 ? 0 : (n >= 10 ? 1 : 2)
  return n.toFixed(digits) + " " + units[i]
}

function formatRate(value) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return formatBytes(value) + "/s"
}

function formatCpu(value) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return Number(value).toFixed(1) + "%"
}

function formatGpu(row) {
  if (!row) return "—"
  var mem = Number(row.gpuMemBytes)
  if (!isFinite(mem) || mem <= 0) return "—"
  return formatBytes(mem)
}

function gpuDetail(row) {
  if (!row) return "—"
  var busy = "Busy " + formatCpu(row.busyPercent)
  var total = row.memTotal
  var share = (total === null || total === undefined) ? "" : (" of " + formatBytes(total))
  var temp = (row.tempC === null || row.tempC === undefined || !isFinite(Number(row.tempC))) ? "" : ("   " + Math.round(Number(row.tempC)) + "°C")
  return busy + share + temp
}

function gpuHeader(gpus) {
  var list = gpus || []
  if (!list.length) return ""
  var parts = []
  for (var i = 0; i < list.length; i++) {
    var gpu = list[i] || {}
    var label = list.length === 1 ? "GPU" : (gpu.shortName || "GPU")
    var used = gpu.memUsed
    var text = (used === null || used === undefined || !isFinite(Number(used))) ? "—" : formatBytes(used)
    parts.push(label + " " + text)
  }
  return parts.join("   ")
}

function formatUptime(seconds) {
  var sec = Math.floor(Number(seconds) || 0)
  if (sec < 0) sec = 0
  var days = Math.floor(sec / 86400)
  var hours = Math.floor((sec % 86400) / 3600)
  var minutes = Math.floor((sec % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

function matches(row, query, kind) {
  if (!row) return false
  if (kind && kind !== "all" && row.kind !== kind) return false
  var q = String(query || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (!q) return true
  var haystack = [
    row.name, row.user, row.status, row.windowTitle, row.cmdline, row.gpuNote, String(row.pid)
  ].join(" ").toLowerCase()
  return haystack.indexOf(q) !== -1
}

function compare(a, b, key, desc) {
  var av = key === "gpu" ? gpuSortValue(a) : (a ? a[key] : null)
  var bv = key === "gpu" ? gpuSortValue(b) : (b ? b[key] : null)
  var emptyA = av === null || av === undefined || av === ""
  var emptyB = bv === null || bv === undefined || bv === ""
  var c = 0
  var missing = emptyA || emptyB
  if (emptyA && emptyB) c = 0
  else if (emptyA) c = 1
  else if (emptyB) c = -1
  else if (typeof av === "string" || typeof bv === "string") {
    c = String(av).toLowerCase().localeCompare(String(bv).toLowerCase())
  } else {
    c = Number(av) - Number(bv)
    if (!isFinite(c)) c = 0
  }
  if (!missing && desc) c = -c
  if (c === 0) c = Number(a.pid) - Number(b.pid)
  return c
}

function gpuSortValue(row) {
  if (!row) return null
  var mem = Number(row.gpuMemBytes)
  if (!isFinite(mem) || mem <= 0) return null
  return mem
}

function baseName(row) {
  var name = String(row && row.name || "").replace(/^\s+|\s+$/g, "")
  var cut = name.indexOf(" — ")
  if (cut > 0) name = name.slice(0, cut).replace(/\s+$/g, "")
  return name
}

function groupKey(row) {
  var name = baseName(row).toLowerCase()
  if (name) return name
  return "pid:" + String(row && row.pid)
}

function round1(value) {
  return Math.round(value * 10) / 10
}

function summarize(items) {
  var cpu = null
  var gpu = null
  var mem = 0
  var gpuMem = 0
  var running = false
  var user = items[0] ? items[0].user : ""
  var sameUser = true
  var titled = null
  var lead = items[0]
  var minPid = items[0] ? items[0].pid : 0
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (typeof item.cpu === "number" && isFinite(item.cpu)) cpu = (cpu || 0) + item.cpu
    if (item.gpuKnown && typeof item.gpu === "number" && isFinite(item.gpu)) gpu = (gpu || 0) + item.gpu
    mem += Number(item.memBytes) || 0
    gpuMem += Number(item.gpuMemBytes) || 0
    if (item.state === "R") running = true
    if (item.user !== user) sameUser = false
    if (item.windowTitle && !titled) titled = item
    if (lead && typeof item.cpu === "number" && (typeof lead.cpu !== "number" || item.cpu > lead.cpu)) lead = item
    if (Number(item.pid) < Number(minPid)) minPid = item.pid
  }
  var titleSource = titled || lead || items[0]
  var title = baseName(titleSource) || String(titleSource && titleSource.name || "?")
  if (titled && titled.windowTitle && String(titled.windowTitle).toLowerCase() !== String(baseName(titled)).toLowerCase()) title = title + " — " + titled.windowTitle
  return {
    cpu: cpu === null ? null : round1(cpu),
    gpu: gpu === null ? null : round1(gpu),
    gpuKnown: gpu !== null,
    gpuMemBytes: gpuMem,
    memBytes: mem,
    status: running ? "Running" : (items[0].status || ""),
    state: running ? "R" : (items[0].state || ""),
    user: sameUser ? user : "—",
    name: title,
    pid: minPid
  }
}

function processEntry(row, depth, grouped) {
  var name = baseName(row) || String(row.name || "?")
  if (!grouped && row.windowTitle) name = name + " — " + row.windowTitle
  return {
    type: "process",
    id: "p:" + row.pid,
    expandable: false,
    expanded: false,
    depth: depth,
    groupKey: groupKey(row),
    name: name,
    status: row.status || "",
    state: row.state || "",
    cpu: row.cpu,
    gpu: row.gpu,
    gpuKnown: !!row.gpuKnown,
    gpuMemBytes: row.gpuMemBytes || 0,
    gpuNote: row.gpuNote || "",
    memBytes: row.memBytes || 0,
    pid: row.pid,
    user: row.user || "",
    windowTitle: row.windowTitle || "",
    cmdline: row.cmdline || "",
    protected: !!row.protected,
    protectReason: row.protectReason || "",
    starttime: row.starttime,
    count: 1
  }
}

function isOpen(key, expanded, query) {
  if (String(query || "").replace(/^\s+|\s+$/g, "") !== "") return true
  var list = expanded || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] === key) return true
  }
  return false
}

function visibleRows(processes, query, kind, sortKey, sortDesc, expanded) {
  var key = SORT_KEYS[sortKey] ? sortKey : "cpu"
  var desc = sortDesc !== false
  var matched = []
  var source = processes || []
  for (var i = 0; i < source.length; i++) {
    if (matches(source[i], query, kind)) matched.push(source[i])
  }
  var buckets = {}
  var order = []
  for (var j = 0; j < matched.length; j++) {
    var row = matched[j]
    var gkey = groupKey(row)
    if (!buckets[gkey]) {
      buckets[gkey] = []
      order.push(gkey)
    }
    buckets[gkey].push(row)
  }
  var groups = []
  for (var g = 0; g < order.length; g++) {
    var items = buckets[order[g]]
    items.sort(function(a, b) { return compare(a, b, key, desc) })
    var summary = summarize(items)
    groups.push({ key: order[g], items: items, summary: summary })
  }
  groups.sort(function(a, b) {
    return compare(
      { cpu: a.summary.cpu, gpu: a.summary.gpu, gpuKnown: a.summary.gpuKnown, gpuMemBytes: a.summary.gpuMemBytes, memBytes: a.summary.memBytes, name: a.summary.name, status: a.summary.status, user: a.summary.user, pid: a.summary.pid },
      { cpu: b.summary.cpu, gpu: b.summary.gpu, gpuKnown: b.summary.gpuKnown, gpuMemBytes: b.summary.gpuMemBytes, memBytes: b.summary.memBytes, name: b.summary.name, status: b.summary.status, user: b.summary.user, pid: b.summary.pid },
      key, desc)
  })
  var out = []
  for (var n = 0; n < groups.length; n++) {
    var group = groups[n]
    if (group.items.length === 1) {
      out.push(processEntry(group.items[0], 0, false))
      continue
    }
    var open = isOpen(group.key, expanded, query)
    var endableTargets = []
    var allProtected = true
    var protectReason = ""
    for (var m = 0; m < group.items.length; m++) {
      var item = group.items[m]
      if (item.protected) {
        if (!protectReason) protectReason = item.protectReason
      } else {
        allProtected = false
        endableTargets.push({ pid: item.pid, starttime: item.starttime })
      }
    }
    out.push({
      type: "group",
      id: "g:" + group.key,
      expandable: true,
      expanded: open,
      depth: 0,
      groupKey: group.key,
      name: group.summary.name,
      status: group.summary.status,
      state: group.summary.state,
      cpu: group.summary.cpu,
      gpu: group.summary.gpu,
      gpuKnown: group.summary.gpuKnown,
      gpuMemBytes: group.summary.gpuMemBytes,
      gpuNote: "",
      memBytes: group.summary.memBytes,
      pid: 0,
      user: group.summary.user,
      windowTitle: "",
      cmdline: "",
      protected: allProtected,
      protectReason: allProtected ? (protectReason || "Protected processes.") : "",
      starttime: -1,
      count: group.items.length,
      targets: endableTargets
    })
    if (open) {
      for (var c = 0; c < group.items.length; c++) out.push(processEntry(group.items[c], 1, true))
    }
  }
  return out
}

function matchCount(processes, query, kind) {
  var count = 0
  var source = processes || []
  for (var i = 0; i < source.length; i++) {
    if (matches(source[i], query, kind)) count++
  }
  return count
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatCpu: formatCpu,
    formatGpu: formatGpu,
    gpuDetail: gpuDetail,
    gpuHeader: gpuHeader,
    formatUptime: formatUptime,
    matches: matches,
    visibleRows: visibleRows,
    matchCount: matchCount
  }
}
