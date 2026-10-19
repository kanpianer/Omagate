import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  signal toggled()
  signal hovered(bool isHovered)

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool hot: hasCursor || mouse.containsMouse

  // Dimensions matching the sharp rectangular toggle in screenshot
  property int trackWidth: Style.space(42)
  property int trackHeight: Style.space(22)
  property int knobSize: Style.space(16)
  property int knobInset: Style.space(3)

  property int pad: Style.space(2)

  implicitWidth: trackWidth + pad * 2
  implicitHeight: trackHeight + pad * 2

  Rectangle {
    id: track
    width: root.trackWidth
    height: root.trackHeight
    anchors.centerIn: parent
    radius: 0
    color: "#232326"
    border.width: 1
    border.color: root.hot ? root.accent : "#52525b"

    Behavior on border.color { ColorAnimation { duration: 120 } }

    Rectangle {
      id: knob
      width: root.knobSize
      height: root.knobSize
      radius: 0
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? track.width - width - root.knobInset : root.knobInset
      color: root.checked ? "#ffffff" : "#71717a"

      Behavior on x {
        NumberAnimation {
          duration: 140
          easing.type: Easing.OutCubic
        }
      }
      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.interactive && !root.busy
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: root.hovered(containsMouse)
    onClicked: root.toggled()
  }
}
