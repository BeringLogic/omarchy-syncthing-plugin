// Exercises SyncthingModel.js against captured API responses.
//
//   node test/run.js
//
// The fixtures under test/fixtures/ are raw bodies pulled from a live
// Syncthing v2.1.5 in Docker. Re-capture them with the commands in
// test/fixtures/README.md when the API shape moves.

const fs = require("fs");
const path = require("path");

const FIXTURES = path.join(__dirname, "fixtures");
const read = (name) => fs.readFileSync(path.join(FIXTURES, name), "utf8");
const json = (name) => JSON.parse(read(name));

// SyncthingModel.js is written as a QML-importable script: bare function
// declarations, no exports. Load it into this scope so the functions are
// callable under node exactly as they are under Quickshell.
const source = fs.readFileSync(path.join(__dirname, "..", "SyncthingModel.js"), "utf8");
const load = new Function(
  source + "\nreturn { splitRecords, safeParse, isPlainObject, readApiKey, expandPath, parseHealth,"
    + " buildFolders, buildDevices, overallStatus, pendingCount, errorCount, formatBytes, formatAgo,"
    + " formatUptime, folderState, folderProgress, folderErrorText, elide, shortId, deviceStatusLabel,"
    + " identiconCells };"
);
const M = load();

let passed = 0;
let failed = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${name}\n         expected ${e}\n         actual   ${a}`);
  }
}

function section(title) {
  console.log(`\n${title}`);
}

// Synthetic device IDs. The fixtures were captured from a real Syncthing
// instance, and a real device ID is a secret-adjacent identifier: it names a
// specific machine and is what someone needs to accept that machine's request.
// These stand in for it, matching the real shape (8 dash-separated groups of 7)
// so nothing under test behaves differently.
const SELF_ID = "SELFDEV-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG";
const REMOTE_ID = "REMOTEV-HHHHHHH-IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN";

const config = json("config.json");
const status = json("status.json");
const connections = json("connections.json");
const pendingDevices = json("pending-devices.json");
const pendingFolders = json("pending-folders.json");
const dbPhotos = json("db-status-tst01-aaaaa.json");
const dbMusic = json("db-status-tst02-bbbbb.json");
const dbCode = json("db-status-tst03-ccccc.json");

const dbByFolder = {
  "tst01-aaaaa": dbPhotos,
  "tst02-bbbbb": dbMusic,
  "tst03-ccccc": dbCode
};

const stats = {
  [REMOTE_ID]: { lastSeen: "2026-09-25T19:16:38Z" }
};

// A fixed clock so the "last seen" formatting assertions do not drift as the
// fixtures age.
const NOW = Date.parse("2026-09-25T19:16:38Z");
const byId = (list, id) => list.find((entry) => entry.id === id || entry.deviceID === id);

const folders = M.buildFolders(config, dbByFolder, pendingFolders);
const devices = M.buildDevices(config, status, connections, pendingDevices, stats);

// ---------------------------------------------------------------- splitting

section("batched response splitting");

{
  // curl -w $'\x1e' appends the separator after every response, so a three-URL
  // batch ends with a trailing separator and one empty tail.
  const raw = `${JSON.stringify(dbPhotos)}\u001e${JSON.stringify(dbMusic)}\u001e${JSON.stringify(status)}\u001e`;
  const parts = M.splitRecords(raw);
  check("three records -> three objects", parts.length, 3);
  check("record 0 is the backup folder", parts[0].state, "idle");
  check("record 1 is the documents folder", parts[1].state, "idle");
  check("record 2 is the system status", typeof parts[2].myID, "string");
}

check("empty input -> no records", M.splitRecords("").length, 0);
check("separator only -> no records", M.splitRecords("\u001e\u001e").length, 0);
check("non-JSON body -> null, not a throw", M.splitRecords("Forbidden"), [null]);
check(
  "paused-folder completion body -> null",
  M.splitRecords(M.elide(read("completion-paused-folder.txt"), 40))[0],
  null
);
check("array body is not an object", M.safeParse("[1,2,3]"), null);

// -------------------------------------------------------------------- health

section("liveness probe (no API key needed)");

check("healthy", M.parseHealth(read("health.json")), { reachable: true, message: "OK" });
check("empty body", M.parseHealth(""), { reachable: false, message: "No response" });
check("container down", M.parseHealth(""), { reachable: false, message: "No response" });
check("not ready yet", M.parseHealth('{"status":"starting"}'), {
  reachable: false,
  message: "starting"
});
check("garbage", M.parseHealth("<html>502</html>"), { reachable: false, message: "No response" });

// ------------------------------------------------------------------ api key

section("api key discovery");

{
  const xml = `<?xml version="1.0"?>
