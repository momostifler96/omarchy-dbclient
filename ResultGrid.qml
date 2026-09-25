import QtQuick
import QtQuick.Controls
import qs.Commons

// Spreadsheet-style view of one result set. A vertical ListView recycles row
// delegates; the header follows its horizontal scroll. Column widths are
// estimated from the data and can be dragged on the header edges.
Item {
  id: grid

  property var columns: []
  property var rows: []
  property var widths: []
  property int selRow: -1
  property int selCol: -1

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body

  readonly property int rowHeight: Math.round(fontSize * 2)
  readonly property int gutter: Math.max(40, String(rows.length).length * fontSize * 0.7 + 16)
  readonly property int totalWidth: {
    var w = gutter
    for (var i = 0; i < widths.length; i++) w += widths[i]
    return w
  }

  signal cellActivated(int row, int col)

  function setResult(res) {
    selRow = -1
    selCol = -1
    columns = res ? res.columns : []
    rows = res ? res.rows : []
    var charW = fontSize * 0.62
    var w = []
    for (var c = 0; c < columns.length; c++) {
      var n = String(columns[c]).length
      var limit = Math.min(rows.length, 60)
      for (var r = 0; r < limit; r++) n = Math.max(n, Math.min(48, cellText(rows[r][c]).length))
      w.push(Math.round(Math.max(56, n * charW + 22)))
    }
    widths = w
    list.contentX = 0
    list.contentY = 0
  }

  function cellText(v) {
    if (v === null || v === undefined) return "NULL"
    if (typeof v === "object") return JSON.stringify(v)
    var s = String(v)
    if (s.length > 400) s = s.slice(0, 400) + "…"
    return s.replace(/\r?\n/g, " ↵ ")
  }

  function setWidth(i, value) {
    var w = widths.slice()
    w[i] = Math.max(36, Math.round(value))
    widths = w
  }

  function selectedValue() {
    if (selRow < 0 || selCol < 0 || selRow >= rows.length) return undefined
    return rows[selRow][selCol]
  }

  Rectangle {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: grid.rowHeight + 2
    color: Util.alpha(grid.foreground, 0.06)
    clip: true

    Row {
      x: -list.contentX
      height: parent.height

      Item { width: grid.gutter; height: parent.height }

      Repeater {
        model: grid.columns.length

        delegate: Item {
          required property int index
          width: grid.widths[index] || 80
          height: header.height

          Text {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            verticalAlignment: Text.AlignVCenter
            text: String(grid.columns[index])
            color: grid.foreground
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize
            font.bold: true
            elide: Text.ElideRight
          }

          Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Util.alpha(grid.foreground, 0.12)
          }

          MouseArea {
            anchors.right: parent.right
            width: 8
            height: parent.height
            cursorShape: Qt.SplitHCursor
            property real startX: 0
            property real startW: 0
            onPressed: function(m) { startX = mapToItem(grid, m.x, 0).x; startW = grid.widths[index] }
            onPositionChanged: function(m) {
              if (pressed) grid.setWidth(index, startW + mapToItem(grid, m.x, 0).x - startX)
            }
            onDoubleClicked: grid.setWidth(index, 360)
          }
        }
      }
    }
  }

  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    clip: true
    model: grid.rows.length
    contentWidth: grid.totalWidth
    flickableDirection: Flickable.HorizontalAndVerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: true

    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: Rectangle {
      id: rowItem
      required property int index
      readonly property var values: grid.rows[index] || []
      width: grid.totalWidth
      height: grid.rowHeight
      color: index === grid.selRow ? Util.alpha(grid.accent, 0.10)
        : (index % 2 ? Util.alpha(grid.foreground, 0.025) : "transparent")

      Row {
        height: parent.height

        Text {
          width: grid.gutter
          height: parent.height
          horizontalAlignment: Text.AlignRight
          verticalAlignment: Text.AlignVCenter
          rightPadding: 8
          text: rowItem.index + 1
          color: grid.muted
          font.family: grid.fontFamily
          font.pixelSize: grid.fontSize - 1
        }

        Repeater {
          model: grid.columns.length

          delegate: Rectangle {
            required property int index
            readonly property var value: rowItem.values[index]
            readonly property bool selected: rowItem.index === grid.selRow && index === grid.selCol
            width: grid.widths[index] || 80
            height: rowItem.height
            color: selected ? Util.alpha(grid.accent, 0.25) : "transparent"
            border.width: selected ? 1 : 0
            border.color: grid.accent

            Text {
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              verticalAlignment: Text.AlignVCenter
              horizontalAlignment: typeof parent.value === "number" ? Text.AlignRight : Text.AlignLeft
              text: grid.cellText(parent.value)
              color: parent.value === null || parent.value === undefined ? grid.muted : grid.foreground
              font.family: grid.fontFamily
              font.pixelSize: grid.fontSize
              font.italic: parent.value === null || parent.value === undefined
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            Rectangle {
              anchors.right: parent.right
              width: 1
              height: parent.height
              color: Util.alpha(grid.foreground, 0.06)
            }

            MouseArea {
              anchors.fill: parent
              onClicked: { grid.selRow = rowItem.index; grid.selCol = index; grid.forceActiveFocus() }
              onDoubleClicked: grid.cellActivated(rowItem.index, index)
            }
          }
        }
      }
    }
  }

  Keys.onPressed: function(event) {
    if (selRow < 0) return
    var handled = true
    if (event.key === Qt.Key_Down) selRow = Math.min(rows.length - 1, selRow + 1)
    else if (event.key === Qt.Key_Up) selRow = Math.max(0, selRow - 1)
    else if (event.key === Qt.Key_Right) selCol = Math.min(columns.length - 1, selCol + 1)
    else if (event.key === Qt.Key_Left) selCol = Math.max(0, selCol - 1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) cellActivated(selRow, selCol)
    else handled = false
    if (handled) {
      event.accepted = true
      list.positionViewAtIndex(selRow, ListView.Contain)
    }
  }
}
