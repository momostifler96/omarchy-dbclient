import QtQuick
import qs.Commons
import qs.Ui

// Right-click menu for the schema tree. popup(items, x, y) with items
// [{ text, icon, danger, run: function() {} }] (null inserts a separator).
Item {
  id: menu

  property bool opened: false
  property var items: []
  property real menuX: 0
  property real menuY: 0

  function popup(list, x, y) {
    items = list
    menuX = x
    menuY = y
    opened = true
  }

  function close() { opened = false }

  visible: opened

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
            color: hover.containsMouse ? Util.alpha(entry.modelData && entry.modelData.danger ? Color.urgent : Color.foreground, 0.10) : "transparent"

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
              onClicked: {
                var run = entry.modelData.run
                menu.close()
                if (typeof run === "function") run()
              }
            }
          }
        }
      }
    }
  }
}
