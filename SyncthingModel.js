// Parsing and derivation for the Syncthing panel.
//
// Everything here is a pure function over strings and plain objects so the
// whole thing can be exercised under node against captured API responses
// (see test/run.js). The QML side only ever hands this module text and reads
// the result back out.

// curl joins batched responses with a record separator (-w $'\x1e', one per
// response). Split and parse, tolerating bodies that are not JSON: Syncthing
// answers a paused folder's completion query with bare text, and a rejected
// key answers everything with "Forbidden".
function splitRecords(raw) {
  var text = String(raw == null ? "" : raw)
  if (text === "") return []
  var parts = text.split("\u001e")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var chunk = parts[i].trim()
    if (chunk === "") continue
    out.push(safeParse(chunk))
  }
  return out
}

function safeParse(chunk) {
  try {
    var value = JSON.parse(chunk)
    return isPlainObject(value) ? value : null
  } catch (e) {
    return null
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function str(value, fallback) {
  if (value === undefined || value === null) return fallback === undefined ? "" : fallback
  return String(value)
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// A directory watch that dies takes the folder down with it, and the folder
// status payload reports it separately from a pull error.
function folderErrorText(db) {
  if (!db) return ""
  var direct = str(db.error).trim()
  if (direct !== "") return direct
  var watch = str(db.watchError).trim()
  if (watch !== "") return watch
  var pulls = num(db.pullErrors)
  if (pulls > 0) return pulls + (pulls === 1 ? " pull error" : " pull errors")
  var errors = num(db.errors)
  if (errors > 0) return errors + (errors === 1 ? " error" : " errors")
  return ""
}

function folderProgress(db) {
  if (!isPlainObject(db)) return 0
  var globalBytes = num(db.globalBytes)
  var needBytes = num(db.needBytes)
  if (globalBytes > 0) return clamp(1 - needBytes / globalBytes, 0, 1)
  // Nothing byte-sized to go on (an empty folder, or one still counting its
  // first index): fall back to item counts, and treat "nothing needed" as done.
  var globalItems = num(db.globalTotalItems)
  if (globalItems > 0) return clamp(1 - num(db.needTotalItems) / globalItems, 0, 1)
  return num(db.needTotalItems) > 0 ? 0 : 1
}

// Stands in for a folder we have no db/status for yet — the first poll after
// startup, a folder that was just added, or a batch that came back short.
function blankDb() {
  return {
    state: "",
    error: "",
    watchError: "",
    errors: 0,
    pullErrors: 0,
    needBytes: 0,
    needFiles: 0,
    needTotalItems: 0,
    globalBytes: 0,
    globalTotalItems: 0,
    receiveOnlyChangedBytes: 0
  }
}

// db/status reports state:"" and zeroes for a paused folder, so paused has to
// come from the config or it is indistinguishable from "just started".
function folderState(folder, db) {
  if (folder.paused) return "paused"
  if (folderErrorText(db) !== "") return "error"
  var state = str(db ? db.state : "", "").trim()
  if (state === "") return folder.paused ? "paused" : "unknown"
  if (state === "syncing" || state === "scanning") return state
  if (state === "idle") return "idle"
  return "unknown"
}

function folderStatusLabel(entry) {
  var db = entry.db
  if (entry.state === "paused") return "Paused"
  if (entry.state === "error") return entry.error || "Error"
  if (entry.state === "scanning") return "Scanning…"
  if (entry.state === "unknown") return "Not connected"

  var needBytes = num(db.needBytes)
  var needFiles = num(db.needFiles)
  if (entry.state === "syncing") {
    if (needBytes > 0) return "Syncing · " + formatBytes(needBytes) + " left"
    if (needFiles > 0) return "Syncing · " + needFiles + (needFiles === 1 ? " file" : " files") + " left"
    return "Syncing"
  }
  // idle, but the index still owes work.
  if (needBytes > 0) return "Pending · " + formatBytes(needBytes) + " to sync"
  if (needFiles > 0) return "Pending · " + needFiles + (needFiles === 1 ? " file" : " files")
  if (num(db.receiveOnlyChangedBytes) > 0) return "Review " + formatBytes(num(db.receiveOnlyChangedBytes)) + " of changes"
  return "Up to date"
}

// Rows for the FOLDERS section: one per configured folder, plus anything the
// cluster is waiting on that is not configured yet.
function buildFolders(config, dbByFolder, pendingFolders) {
  var out = []
  var configured = isPlainObject(config) && Array.isArray(config.folders) ? config.folders : []

  for (var i = 0; i < configured.length; i++) {
    var raw = configured[i]
    if (!isPlainObject(raw)) continue
    var id = str(raw.id)
    if (id === "") continue
    var db = isPlainObject(dbByFolder) && isPlainObject(dbByFolder[id]) ? dbByFolder[id] : blankDb()
    var folder = {
      id: id,
      label: str(raw.label) || id,
      path: str(raw.path),
      type: str(raw.type) || "sendreceive",
      paused: raw.paused === true,
      pending: false,
      db: db
    }
    folder.state = folderState(folder, db)
    folder.error = folderErrorText(db)
    folder.progress = folderState(folder, db) === "paused" ? 0 : folderProgress(db)
    folder.needBytes = num(db.needBytes)
    folder.needFiles = num(db.needFiles)
    folder.globalBytes = num(db.globalBytes)
    folder.statusLabel = folderStatusLabel(folder)
    out.push(folder)
  }

  var pending = isPlainObject(pendingFolders) ? pendingFolders : {}
  for (var key in pending) {
    if (!Object.prototype.hasOwnProperty.call(pending, key)) continue
    if (findById(out, key) !== null) continue
    var entry = isPlainObject(pending[key]) ? pending[key] : {}
    out.push({
      id: str(key),
      label: str(entry.label) || str(key),
      path: "",
      type: "pending",
      paused: false,
      pending: true,
      db: null,
      state: "pending",
      error: "",
      progress: 0,
      needBytes: 0,
      needFiles: 0,
      globalBytes: 0,
      statusLabel: "Pending approval"
    })
  }
  return out
}

function findById(list, id) {
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i]
  }
  return null
}

function deviceState(device) {
  if (device.paused) return "paused"
  if (device.pending) return "pending"
  if (device.isSelf) return "self"
  if (!device.connected) return "offline"
  return "online"
}

function deviceStatusLabel(device) {
  if (device.state === "paused") return "Paused"
  if (device.state === "pending") return "Pending approval"
  if (device.state === "self") return "This device"
  if (device.state === "offline") {
    if (device.lastSeenText !== "") return "Offline · last seen " + device.lastSeenText
    return "Offline"
  }
  if (device.connectionType !== "" && device.connectionType !== "tcp-client" && device.connectionType !== "tcp-server") {
    return "Connected · " + device.connectionType
  }
  return "Connected"
}

// Rows for the DEVICES section. The self device is included so the toggle and
// the connection list line up; it just never gets a pause button.
//

function buildDevices(config, status, connections, pendingDevices, stats) {
  var out = []
  var myId = str(isPlainObject(status) ? status.myID : "")
  var configured = isPlainObject(config) && Array.isArray(config.devices) ? config.devices : []
  var conns = isPlainObject(connections) && isPlainObject(connections.connections) ? connections.connections : {}
  var lastSeenById = isPlainObject(stats) ? stats : {}

  for (var i = 0; i < configured.length; i++) {
    var raw = configured[i]
    if (!isPlainObject(raw)) continue
    var id = str(raw.deviceID)
    if (id === "") continue
    var conn = isPlainObject(conns[id]) ? conns[id] : null
    var seen = isPlainObject(lastSeenById[id]) ? str(lastSeenById[id].lastSeen, "") : ""
    var device = {
      deviceID: id,
      name: str(raw.name) || shortId(id),
      isSelf: id !== "" && id === myId,
      paused: raw.paused === true,
      pending: false,
      connected: conn !== null && conn.connected === true,
      connectionType: conn !== null ? str(conn.type) : "",
      address: conn !== null ? str(conn.address) : "",
      clientName: conn !== null ? str(conn.clientName) : "",
      lastSeen: seen,
      lastSeenText: seen === "" ? "" : formatAgo(seen)
    }
    device.state = deviceState(device)
    device.statusLabel = deviceStatusLabel(device)
    out.push(device)
  }

  var pending = isPlainObject(pendingDevices) ? pendingDevices : {}
  for (var key in pending) {
    if (!Object.prototype.hasOwnProperty.call(pending, key)) continue
    if (findById(out, key) !== null) continue
    var entry = isPlainObject(pending[key]) ? pending[key] : {}
    var extra = {
      deviceID: str(key),
      name: str(entry.name) || shortId(str(key)),
      isSelf: false,
      paused: false,
      pending: true,
      connected: false,
      connectionType: "",
      address: "",
      clientLabel: "",
      lastSeen: "",
      lastSeenText: ""
    }
    extra.state = deviceState(extra)
    extra.statusLabel = deviceStatusLabel(extra)
    out.push(extra)
  }

  // This device first, then pending, then the rest alphabetically.
  out.sort(function (a, b) {
    return deviceOrder(a) - deviceOrder(b) || a.name.localeCompare(b.name)
  })
  return out
}

function deviceOrder(device) {
  if (device.isSelf) return 0
  if (device.pending) return 1
  return 2
}

// One badge for the whole bar slot, worst first. Mirrors the icon's precedence
// so the panel and the bar never disagree about what state Syncthing is in.
function overallStatus(folders, devices, reachable) {
  if (!reachable) {
    return { state: "stopped", text: "Stopped", pending: false, error: false, busy: false }
  }
  var pending = false
  var error = false
  var busy = false
  var pausedCount = 0
  var i

  for (i = 0; i < devices.length; i++) {
    if (devices[i].pending) pending = true
  }
  for (i = 0; i < folders.length; i++) {
    var folder = folders[i]
    if (folder.pending) pending = true
    if (folder.state === "paused") pausedCount += 1
    if (folder.state === "error") error = true
    if (folder.state === "syncing" || folder.state === "scanning") busy = true
  }

  if (error) return { state: "error", text: "Error", pending: pending, error: true, busy: busy }
  if (pending) return { state: "pending", text: "Pending approval", pending: true, error: false, busy: busy }

  var live = Math.max(0, folders.length - pausedCount)
  if (busy) return { state: "syncing", text: "Syncing", pending: false, error: false, busy: true }
  if (folders.length > 0 && pausedCount === folders.length) {
    return { state: "paused", text: "Paused", pending: false, error: false, busy: false }
  }
  if (live === 0) return { state: "idle", text: "Up to date", pending: false, error: false, busy: false }
  return { state: "idle", text: "Up to date", pending: false, error: false, busy: false }
}

function pendingCount(folders, devices) {
  var count = 0
  var i
  for (i = 0; i < folders.length; i++) if (folders[i].pending) count += 1
  for (i = 0; i < devices.length; i++) if (devices[i].pending) count += 1
  return count
}

function errorCount(folders) {
  var count = 0
  for (var i = 0; i < folders.length; i++) {
    if (folders[i].state === "error") count += 1
  }
  return count
}

// GET /rest/noauth/health is the only endpoint that needs no API key, which
// makes it the one thing we can check without credentials or privileges.
function parseHealth(raw) {
  var text = String(raw == null ? "" : raw).trim()
  if (text === "") return { reachable: false, message: "No response" }
  var parsed = safeParse(text)
  if (parsed === null) return { reachable: false, message: "No response" }
  var status = str(parsed.status)
  if (status === "OK") return { reachable: true, message: "OK" }
  return { reachable: false, message: status === "" ? "Not ready" : status }
}

// The API key lives in the GUI section of the container's config.xml. Reading
// it from disk keeps it out of shell.json, which is world-readable.
function readApiKey(xml) {
  var text = String(xml == null ? "" : xml)
  var match = text.match(/<apikey>([^<]*)<\/apikey>/)
  if (match === null) return ""
  return match[1].trim()
}

// Tolerant to "~" and to a relative path, which is how users will type it into
// `omarchy bar set`.
function expandPath(path, home) {
  var value = str(path).trim()
  if (value === "") return ""
  var base = str(home, "")
  if (value === "~") return base
  if (value.indexOf("~/") === 0) return base + value.slice(1)
  return value
}

function shortId(id) {
  var text = str(id)
  if (text.length <= 7) return text
  return text.substring(0, 7)
}

// ---------- formatting ----------

function formatBytes(bytes) {
  var value = num(bytes)
  if (value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var index = 0
  var scaled = value
  while (scaled >= 1024 && index < units.length - 1) {
    scaled /= 1024
    index += 1
  }
  var digits = scaled >= 100 || index === 0 ? 0 : (scaled >= 10 ? 1 : 2)
  return scaled.toFixed(digits) + " " + units[index]
}

// Syncthing hands back RFC3339 with a Z; Safari-grade Date parsing is not
// assumed, so the offset is normalised to an explicit UTC parse.
function parseTime(value) {
  var text = str(value).trim()
  if (text === "") return NaN
  if (text.indexOf("0001-01-01") === 0) return NaN
  var normalized = text.replace(/Z$/, "+00:00")
  var stamp = Date.parse(normalized)
  if (isNaN(stamp)) stamp = Date.parse(text)
  return stamp
}

function formatAgo(value, nowMs) {
  var stamp = typeof value === "number" ? value : parseTime(value)
  if (isNaN(stamp)) return ""
  var now = typeof nowMs === "number" ? nowMs : Date.now()
  var seconds = Math.max(0, Math.floor((now - stamp) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + (minutes === 1 ? " min ago" : " min ago")
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

function formatUptime(seconds) {
  var total = Math.max(0, Math.floor(num(seconds)))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (days > 0) return days + (days === 1 ? "d " : "d ") + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

function elide(text, limit) {
  var value = String(text == null ? "" : text).replace(/\s+/g, " ").trim()
  var max = num(limit) || 80
  if (value.length <= max) return value
  return value.substring(0, max - 1) + "…"
}
