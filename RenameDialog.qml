import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property string initialName: ""
  property var existingNames: []
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius
  property string errorMessage: ""

  signal canceled()
  signal confirmed(string newName)
  visible: opened

  Keys.priority: Keys.BeforeItem
  Keys.onReturnPressed: function(event) {
    event.accepted = true
    root.submit()
  }
  Keys.onEnterPressed: function(event) {
    event.accepted = true
    root.submit()
  }
  Keys.onEscapePressed: function(event) {
    event.accepted = true
    root.close()
    root.canceled()
  }

  function open(accountName, allNames) {
    initialName = accountName || ""
    existingNames = allNames || []
    errorMessage = ""
    inputField.text = initialName
    opened = true
    Qt.callLater(function() {
      inputField.forceActiveFocus()
      inputField.selectAll()
    })
  }

  function close() {
    opened = false
    errorMessage = ""
  }

  function validate(text) {
    var trimmed = text.trim()
    if (trimmed === "") {
      return "Node name cannot be empty"
    }
    if (trimmed.length > 128) {
      return "Name must be 128 characters or fewer"
    }
    if (!/^[A-Za-z0-9#][A-Za-z0-9._@()+,#%=-]*( [A-Za-z0-9._@()+,#%=-]+)*$/.test(trimmed)) {
      return "Name contains invalid characters"
    }
    for (var i = 0; i < existingNames.length; i++) {
      if (existingNames[i] === trimmed && trimmed !== initialName) {
        return "An account with this name already exists"
      }
    }
    return ""
  }

  function submit() {
    var trimmed = inputField.text.trim()
    if (trimmed === initialName) {
      close()
      return
    }
    var err = validate(trimmed)
    if (err !== "") {
      errorMessage = err
      return
    }
    var target = trimmed
    close()
    root.confirmed(target)
  }

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.close()
        root.canceled()
      }
    }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(390))
      implicitHeight: cardContent.implicitHeight + Style.space(36)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: root.cornerRadius

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Column {
        id: cardContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        spacing: Style.space(14)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Rename VPN Node"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        TextField {
          id: inputField
          width: parent.width
          placeholderText: "New node name"
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          foreground: root.foreground
          accent: root.accent
          selectByMouse: true
          hasCursor: true

          onTextChanged: {
            if (root.errorMessage !== "") root.errorMessage = ""
          }

          Keys.onReturnPressed: function(event) {
            event.accepted = true
            root.submit()
          }
          Keys.onEnterPressed: function(event) {
            event.accepted = true
            root.submit()
          }
          Keys.onEscapePressed: function(event) {
            event.accepted = true
            root.close()
            root.canceled()
          }
        }

        Text {
          id: errorText
          visible: root.errorMessage !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorMessage
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          anchors.right: parent.right
          spacing: Style.space(10)

          BorderSurface {
            width: Style.space(88)
            height: Style.space(34)
            color: "transparent"
            borderSpec: Border.flat(Util.alpha(root.foreground, 0.38), Style.normalBorderWidth)
            radius: Style.cornerRadius

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "Cancel"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.close()
                root.canceled()
              }
            }
          }

          BorderSurface {
            width: Style.space(88)
            height: Style.space(34)
            color: Util.alpha(root.accent, 0.15)
            borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
            radius: Style.cornerRadius

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "Save"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.submit()
            }
          }
        }
      }
    }
  }
}