<configuration version="37">
    <gui enabled="true" tls="false">
        <address>0.0.0.0:8384</address>
        <apikey>ABCDEFGH12345678IJKLMNOP90123456</apikey>
        <theme>default</theme>
    </gui>
    <folder id="tst01-aaaaa" paused="false">
        <paused>false</paused>
    </folder>
</configuration>`;
  check("reads the gui apikey", M.readApiKey(xml), "ABCDEFGH12345678IJKLMNOP90123456");
  check("first apikey wins", M.readApiKey(xml + "<apikey>SECOND</apikey>"), "ABCDEFGH12345678IJKLMNOP90123456");
}
check("self-closing empty apikey", M.readApiKey("<apikey></apikey>"), "");
check("no apikey element", M.readApiKey("<gui><address>x</address></gui>"), "");
check("missing file", M.readApiKey(""), "");

check("expands ~", M.expandPath("~/docker/syncthing/config.xml", "/home/testuser"),
  "/home/testuser/docker/syncthing/config.xml");
check("expands bare ~", M.expandPath("~", "/home/testuser"), "/home/testuser");
check("leaves absolute path alone", M.expandPath("/etc/syncthing/config.xml", "/home/testuser"),
  "/etc/syncthing/config.xml");
check("empty stays empty", M.expandPath("", "/home/testuser"), "");
check("trims whitespace", M.expandPath("  /a/b  ", "/home/testuser"), "/a/b");

// ------------------------------------------------------------------- folders

section("folder rows");

check("one row per configured folder", folders.length, 3);
check("row order follows config", folders.map((f) => f.label), ["Photos", "Music", "Code"]);
check("backup is idle", folders[0].state, "idle");
check("backup is up to date", folders[0].statusLabel, "Up to date");
check("backup fully synced", folders[0].progress, 1);
check("backup has nothing outstanding", folders[0].needBytes, 0);
check("paused folder reads paused from config", folders[2].state, "paused");
check("paused folder label", folders[2].statusLabel, "Paused");
check("paused folder has no progress bar", folders[2].progress, 0);
check("folder type preserved", folders[0].type, "sendreceive");
check("paused db payload really is empty-state", dbCode.state, "");

{
  // db/status reports state:"" for a paused folder; without the config flag a
  // paused folder would be indistinguishable from "unknown".
  const onlyDb = M.buildFolders({ folders: [{ id: "x", label: "X", paused: false }] }, { x: dbCode }, {});
  check("empty db state -> unknown, not idle", onlyDb[0].state, "unknown");
  check("unknown folder label", onlyDb[0].statusLabel, "Not connected");
}

{
  const syncing = Object.assign({}, dbMusic, {
    state: "syncing",
    needBytes: 52428800,
    needFiles: 12,
    globalBytes: 209715200
  });
  const rows = M.buildFolders({ folders: [{ id: "d", label: "Docs", paused: false }] }, { d: syncing }, {});
  check("syncing state", rows[0].state, "syncing");
  check("syncing label", rows[0].statusLabel, "Syncing · 50.0 MB left");
  check("progress is remaining work", rows[0].progress, 0.75);
}

{
  const scanning = Object.assign({}, dbPhotos, { state: "scanning" });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] }, { b: scanning }, {});
  check("scanning state", rows[0].state, "scanning");
  check("scanning label", rows[0].statusLabel, "Scanning…");
}

{
  // An idle folder can still owe work; that is not "Up to date".
  const pending = Object.assign({}, dbPhotos, { state: "idle", needBytes: 1073741824, needFiles: 3 });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] }, { b: pending }, {});
  check("idle-but-owing stays pending", rows[0].statusLabel, "Pending · 1.00 GB to sync");
  check("idle-but-owing has progress left", rows[0].progress, 0);
}

{
  const failed = Object.assign({}, dbPhotos, { state: "idle", error: "folder marker missing: foo" });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] }, { b: failed }, {});
  check("error wins over idle", rows[0].state, "error");
  check("error text surfaced", rows[0].statusLabel, "folder marker missing: foo");
}

{
  const pulls = Object.assign({}, dbPhotos, { state: "idle", pullErrors: 1 });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] }, { b: pulls }, {});
  check("pull error -> error state", rows[0].state, "error");
  check("single pull error is singular", rows[0].statusLabel, "1 pull error");
}

{
  const many = Object.assign({}, dbPhotos, { state: "idle", errors: 4 });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] }, { b: many }, {});
  check("error count is pluralised", rows[0].statusLabel, "4 errors");
}

{
  // A dead inotify watch takes the folder down even though the index is fine.
  const watch = Object.assign({}, dbPhotos, { state: "idle", watchError: "inotify limit reached" });
  check("watchError is an error", M.folderErrorText(watch), "inotify limit reached");
}

{
  const receiveOnly = Object.assign({}, dbPhotos, { receiveOnlyChangedBytes: 2097152 });
  const rows = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false, type: "receiveonly" }] },
    { b: receiveOnly }, {});
  check("receive-only changes need review", rows[0].statusLabel, "Review 2.00 MB of changes");
}

{
  // No bytes and no items is "done", not "0%".
  const empty = { state: "idle", globalBytes: 0, globalTotalItems: 0, needBytes: 0, needTotalItems: 0 };
  check("empty folder is complete", M.folderProgress(empty), 1);
  const counting = { globalBytes: 0, globalTotalItems: 100, needTotalItems: 25, needBytes: 0 };
  check("falls back to item counts", M.folderProgress(counting), 0.75);
  const nothingIndexed = { globalBytes: 0, globalTotalItems: 0, needBytes: 0, needTotalItems: 5 };
  check("items needed but nothing indexed", M.folderProgress(nothingIndexed), 0);
}

{
  const pendingRow = M.buildFolders(
    { folders: [{ id: "known", label: "Known", paused: false }] },
    { known: dbPhotos },
    { "new-one": { folderID: "new-one", label: "Shared drive" } }
  );
  check("pending folder gets a row", pendingRow.length, 2);
  check("pending folder is flagged", pendingRow[1].pending, true);
  check("pending folder state", pendingRow[1].state, "pending");
  check("pending folder label from payload", pendingRow[1].label, "Shared drive");
}

{
  // A folder that is both configured and pending must not appear twice.
  const deduped = M.buildFolders(
    { folders: [{ id: "both", label: "Both", paused: false }] },
    { both: dbPhotos },
    { both: { folderID: "both", label: "Both" } }
  );
  check("configured+pending is not duplicated", deduped.length, 1);
}

check("no config at all -> no rows", M.buildFolders(null, {}, {}).length, 0);
check("garbage db payload is tolerated",
  M.buildFolders({ folders: [{ id: "a", label: "A" }] }, { a: "not-an-object" }, {})[0].state, "unknown");

// ------------------------------------------------------------------- devices

section("device rows");

check("one row per configured device", devices.length, 2);
check("this device sorts first", devices[0].isSelf, true);
check("self is labelled", devices[0].statusLabel, "This device");
check("self carries the real name", devices[0].name, "alpha");
check("self id matches status.myID", devices[0].deviceID, status.myID);

check("peer is connected", devices[1].connected, true);
check("peer connection type is kept", devices[1].connectionType, "relay-client");
check("relay is called out in the label", devices[1].statusLabel, "Connected · relay-client");
  check("peer last seen is formatted", M.formatAgo(devices[1].lastSeen, NOW), "just now");
  check("last seen text is precomputed for the row", devices[1].lastSeenText.length > 0, true);
check("peer address kept", devices[1].address, "203.0.113.20:22067");

{
  const empty = M.buildDevices(
    { devices: [{ deviceID: "AAA", name: "Laptop", paused: false }] },
    { myID: "BBB" },
    { connections: {} },
    {},
    {}
  );
  check("absent from connections means offline", empty[0].connected, false);
  check("offline label without a last-seen", empty[0].statusLabel, "Offline");
  check("offline state", empty[0].state, "offline");
}

{
  const seen = M.buildDevices(
    { devices: [{ deviceID: "AAA", name: "Laptop", paused: false }] },
    { myID: "BBB" },
    { connections: {} },
    {},
    { AAA: { lastSeen: new Date(NOW - 3600000).toISOString().replace(/\.\d+Z$/, "Z") } },
    NOW
  );
  check("offline with a last-seen reads well", seen[0].statusLabel, "Offline · last seen 1 hour ago");
}

{
  const paused = M.buildDevices(
    { devices: [{ deviceID: "AAA", name: "Laptop", paused: true }] },
    { myID: "BBB" },
    { connections: { AAA: { connected: true, type: "tcp-client" } } },
    {},
    {}
  );
  check("paused beats connected", paused[0].state, "paused");
  check("paused label", paused[0].statusLabel, "Paused");
}

{
  const pending = M.buildDevices(
    { devices: [{ deviceID: "AAA", name: "Laptop", paused: false }] },
    { myID: "BBB" },
    { connections: { AAA: { connected: true, type: "tcp-client" } } },
    { "CCC": { deviceID: "CCC", name: "Phone" } },
    {}
  );
  check("pending device gets a row", pending.length, 2);
  // Rows are sorted (self, then pending, then the rest), so look the row up
  // rather than assuming where it lands.
  const phone = byId(pending, "CCC");
  check("pending device flagged", phone.pending, true);
  check("pending device state", phone.state, "pending");
  check("pending device label", phone.statusLabel, "Pending approval");
  check("pending device name from payload", phone.name, "Phone");
  check("pending sorts before the plain device", pending[0].deviceID, "CCC");
}

{
  const plainTcp = M.deviceStatusLabel({ state: "online", connectionType: "tcp-client" });
  check("a plain tcp connection is not spelled out", plainTcp, "Connected");
}

// ------------------------------------------------------------------ overall

section("overall status (drives the bar icon)");

check(
  "container stopped",
  M.overallStatus(folders, devices, false),
  { state: "stopped", text: "Stopped", pending: false, error: false, busy: false }
);
check("all synced", M.overallStatus(folders, devices, true),
  { state: "idle", text: "Up to date", pending: false, error: false, busy: false });

{
  const busy = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] },
    { b: Object.assign({}, dbPhotos, { state: "syncing" }) }, {});
  const o = M.overallStatus(busy, devices, true);
  check("syncing wins over idle", o.state, "syncing");
  check("syncing text", o.text, "Syncing");
  check("syncing flags busy", o.busy, true);
}

{
  const bad = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] },
    { b: Object.assign({}, dbPhotos, { state: "idle", error: "disk full" }) }, {});
  const o = M.overallStatus(bad, devices, true);
  check("error beats syncing", o.state, "error");
  check("error text", o.text, "Error");
  check("error flagged", o.error, true);
  check("error count", M.errorCount(bad), 1);
}

{
  // Approval outranks activity: an unseen share is the thing worth noticing.
  const busy = M.buildFolders({ folders: [{ id: "b", label: "B", paused: false }] },
    { b: Object.assign({}, dbPhotos, { state: "syncing" }) }, {});
  const pendingDevicesArg = M.buildDevices(config, status, connections, { "NEW": { name: "Phone" } }, stats);
  const o = M.overallStatus(busy, pendingDevicesArg, true);
  check("pending beats syncing", o.state, "pending");
  check("pending text", o.text, "Pending approval");
  check("pending count counts devices and folders", M.pendingCount(busy, pendingDevicesArg), 1);
}

{
  // Every folder paused but the container up is "paused", not "up to date".
  const allPaused = M.buildFolders(
    { folders: [
      { id: "a", label: "A", paused: true },
      { id: "b", label: "B", paused: true }
    ] },
    { a: dbPhotos, b: dbMusic },
    {}
  );
  const o = M.overallStatus(allPaused, devices, true);
  check("all folders paused", o.state, "paused");
  check("all folders paused text", o.text, "Paused");
}

{
  const partial = M.buildFolders(
    { folders: [
      { id: "a", label: "A", paused: true },
      { id: "b", label: "B", paused: false }
    ] },
    { a: dbPhotos, b: dbMusic },
    {}
  );
  check("some paused still counts as up to date", M.overallStatus(partial, devices, true).state, "idle");
}

// ---------------------------------------------------------------- formatting

section("formatting");

check("bytes: 0", M.formatBytes(0), "0 B");
check("bytes: bytes", M.formatBytes(512), "512 B");
check("bytes: KB", M.formatBytes(1536), "1.50 KB");
check("bytes: MB", M.formatBytes(52428800), "50.0 MB");
check("bytes: GB", M.formatBytes(1073741824), "1.00 GB");
check("bytes: 4.5 GB", M.formatBytes(4831838208), "4.50 GB");
check("bytes: no decimals when large", M.formatBytes(123456789), "118 MB");
check("bytes: junk in, 0 out", M.formatBytes("nope"), "0 B");

const now = Date.parse("2026-09-25T20:00:00Z");
check("ago: under a minute", M.formatAgo("2026-09-25T19:59:30Z", now), "just now");
check("ago: minutes", M.formatAgo("2026-09-25T19:45:00Z", now), "15 min ago");
check("ago: hours", M.formatAgo("2026-09-25T17:00:00Z", now), "3 hours ago");
check("ago: days", M.formatAgo("2026-09-23T20:00:00Z", now), "2 days ago");
check("ago: zero time is unknown", M.formatAgo("0001-01-01T00:00:00Z", now), "");
check("ago: empty is unknown", M.formatAgo("", now), "");
check("ago: junk is unknown", M.formatAgo("not a date", now), "");
check("ago: never goes negative", M.formatAgo("2026-09-25T20:30:00Z", now), "just now");

check("uptime: minutes", M.formatUptime(125), "2m");
check("uptime: hours", M.formatUptime(7380), "2h 3m");
check("uptime: days", M.formatUptime(176580), "2d 1h");
check("uptime: junk in, 0 out", M.formatUptime("nope"), "0m");

check("elide short text", M.elide("hello", 20), "hello");
check("elide long text", M.elide("x".repeat(100), 10).length, 10);
check("elide collapses whitespace", M.elide("a   b\n\tc", 20), "a b c");
check("short id", M.shortId(REMOTE_ID), "REMOTEV");
check("short id of short input", M.shortId("abc"), "abc");
// ------------------------------------------------------------- device identicon

// The web UI builds these in the browser (syncthing/core/identiconDirective.js)
// with no server-side endpoint, so the reference below is a verbatim port of
// that directive and stands in as the oracle. If Syncthing ever changes the
// algorithm, this is the place that should fail.
const webUiIdenticon = (value, size) => {
  const n = size || 5;
  const middleCol = Math.ceil(n / 2) - 1;
  const cells = [];
  const shouldFill = (row, col) => !(parseInt(value.charCodeAt(row + col * n), 10) % 2);
  const shouldMirror = (row, col) => !(n % 2 && col === middleCol);
  if (value) {
    // The directive reassigns `value` here, so the char codes read inside the
    // loop are from the stripped string, not the raw one.
    value = value.toString().replace(/[\W_]/g, "");
    for (let row = 0; row < n; ++row) {
      for (let col = middleCol; col > -1; --col) {
        if (shouldFill(row, col)) {
          cells.push([row, col]);
          if (shouldMirror(row, col)) cells.push([row, n - col - 1]);
        }
      }
    }
  }
  return cells.sort((a, b) => a[0] - b[0] || a[1] - b[1]).map(([r, c]) => r + "," + c).join("|");
};

const identiconText = (value, size) =>
  M.identiconCells(value, size).map((c) => c.row + "," + c.col).join("|");

const IDENTICON_IDS = [
  SELF_ID,
  REMOTE_ID,
  "SHORT", "a", "abcdefghijklmnop", "12345",
  "ZZZZZZZZZZZZZZZ", "0000000000000000", "x-y_z", "-----", "___",
  "", "\u03a9", "\u{1f642}",
];
for (const id of IDENTICON_IDS) {
  check(`identicon matches the web UI directive: ${JSON.stringify(id)}`,
    identiconText(id), webUiIdenticon(id));
}

check("identicon of an empty value is empty, not a solid grid", M.identiconCells(""), []);
check("identicon of a null value is empty", M.identiconCells(null), []);

const cells = M.identiconCells(SELF_ID);
check("identicon cells stay inside the 5x5 grid",
  cells.every((c) => c.row >= 0 && c.row < 5 && c.col >= 0 && c.col < 5), true);
check("identicon has no duplicate cells",
  new Set(cells.map((c) => c.row + "," + c.col)).size, cells.length);
check("identicon is left-right symmetric",
  cells.every((c) => cells.some((m) => m.row === c.row && m.col === 4 - c.col)), true);
check("identicon is deterministic",
  identiconText(REMOTE_ID),
  identiconText(REMOTE_ID));
check("identicon of a device id equals the id with dashes removed",
  identiconText("AB-CD-EF"), identiconText("ABCDEF"));

// Every device the panel renders needs a pattern to draw.
const devicesWithIcons = M.buildDevices(config, status, connections, pendingDevices, stats);
check("buildDevices gives every device an identicon",
  devicesWithIcons.every((d) => Array.isArray(d.identicon) && d.identicon.length > 0), true);
check("buildDevices draws this device's identicon from its own id",
  identiconText(status.myID), identiconText(devicesWithIcons.find((d) => d.isSelf).deviceID));

// ------------------------------------------------------------------- summary

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
