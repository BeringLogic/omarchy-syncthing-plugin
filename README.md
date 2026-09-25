# Omarchy Syncthing Plugin

An [Omarchy](https://omarchy.org) bar widget for Syncthing running in a Docker
container. The other Syncthing bar widgets assume a systemd unit on the host;
this one treats the container as the thing that is up or down.

## Features

- A Syncthing mark in the bar that **spins while syncing**, carries a red `!`
  badge on folder errors, an amber triangle when devices or folders are pending
  approval, and a slash through it when the container is not answering.
- Clicking the bar icon opens a panel with:
  - the Syncthing mark, the overall status, and how long the daemon has been up;
  - a power toggle that starts and stops the container;
  - every shared folder, with a status-coloured icon, its name and status, a
    progress bar while work is in flight, a rescan button, and a pause/resume
    button;
  - every device, with its icon, name, status, and a pause/resume button;
  - a footer link that opens the Syncthing web UI in the default browser.

The panel is fully keyboard navigable: `↑`/`↓` (or `j`/`k`) move a cursor,
`Enter`/`Space` activate, `Esc` closes, `Tab` moves to the next bar panel, and
`t`, `r`, `o` toggle the container, refresh, and open the web UI.

## Requirements

- Omarchy 4.0.0.alpha or newer (QML/Quickshell plugins).
- A Syncthing instance reachable over its REST API. The default settings expect
  it on `http://127.0.0.1:8384`.
- `curl` on `PATH`.
- `pkexec` (from `polkit`), unless you set `usePolkit: false` and run the shell
  as a user that can talk to the Docker socket.

The plugin never stops the container with a bare `docker` call unless you ask
for it, because that is the one action that needs root.

## Install

```bash
omarchy plugin add https://github.com/you/omarchy-syncthing-plugin.git --enable
```

`--enable` also asks which bar section to place the widget in; pass `right` to
skip the prompt:

```bash
omarchy plugin enable syncthing.bar right
```

To uninstall:

```bash
omarchy plugin remove syncthing.bar --yes
```

## Configuration

Settings live in your bar entry, so you can set them with
`omarchy bar set` or by editing `~/.config/omarchy/shell.json` directly. Every
key has a working default except the API key, which is read from disk (below).

| Key | Default | Meaning |
| --- | --- | --- |
| `apiBase` | `http://127.0.0.1:8384` | Syncthing GUI address. |
| `apiKeyPath` | `~/docker/syncthing/var_syncthing/config/config.xml` | File to read the `<apikey>` element from. |
| `containerName` | `syncthing` | Container the power toggle stops and starts. |
| `usePolkit` | `true` | Run `docker` through `pkexec`. |
| `refreshIntervalSec` | `15` | Poll interval while idle. |
| `busyIntervalSec` | `3` | Poll interval while syncing or scanning. |
| `webUrl` | `http://localhost:8384/` | Target of the footer link. |

For example:

```bash
omarchy bar set syncthing.bar apiKeyPath ~/docker/syncthing/var_syncthing/config/config.xml
omarchy bar set syncthing.bar refreshIntervalSec 30
```

Settings are per-bar-entry, so the same widget can be added to more than one bar
section with different values.

### The API key

There is no API key setting on purpose, so the plugin never asks you to paste a
secret into a config file. Every refresh re-reads the `<apikey>` element from
`apiKeyPath`, which keeps it in step with Syncthing's own key rotation. The file
is only ever read by the shell process; the key is not written anywhere.

Point `apiKeyPath` at the `config.xml` of the Syncthing instance you are
monitoring. If the path changes, the plugin drops the cached key and re-reads it.

## How it works

`Panel.qml` is the only manifest entry point. It owns the bar button, the popup,
and the keyboard state machine, and it instantiates `Service.qml` as a plain
child. There is deliberately no `service` kind: the shell builds one bar widget
per plugin, so keeping the poller inside the panel guarantees exactly one poller
and means it stops when you drop the widget from the bar.

Polling is timer-driven, not event-driven. Syncthing's `/rest/events` endpoint
streams nothing useful to a client that only wants a status summary, so
`Service.qml` instead does two batched `curl` rounds per tick:

1. `/rest/config`, `/rest/system/status`, `/rest/system/connections`, the two
   `/rest/cluster/pending/*` endpoints, and `/rest/stats/device`;
2. one `/rest/db/status` per folder, issued only after round one so a folder
   added from another device shows up without a restart.

Each round is a single `curl` process using `--write-out` with an ASCII record
separator, so six requests cost one subprocess. Liveness comes from
`/rest/noauth/health`, which needs no credentials, so the bar can say "stopped"
without holding a key or touching the Docker socket.

`SyncthingModel.js` holds all the parsing and derivation and is pure, so it is
covered by a Node test suite that runs against captured API responses.

## Status precedence

The bar shows one state, chosen in this order:

1. container not answering → stopped (slashed mark)
2. any folder in error → error (`!` badge)
3. devices or folders awaiting approval → pending (amber triangle)
4. any folder syncing or scanning → syncing (spinning mark)
5. every folder paused → all paused
6. otherwise → up to date

Per folder, the order is paused → error → syncing/scanning → idle, and progress
is `1 - needBytes/globalBytes` with a fallback to item counts when byte counts
are zero.

## Actions

- **Start/stop** runs `pkexec docker start|stop <containerName>`. The switch
  moves immediately and only settles once `/rest/noauth/health` agrees, so a
  dismissed polkit prompt is visibly a failure rather than a silent no-op.
- **Pause/resume** flips one flag and writes the folder or device back with
  `PUT /rest/config/folders/{id}` (or `/devices/{id}`). A full
  `/rest/config` round trip is never used, because Syncthing redacts
  `gui.apiKey` on read and posting the config back would blank the key and lock
  you out of your own GUI. The sub-resource is written instead, which leaves
  `gui` untouched.
- **Rescan** is `POST /rest/db/scan?folder={id}`.

Mutations are serialised through a single action process, so a second click
while a rescan is in flight is dropped instead of racing it. Every poll has a
watchdog, so a `curl` that never exits cannot silently freeze the panel.

## Development

Run the test suite:

```bash
node test/run.js
```

Lint the QML (the shell's `qs.*` imports will not resolve outside the shell, so
expect import warnings and ignore them):

```bash
qmllint Panel.qml Service.qml SyncthingIcon.qml
```

To test against a running shell without publishing, symlink the checkout into
your plugin directory and rescan:

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/syncthing.bar
omarchy shell shell rescanPlugins
```

If edits do not appear, restart the shell; Quickshell keeps the compiled
component for a given URL, so in-place edits are not always picked up by a
plugin rescan alone.

## License

MIT
