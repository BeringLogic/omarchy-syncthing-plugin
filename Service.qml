import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "SyncthingModel.js" as Model

// Headless poller for the Syncthing REST API.
//
// Declared as an inline child of Panel.qml rather than a `service` manifest
// entry point. The shell only instantiates one bar widget per plugin, so
// keeping the poller inside the panel guarantees exactly one poller exists --
// a `service` kind would add a second one that keeps polling even after the
// widget is dropped from the bar.
//
// Liveness is probed through /rest/noauth/health, the one endpoint that needs no
// API key, so "is the container up" is answerable without credentials and
// without touching the Docker socket.
Item {
  id: root

  // Injected by Panel.qml from the bar's inline shell.json entry.
  property var settings: ({})

  // ---- observable state, read by Panel.qml ----
  property bool reachable: false
  property string healthMessage: ""
  property bool refreshing: false
  property string myId: ""
  property int uptimeSec: 0
  property var folders: []
  property var devices: []
  property string overallText: "Checking…"
  property string overallState: "unknown"
  property bool busy: false
  property int pendingCount: 0
  property int folderErrorCount: 0
  property string actionStatus: ""
  property string lastError: ""
  // True while a container start/stop is in flight, so the panel can colour the
  // status line without string-matching actionStatus.
  property bool starting: false

  // Optimistic container state so the switch throws the instant you click it,
  // rather than waiting for docker and then for the health probe to agree.
  // -1 means "follow reality".
  property int _desiredRunning: -1
  readonly property bool running: _desiredRunning === -1 ? reachable : (_desiredRunning === 1)

  property var _config: null
  property var _dbByFolder: ({})
  property var _connections: null
  property var _pendingDevices: null
  property var _pendingFolders: null
  property var _stats: ({})
  property var _folderIds: []
  property string _apiKey: ""

  readonly property string apiBase: String(setting("apiBase", "http://127.0.0.1:8384")).replace(/\/+$/, "")
  readonly property string apiKeyPath: String(setting("apiKeyPath", "~/docker/syncthing/var_syncthing/config/config.xml"))
  readonly property string containerName: String(setting("containerName", "syncthing"))
  readonly property string webUrl: String(setting("webUrl", "http://localhost:8384/"))
  readonly property bool usePolkit: boolSetting("usePolkit", true)
  readonly property int idleIntervalMs: intSetting("refreshIntervalSec", 15, 5, 3600) * 1000
  readonly property int busyIntervalMs: intSetting("busyIntervalSec", 3, 2, 300) * 1000
  readonly property bool hasApiKey: _apiKey !== ""
  readonly property bool busyNow: healthProcess.running || configProcess.running
    || folderProcess.running || keyProcess.running || actionProcess.running

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function boolSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    return text === "true" || text === "1" || text === "yes"
  }

  function applySettings(next) {
    if (next === null || next === undefined) return
    settings = next
  }

  // ---------- polling ----------

  // Health first: it needs no key, so it tells us whether the rest is worth
  // asking for, and it is the only signal the bar icon needs when the
  // container is down.
  function refresh() {
    if (busyNow) return
    if (!hasApiKey) refreshApiKey()
    refreshing = true
    healthProcess.running = true
    if (!watchdog.running) watchdog.start()
  }

  // Round A: everything whose URL does not depend on config, as one curl
  // process with a record separator, so six requests cost one subprocess.
  function refreshConfig() {
    if (!hasApiKey || configProcess.running) return
    var urls = [
      apiBase + "/rest/config",
      apiBase + "/rest/system/status",
      apiBase + "/rest/system/connections",
      apiBase + "/rest/cluster/pending/devices",
      apiBase + "/rest/cluster/pending/folders",
      apiBase + "/rest/stats/device"
    ]
    _batchOutput = ""
    _batchError = ""
    configProcess.command = buildCurl(urls, "GET")
    configProcess.running = true
  }

  // Round B: one db/status per folder, batched the same way. Fired from round A
  // so the folder list is at most one poll old, which is what lets a folder
  // added from another device show up here without a restart.
  function refreshFolders() {
    if (!hasApiKey || folderProcess.running) return
    if (!Model.isPlainObject(_config) || !Array.isArray(_config.folders)) return
    var ids = []
    for (var i = 0; i < _config.folders.length; i++) {
      var id = String(_config.folders[i].id || "")
      if (id !== "") ids.push(id)
    }
    if (ids.length === 0) return
    var urls = []
    for (var j = 0; j < ids.length; j++) {
      urls.push(apiBase + "/rest/db/status?folder=" + encodeURIComponent(ids[j]))
    }
    _folderIds = ids
    _folderOutput = ""
    folderProcess.command = buildCurl(urls, "GET")
    folderProcess.running = true
  }

  function buildCurl(urls, method, body) {
    var args = ["curl", "--silent", "--max-time", "6", "--no-buffer"]
    if (method === "POST") args.push("--request", "POST")
    if (method === "PUT") args.push("--request", "PUT", "--header", "Content-Type: application/json")
    if (_apiKey !== "") args.push("--header", "X-API-Key: " + _apiKey)
    args.push("--write-out", "\u001e")
    if (body !== undefined && body !== null) args.push("--data-binary", body)
    for (var i = 0; i < urls.length; i++) args.push(urls[i])
    return args
  }

  function refreshApiKey() {
    if (keyProcess.running) return
    var path = Model.expandPath(apiKeyPath, Quickshell.env("HOME"))
    if (path === "") return
    _keyOutput = ""
    keyProcess.command = ["cat", "--", path]
    keyProcess.running = true
  }

  function applyHealth(raw) {
    var parsed = Model.parseHealth(raw)
    reachable = parsed.reachable
    healthMessage = parsed.message
    // Reality caught up to the pending toggle.
    if (_desiredRunning !== -1 && reachable === (_desiredRunning === 1)) _desiredRunning = -1
  }

  function applyBatch(records, exitCode, rawText) {
    // curl without --fail still exits 0 on a 403, and every body then comes
    // back as unparseable text. A null record is the reliable tell.
    if (records.length < 6 || records[0] === null) {
      var body = String(rawText || "").toLowerCase()
      if (body.indexOf("forbidden") !== -1) {
        lastError = "Syncthing rejected the API key"
      } else if (exitCode !== 0) {
        lastError = "Could not reach " + apiBase
      }
      refreshing = false
      return
    }

    _config = records[0]
    myId = String(records[1].myID || "")
    uptimeSec = Number(records[1].uptime || 0)
    _connections = records[2]
    _pendingDevices = records[3]
    _pendingFolders = records[4]
    _stats = records[5]
    lastError = ""
    recompute()
  }

  function applyFolders(records) {
    var next = ({})
    for (var i = 0; i < _folderIds.length; i++) {
      if (Model.isPlainObject(records[i])) next[_folderIds[i]] = records[i]
    }
    _dbByFolder = next
    recompute()
    refreshing = false
  }

  function recompute() {
    if (!Model.isPlainObject(_config)) return
    folders = Model.buildFolders(_config, _dbByFolder, _pendingFolders)
    devices = Model.buildDevices(_config, { myID: myId }, _connections, _pendingDevices, _stats)
    var overall = Model.overallStatus(folders, devices, reachable)
    overallState = overall.state
    overallText = overall.text
    busy = overall.busy
    pendingCount = Model.pendingCount(folders, devices)
    folderErrorCount = Model.errorCount(folders)
  }

  // ---------- actions ----------

  // Every mutation goes through one process, so a second click while a rescan
  // is in flight is dropped instead of racing it.
  function runAction(label, command) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = label
    actionProcess.command = command
    actionProcess.running = true
  }

  function rescanFolder(folder) {
    if (!folder || !hasApiKey) return
    runAction("Rescanning " + folder.label + "…",
      buildCurl([apiBase + "/rest/db/scan?folder=" + encodeURIComponent(folder.id)], "POST"))
  }

  // Syncthing has no per-folder or per-device pause endpoint: the sub-resource
  // is read from config, one flag is flipped, and it is written back whole.
  //
  // A full /rest/config round trip is deliberately avoided. The API redacts
  // gui.apiKey on read, so posting the config back would blank the key and lock
  // the user out of their own GUI. PUT on the sub-resource leaves gui alone.
  function toggleFolderPause(folder) {
    if (!folder || !hasApiKey) return
    var body = subResource("folder", folder.id)
    if (body === null) {
      lastError = "No config entry for " + folder.label
      return
    }
    body.paused = !folder.paused
    runAction((folder.paused ? "Resuming " : "Pausing ") + folder.label + "…",
      buildCurl([apiBase + "/rest/config/folders/" + encodeURIComponent(folder.id)], "PUT",
        JSON.stringify(body)))
  }

  function toggleDevicePause(device) {
    if (!device || !hasApiKey) return
    var body = subResource("device", device.deviceID)
    if (body === null) {
      lastError = "No config entry for " + device.name
      return
    }
    body.paused = !device.paused
    runAction((device.paused ? "Resuming " : "Pausing ") + device.name + "…",
      buildCurl([apiBase + "/rest/config/devices/" + encodeURIComponent(device.deviceID)], "PUT",
        JSON.stringify(body)))
  }

  // A deep copy, so the cached config is never mutated by a pending toggle and
  // a failed PUT cannot desync what the panel believes.
  function subResource(kind, id) {
    if (!Model.isPlainObject(_config)) return null
    var list = kind === "folder" ? _config.folders : _config.devices
    if (!Array.isArray(list)) return null
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!Model.isPlainObject(entry)) continue
      var key = kind === "folder" ? entry.id : entry.deviceID
      if (String(key || "") === id) return JSON.parse(JSON.stringify(entry))
    }
    return null
  }

  function toggleRunning() {
    if (actionProcess.running) return
    var want = !running
    _desiredRunning = want ? 1 : 0
    starting = want
    var command = usePolkit
      ? ["pkexec", "docker", want ? "start" : "stop", containerName]
      : ["docker", want ? "start" : "stop", containerName]
    runAction((want ? "Starting " : "Stopping ") + containerName + "…", command)
  }

  function openWebUi() {
    if (webUrl === "") return
    Quickshell.execDetached(["omarchy-launch-browser", webUrl])
  }

  // A device ID is the one thing a user has to transcribe by hand when writing
  // config on another machine, so the copy button is worth a toast confirming
  // it landed -- a bare clipboard write is invisible and unfalsifiable.
  function copyDeviceId(device) {
    if (!device || !device.deviceID) return
    var id = device.deviceID
    Quickshell.execDetached([
      "bash", "-c",
      "wl-copy -- " + Model.shellQuote(id) +
        " && omarchy-notification-send " + Model.shellQuote(id + " copied to the clipboard")
    ])
  }

  onApiKeyPathChanged: _apiKey = ""
  onApiBaseChanged: _apiKey = ""

  Component.onCompleted: refresh()

  // ---------- schedule ----------

  Timer {
    id: pollTimer
    interval: root.busy ? root.busyIntervalMs : root.idleIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Every poll is skipped while its own process is still running, so one that
  // never exits would silently stop the panel updating and stay stopped. Reap
  // anything still alive well inside the slowest interval.
  Timer {
    id: watchdog
    interval: Math.max(8000, root.busyIntervalMs)
    repeat: false
    onTriggered: {
      if (healthProcess.running) healthProcess.running = false
      if (configProcess.running) configProcess.running = false
      if (folderProcess.running) folderProcess.running = false
    }
  }

  Timer {
    id: delayedRefresh
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2400
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // ---------- processes ----------

  Process {
    id: healthProcess
    running: false
    command: ["curl", "--silent", "--max-time", "4", root.apiBase + "/rest/noauth/health"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyHealth(text) }
    onExited: function() {
      // Chain into the authenticated round only when there is a server to ask.
      if (root.reachable) root.refreshConfig()
      else {
        root.refreshing = false
        root.recompute()
      }
    }
  }

  Process {
    id: keyProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._keyOutput = text }
    onExited: function(exitCode) {
      var found = Model.readApiKey(root._keyOutput)
      if (found !== "") {
        root._apiKey = found
        root.lastError = ""
      } else if (exitCode !== 0) {
        root.lastError = "Could not read " + root.apiKeyPath
      } else {
        root.lastError = "No <apikey> in " + root.apiKeyPath
      }
      // Retry now that a key may be available.
      Qt.callLater(function() { root.refresh() })
    }
  }

  Process {
    id: configProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._batchOutput = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root._batchError = text }
    onExited: function(exitCode) {
      root.applyBatch(Model.splitRecords(root._batchOutput), exitCode, root._batchOutput)
      root.refreshFolders()
    }
  }

  Process {
    id: folderProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._folderOutput = text }
    onExited: function() {
      root.applyFolders(Model.splitRecords(root._folderOutput))
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        // A dismissed polkit prompt is the common failure here, and pkexec's
        // "not authorized" message is worth showing verbatim.
        root.lastError = Model.elide(root._actionError || root._actionOutput || "Command failed", 90)
        root._desiredRunning = -1
      }
      root.starting = false
      root.actionStatus = ""
      actionStatusTimer.restart()
      delayedRefresh.restart()
    }
  }

  property string _batchOutput: ""
  property string _batchError: ""
  property string _folderOutput: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _keyOutput: ""
}
