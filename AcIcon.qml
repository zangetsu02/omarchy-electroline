import QtQuick
import qs.Commons

// A wall split unit seen head on. Filled means at least one is running, the
// outline means they are all idle: the same at-a-glance rule the other bar
// widgets use.
Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground
  property bool filled: false
  property bool crossed: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real unitWidth: iconSize
  readonly property real unitHeight: Math.round(iconSize * 0.42)
  readonly property real stroke: Math.max(1, Math.round(iconSize * 0.1))

  Rectangle {
    id: body
    width: root.unitWidth
    height: root.unitHeight
    radius: Math.max(2, Math.round(root.iconSize * 0.14))
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round(root.iconSize * 0.12)
    color: root.filled ? root.color : "transparent"
    border.color: root.color
    border.width: root.filled ? 0 : root.stroke
  }

  // The louver, drawn in the background colour when the body is filled so it
  // stays visible either way.
  Rectangle {
    width: Math.round(body.width * 0.68)
    height: Math.max(1, Math.round(root.stroke * 0.8))
    radius: height / 2
    anchors.horizontalCenter: body.horizontalCenter
    y: body.y + Math.round(body.height * 0.62)
    color: root.filled ? Color.background : root.color
  }

  // Two puffs of air below, so the glyph is not just a rounded rectangle.
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    y: body.y + body.height + Math.round(root.iconSize * 0.16)
    spacing: Math.max(2, Math.round(root.iconSize * 0.16))

    Repeater {
      model: 2
      Rectangle {
        width: Math.round(root.iconSize * 0.26)
        height: Math.max(1, Math.round(root.stroke * 0.8))
        radius: height / 2
        color: root.color
        opacity: root.filled ? 1.0 : 0.65
      }
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.24
    height: Math.max(2, parent.height * 0.13)
    radius: height / 2
    color: root.color
    rotation: -45
  }
}
