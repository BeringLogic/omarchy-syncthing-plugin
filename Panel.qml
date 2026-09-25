import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SyncthingModel.js" as Model

// Bar icon plus popup, in one entry point, as a bar-widget.
//
// The root extends qs.Ui Panel rather than BarWidget because Panel declares the
// three properties the host injects (bar, moduleName, settings) and provides
// open()/close()/opened, which is how the bar finds this widget for
// `omarchy-shell shell toggle` and how the popup is dismissed.
Panel {
  id: root
  moduleName: "syncthing.bar"
  ipcTarget: "syncthing.bar"
  manageIpc: false

  // The poller is a plain child of the panel rather than a `service` manifest
  // entry point. The bar instantiates one widget per plugin, so this is
  // guaranteed to be the only poller -- and it stops when the widget is removed
  // from the bar. Settings come straight from the bar's inline entry.
  Service {
    id: st
    settings: root.settings
  }

  // ---- theme ----
  //
  // Style.font.family unconditionally: it resolves through `fc-match monospace`
  // to the Nerd Font. bar.fontFamily is an empty string for a third-party
  // widget's facade, which would fall back to a proportional face and render
  // every icon glyph as tofu.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color trackColor: Style.selectedFillFor(foreground, Color.accent)
  readonly property color warningColor: "#d99a3c"
  readonly property string fontFamily: Style.font.family
  readonly property bool barIconActive: st.reachable && st.folderErrorCount === 0 && st.pendingCount === 0

  // Folder icons take the colour of the folder's state, so the section reads
  // at a glance without every row needing a status pill.
  function folderColor(folder) {
    if (folder.state === "error") return root.urgent
    if (folder.state === "pending") return root.warningColor
    if (folder.state === "paused") return root.dim
    if (folder.state === "syncing" || folder.state === "scanning") return Color.accent
    return root.foreground
  }

  function deviceColor(device) {
    if (device.state === "pending") return root.warningColor
    if (device.state === "paused" || device.state === "offline") return root.dim
    return root.foreground
  }

  function heroDetail() {
    if (!st.reachable) return "STOPPED"
    if (st.folderErrorCount > 0) return st.folderErrorCount + (st.folderErrorCount === 1 ? " ERROR" : " ERRORS")
    if (st.pendingCount > 0) return st.pendingCount + " PENDING"
    if (st.busy) return "SYNCING"
    return ""
  }

  // ---- keyboard cursor ----
  property bool cursorActive: false
  property string focusSection: "header"
  property int folderIndex: 0
  property int deviceIndex: 0

  readonly property bool showFolders: st.folders.length > 0
  readonly property bool showDevices: st.devices.length > 1
  readonly property bool showFooter: st.webUrl !== ""

  function hasSection(name) {
    if (name === "folders") return showFolders
    if (name === "devices") return showDevices
    if (name === "footer") return showFooter
    return true
  }

  function nextSection(name) {
    var order = ["header", "folders", "devices", "footer"]
    var start = order.indexOf(name)
    for (var i = start + 1; i < order.length; i++) {
      if (hasSection(order[i])) return order[i]
    }
    return ""
  }

  function previousSection(name) {
    var order = ["header", "folders", "devices", "footer"]
    var start = order.indexOf(name)
    for (var i = start - 1; i >= 0; i--) {
      if (hasSection(order[i])) return order[i]
    }
    return ""
  }

  function ensureCursor() {
    if (folderIndex >= st.folders.length) folderIndex = Math.max(0, st.folders.length - 1)
    if (deviceIndex >= st.devices.length) deviceIndex = Math.max(0, st.devices.length - 1)
    if (!hasSection(focusSection)) focusSection = nextSection("") || "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy > 0) {
      if (focusSection === "header") {
        var fromHeader = nextSection("header")
        if (fromHeader !== "") { focusSection = fromHeader; folderIndex = 0; deviceIndex = 0 }
      } else if (focusSection === "folders") {
        if (folderIndex < st.folders.length - 1) folderIndex += 1
        else {
          var afterFolders = nextSection("folders")
          if (afterFolders !== "") { focusSection = afterFolders; deviceIndex = 0 }
        }
      } else if (focusSection === "devices") {
        if (deviceIndex < st.devices.length - 1) deviceIndex += 1
        else {
          var afterDevices = nextSection("devices")
          if (afterDevices !== "") focusSection = afterDevices
        }
      }
    } else if (dy < 0) {
      if (focusSection === "footer") {
        var beforeFooter = previousSection("footer")
        if (beforeFooter !== "") focusSection = beforeFooter
      } else if (focusSection === "devices") {
        if (deviceIndex > 0) deviceIndex -= 1
        else {
          var beforeDevices = previousSection("devices")
          if (beforeDevices !== "") { focusSection = beforeDevices; folderIndex = Math.max(0, st.folders.length - 1) }
        }
      } else if (focusSection === "folders") {
        if (folderIndex > 0) folderIndex -= 1
        else focusSection = "header"
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") {
      st.toggleRunning()
    } else if (focusSection === "folders") {
      var folder = st.folders[folderIndex]
      if (folder) st.toggleFolderPause(folder)
    } else if (focusSection === "devices") {
      var device = st.devices[deviceIndex]
      // "This device" is not something you can pause.
      if (device && !device.isSelf && !device.pending) st.toggleDevicePause(device)
    } else if (focusSection === "footer") {
      st.openWebUi()
    }
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      if (point.y < viewTop + margin) {
        panelFlick.contentY = Math.max(0, point.y - margin)
      } else if (point.y + item.height > viewBottom - margin) {
        panelFlick.contentY = Math.min(
          Math.max(0, panelFlick.contentHeight - panelFlick.height),
          point.y + item.height + margin - panelFlick.height)
      }
    })
  }

  // Repeater.itemAt, not children[index]: a Repeater's instances are appended
  // to its parent's children alongside the Repeater object itself, so children
  // is offset by one and would highlight and scroll the wrong row.
  function scrollCursorIntoView() {
    if (focusSection === "folders") {
      scrollItemIntoView(folderRepeater.itemAt(folderIndex))
    } else if (focusSection === "devices") {
      scrollItemIntoView(deviceRepeater.itemAt(deviceIndex))
    }
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "header"
      folderIndex = 0
      deviceIndex = 0
      if (panelFlick) panelFlick.contentY = 0
      st.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  onShowFoldersChanged: ensureCursor()
  onShowDevicesChanged: ensureCursor()

  // Folder and device lists live on the service, not on this root, so their
  // change signals have to be observed here rather than as root handlers.
  Connections {
    target: st
    function onFoldersChanged() { root.ensureCursor(); root.scrollCursorIntoView() }
    function onDevicesChanged() { root.ensureCursor(); root.scrollCursorIntoView() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { st.refresh(); return "ok" }
    function status(): string { return st.overallText }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: st.reachable ? st.overallText : "Syncthing is stopped"

    iconComponent: Component {
      Item {
        SyncthingIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconActive ? root.barForeground : Qt.darker(root.barForeground, 1.4)
          badgeColor: root.urgent
          warningColor: root.warningColor
          spinning: st.busy && st.reachable
          error: st.folderErrorCount > 0
          pending: st.pendingCount > 0
          stopped: !st.reachable
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) st.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t || "").toLowerCase()
        if (key === "r") st.refresh()
        else if (key === "t") st.toggleRunning()
        else if (key === "o") st.openWebUi()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- hero ----
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "header"
            }

            PanelHero {
              id: hero
              width: parent.width
              title: "Syncthing"
              detail: root.heroDetail()
              meta: st.reachable
                ? st.overallText + " · up " + Model.formatUptime(st.uptimeSec)
                : "Container is not running"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: st.reachable ? 1.0 : 0.5

              iconComponent: Component {
                SyncthingIcon {
                  iconSize: Style.font.display
                  color: st.reachable ? root.foreground : root.dim
                  badgeColor: root.urgent
                  warningColor: root.warningColor
                  spinning: st.busy && st.reachable
                  error: st.folderErrorCount > 0
                  pending: st.pendingCount > 0
                  stopped: !st.reachable
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: st.running
                  busy: st.actionStatus !== "" || st.refreshing
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: st.toggleRunning()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: st.running ? "Stop " + st.containerName : "Start " + st.containerName
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // ---- transient action / error line ----
          Text {
            visible: st.actionStatus !== "" || st.lastError !== ""
            width: parent.width
            text: st.actionStatus !== "" ? st.actionStatus : st.lastError
            color: st.lastError !== "" && st.actionStatus === ""
              ? root.urgent
              : (st.starting ? root.warningColor : root.dim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- unreachable, or no API key ----
          CursorSurface {
            visible: !st.reachable
            width: parent.width
            implicitHeight: message.implicitHeight + Style.spacing.rowPaddingX * 2
            foreground: root.foreground

            Text {
              id: message
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: st.containerName + " is not answering on " + st.apiBase
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          // ---- folders ----
          PanelSeparator {
            visible: root.showFolders
            foreground: root.foreground
          }

          Column {
            visible: root.showFolders
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FOLDERS"
              width: parent.width
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: folderColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: folderRepeater
                model: st.folders
                FolderRow {
                  required property var modelData
                  required property int index
                  width: folderColumn.width
                  folder: modelData
                  rowIndex: index
                }
              }
            }
          }

          // ---- devices ----
          PanelSeparator {
            visible: root.showDevices
            foreground: root.foreground
          }

          Column {
            visible: root.showDevices
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DEVICES"
              width: parent.width
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: deviceColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: deviceRepeater
                model: st.devices
                DeviceRow {
                  required property var modelData
                  required property int index
                  width: deviceColumn.width
                  device: modelData
                  rowIndex: index
                }
              }
            }
          }

          // ---- footer link ----
          PanelSeparator {
            visible: root.showFooter
            foreground: root.foreground
          }

          CursorSurface {
            id: footerRow
            visible: root.showFooter
            width: parent.width
            implicitHeight: footerInner.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "footer"
            foreground: root.foreground

            function focusFooter() {
              root.cursorActive = true
              root.focusSection = "footer"
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: footerRow.focusFooter()
              onClicked: st.openWebUi()
            }

            RowLayout {
              id: footerInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: "󰖀"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                Layout.alignment: Qt.AlignVCenter
              }

              Text {
                Layout.fillWidth: true
                text: st.webUrl
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              Text {
                text: "Open web UI"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }
        }
      }
    }
  }

  // ---------- folder row ----------
  component FolderRow: CursorSurface {
    id: folderRow

    property var folder: null
    property int rowIndex: 0
    readonly property bool working: folder.state === "syncing" || folder.state === "scanning"
    readonly property string rescanTip: folder.pending
      ? "Pending folders are not configured here yet"
      : "Rescan " + folder.label

    hasCursor: root.cursorActive && root.focusSection === "folders" && root.folderIndex === rowIndex
    foreground: root.foreground
    implicitHeight: layout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: {
        if (containsMouse) {
          root.cursorActive = true
          root.focusSection = "folders"
          root.folderIndex = folderRow.rowIndex
        }
      }
    }

    RowLayout {
      id: layout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        text: "󰉋"
        color: root.folderColor(folderRow.folder)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          Layout.fillWidth: true
          text: folderRow.folder.label
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: folderRow.folder.state === "error"
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: folderRow.folder.statusLabel
          textFormat: Text.PlainText
          color: folderRow.folder.state === "error" ? root.urgent
            : (folderRow.folder.pending ? root.warningColor : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // Progress bar. There is no ProgressBar in qs.Ui, so this is the
        // track-and-fill idiom the power panel uses.
        Item {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(1)
          implicitHeight: Style.space(4)
          visible: folderRow.folder.state !== "paused" && folderRow.folder.state !== "pending"
            && folderRow.folder.globalBytes > 0

          Rectangle {
            id: progressTrack
            anchors.fill: parent
            radius: height / 2
            color: root.trackColor
          }

          Rectangle {
            anchors.left: progressTrack.left
            anchors.verticalCenter: progressTrack.verticalCenter
            height: progressTrack.height
            radius: progressTrack.radius
            color: root.folderColor(folderRow.folder)
            width: Math.max(progressTrack.height,
              progressTrack.width * Math.max(0, Math.min(1, folderRow.folder.progress)))

            Behavior on width {
              NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
            }
            Behavior on color {
              ColorAnimation { duration: 220 }
            }

            // Pulse while work is in flight: the shell's idiom for "busy".
            SequentialAnimation on opacity {
              running: folderRow.working
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }
      }

      PanelActionButton {
        id: rescanButton
        visible: !folderRow.folder.pending
        iconText: "󰑚"
        tooltipText: folderRow.rescanTip
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: st.rescanFolder(folderRow.folder)
      }

      PanelActionButton {
        visible: !folderRow.folder.pending
        iconText: folderRow.folder.paused ? "󰐊" : "󰏤"
        tooltipText: folderRow.folder.paused
          ? "Resume " + folderRow.folder.label
          : "Pause " + folderRow.folder.label
        foreground: root.foreground
        hoverColor: folderRow.folder.paused ? root.foreground : root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: st.toggleFolderPause(folderRow.folder)
      }
    }
  }

  // ---------- device row ----------
  component DeviceRow: CursorSurface {
    id: deviceRow

    property var device: null
    property int rowIndex: 0
    // This device and anything not yet approved have nothing to pause.
    readonly property bool pausable: !device.isSelf && !device.pending
    readonly property bool working: device.connected && !device.paused && !device.isSelf

    hasCursor: root.cursorActive && root.focusSection === "devices" && root.deviceIndex === rowIndex
    foreground: root.foreground
    implicitHeight: layout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: {
        if (containsMouse) {
          root.cursorActive = true
          root.focusSection = "devices"
          root.deviceIndex = deviceRow.rowIndex
        }
      }
    }

    RowLayout {
      id: layout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        text: deviceRow.device.isSelf ? "󰖜" : "󰘢"
        color: root.deviceColor(deviceRow.device)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: deviceRow.device.name
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: deviceRow.device.isSelf
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: deviceRow.device.statusLabel
          textFormat: Text.PlainText
          color: deviceRow.device.pending ? root.warningColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: deviceRow.pausable
        iconText: deviceRow.device.paused ? "󰐊" : "󰏤"
        tooltipText: deviceRow.device.paused
          ? "Resume " + deviceRow.device.name
          : "Pause " + deviceRow.device.name
        foreground: root.foreground
        hoverColor: deviceRow.device.paused ? root.foreground : root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: st.toggleDevicePause(deviceRow.device)
      }
    }
  }
}
