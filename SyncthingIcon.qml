import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// The Syncthing mark: three arcs of a broken ring, 100 degrees each with 20
// degree gaps, 120 degrees apart. Drawn rather than loaded from SVG because the
// bar's optical canvas is only ~16px, where a filled path holds up better than
// Qt's SVG renderer.
//
// State is layered on top the way the tailscale icon layers its badge, so the
// bar slot carries the same signal set at a glance: it spins while busy, gets
// a "!" badge on errors, an orange triangle on pending approvals, and a slash
// when the container is down.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  // The theme palette has no warm "needs attention" token -- Color.urgent is
  // the only semantic colour and it is red. Pending approval is a softer
  // problem, so it gets its own fixed amber.
  property color warningColor: "#d99a3c"
  property bool spinning: false
  property bool error: false
  property bool pending: false
  property bool stopped: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1.4, iconSize * 0.115)
  readonly property real ringRadius: (iconSize - stroke) / 2

  // The arcs are the part that spins; badges and the slash stay put so they
  // never read as part of a rotating graphic.
  Item {
    id: rotor
    anchors.fill: parent
    opacity: root.stopped ? 0.45 : 1.0

    transform: Rotation {
      id: spinAngle
      origin.x: rotor.width / 2
      origin.y: rotor.height / 2
      angle: 0

      NumberAnimation on angle {
        running: root.spinning
        from: 0
        to: 360
        duration: 1400
        loops: Animation.Infinite
      }
    }

    Shape {
      id: ring
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: root.color
        strokeWidth: root.stroke
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2; centerY: ring.height / 2
          radiusX: root.ringRadius; radiusY: root.ringRadius
          startAngle: -50; sweepAngle: 100
        }
      }

      ShapePath {
        strokeColor: root.color
        strokeWidth: root.stroke
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2; centerY: ring.height / 2
          radiusX: root.ringRadius; radiusY: root.ringRadius
          startAngle: 70; sweepAngle: 100
        }
      }

      ShapePath {
        strokeColor: root.color
        strokeWidth: root.stroke
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2; centerY: ring.height / 2
          radiusX: root.ringRadius; radiusY: root.ringRadius
          startAngle: 190; sweepAngle: 100
        }
      }
    }
  }

  // A rotation animation left mid-flight would strand the mark at a random
  // angle, so snap it back to upright the moment the spin stops.
  onSpinningChanged: if (!spinning) spinAngle.angle = 0

  // Container down: a slash across the mark.
  Rectangle {
    visible: root.stopped
    anchors.centerIn: parent
    width: parent.width * 1.05
    height: Math.max(1.5, parent.height * 0.13)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  // Pending approvals. Drawn as a filled triangle so it still reads as a
  // distinct shape when the whole icon is 16px.
  Shape {
    id: pendingMark
    visible: root.pending && !root.error
    width: Math.max(6, root.iconSize * 0.46)
    height: width * 0.92
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.warningColor
      strokeColor: "transparent"
      startX: 0
      startY: 0
      // Qualified: an unqualified `width` inside a ShapePath resolves to the
      // component root, not to this Shape.
      PathLine { x: pendingMark.width; y: pendingMark.height }
      PathLine { x: 0; y: pendingMark.height }
    }

    BorderSurface {
      anchors.fill: parent
      color: "transparent"
      borderSpec: Border.flat(Color.popups.background, 1)
      radius: 2
    }
  }

  // Errors outrank pending: a "!" badge, mirroring the tailscale icon.
  BorderSurface {
    id: errorBadge
    visible: root.error
    width: Math.max(7, parent.width * 0.44)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.78)
      font.bold: true
    }
  }
}
