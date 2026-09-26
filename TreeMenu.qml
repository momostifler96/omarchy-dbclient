import QtQuick
import qs.Commons
import qs.Ui

// Right-click menu for the schema tree. popup(items, x, y) with items
// [{ text, icon, danger, run: function() {} }] (null inserts a separator).
// Keyboard: Up/Down, Home/End, Enter/Space, Escape.
Item {
  id: menu

  property bool opened: false
  property var items: []
  property real menuX: 0
  property real menuY: 0

  property int current: -1          // keyboard-highlighted entry
  property Item returnFocus: null   // gets the focus back on close

  function popup(list, x, y, keyboard) {
    items = list
    menuX = x
    menuY = y
    current = keyboard ? step(-1, 1) : -1
    opened = true
    forceActiveFocus()
  }

  function close() {
    if (!opened) return
    opened = false
    if (returnFocus) returnFocus.forceActiveFocus()
  }

  function step(from, dir) {
    for (var i = from + dir; i >= 0 && i < items.length; i += dir)
      if (items[i]) return i
    return from
  }

  function trigger(i) {
    var entry = items[i]
    if (!entry) return
    close()
    if (typeof entry.run === "function") entry.run()
  }

  visible: opened

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Down) current = step(current, 1)
    else if (event.key === Qt.Key_Up) current = step(current < 0 ? items.length : current, -1)
    else if (event.key === Qt.Key_Home) current = step(-1, 1)
    else if (event.key === Qt.Key_End) current = step(items.length, -1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) trigger(current)
    else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left) close()
    event.accepted = true
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: menu.close()
  }

  BorderSurface {
    id: card
    x: Math.max(4, Math.min(menu.menuX, menu.width - width - 4))
    y: Math.max(4, Math.min(menu.menuY, menu.height - height - 4))
    width: 260
    height: column.implicitHeight + 8
    color: Color.popups.background
    borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    MouseArea { anchors.fill: parent }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 4

      Repeater {
        model: menu.items

        delegate: Item {
          id: entry
          required property var modelData
          required property int index
          width: column.width
          height: modelData ? 28 : 9

          Rectangle {
            visible: !entry.modelData
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: Util.alpha(Color.foreground, 0.12)
          }

          Rectangle {
            visible: !!entry.modelData
            anchors.fill: parent
            radius: Style.cornerRadius
            color: hover.containsMouse || menu.current === entry.index ? Util.alpha(entry.modelData && entry.modelData.danger ? Color.urgent : Color.foreground, 0.10) : "transparent"

            Text {
              id: icon
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              width: 18
              text: entry.modelData && entry.modelData.icon ? entry.modelData.icon : ""
              color: entry.modelData && entry.modelData.danger ? Color.urgent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.left: icon.right
              anchors.leftMargin: 8
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: entry.modelData ? entry.modelData.text : ""
              color: entry.modelData && entry.modelData.danger ? Color.urgent : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              onEntered: menu.current = entry.index
              onClicked: menu.trigger(entry.index)
            }
          }
        }
      }
    }
  }
}
