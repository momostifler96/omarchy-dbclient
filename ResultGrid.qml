import QtQuick
import QtQuick.Controls
import qs.Commons

// Spreadsheet-style view of one result set. A vertical ListView recycles row
// delegates; the header follows its horizontal scroll. Column widths are
// estimated from the data and can be dragged on the header edges.
//
// In editable mode (table tabs) the grid only *records* intent: edits,
// deleted and inserted rows live in the panel's tab state and are passed
// back in through `edits` / `deleted` / `baseCount`; nothing is written
// until the panel saves.
Item {
  id: grid

  property var columns: []
  property var rows: []
  property var widths: []
  property int selRow: -1
  property int selCol: -1
  property var selectedRows: ({})     // row -> true
  property int anchorRow: -1

  // editing
  property bool editable: false
  property var colEditable: []
  property int baseCount: -1           // rows >= baseCount are new (inserted)
  property var edits: ({})             // "row:col" -> value
  property var deleted: ({})           // row -> true
  property int editRow: -1
  property int editCol: -1
  property string editInitial: ""

  // sorting (server-side for tables, local for query results)
  property int sortCol: -1
  property bool sortDesc: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted
  property color urgent: Color.urgent
  readonly property color added: "#4caf50"
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body

  readonly property int rowHeight: Math.round(fontSize * 2)
  readonly property int gutter: Math.max(44, String(rows.length).length * fontSize * 0.7 + 20)
  readonly property int totalWidth: {
    var w = gutter
    for (var i = 0; i < widths.length; i++) w += widths[i]
    return w
  }

  signal cellActivated(int row, int col)
  signal cellEdited(int row, int col, var value)
  signal headerClicked(int col)
  signal deleteRequested()

  // keep: same columns as before (edits, paging) -> keep widths + selection
  function setResult(res, keep) {
    var cols = res ? res.columns : []
    var same = keep && cols.length === columns.length && cols.every(function(c, i) { return c === columns[i] })
    columns = cols
    rows = res ? res.rows : []
    editRow = -1
    if (same) {
      if (selRow >= rows.length) selRow = rows.length - 1
      return
    }
    selRow = -1
    selCol = -1
    selectedRows = ({})
    var charW = fontSize * 0.62
    var w = []
    for (var c = 0; c < cols.length; c++) {
      var n = String(cols[c]).length + 2
      var limit = Math.min(rows.length, 60)
      for (var r = 0; r < limit; r++) n = Math.max(n, Math.min(48, cellText(rows[r][c]).length))
      w.push(Math.round(Math.max(64, n * charW + 24)))
    }
    widths = w
    list.contentX = 0
    list.contentY = 0
  }

  function isNew(r) { return baseCount >= 0 && r >= baseCount }

  function valueAt(r, c) {
    var key = r + ":" + c
    if (key in edits) return edits[key]
    if (isNew(r)) return undefined
    var row = rows[r]
    return row ? row[c] : undefined
  }

  function isEdited(r, c) { return (r + ":" + c) in edits }

  function cellText(v) {
    if (v === null) return "NULL"
    if (v === undefined) return ""
    if (typeof v === "object") return JSON.stringify(v)
    var s = String(v)
    if (s.length > 400) s = s.slice(0, 400) + "…"
    return s.replace(/\r?\n/g, " ↵ ")
  }

  function rawText(v) {
    if (v === null || v === undefined) return ""
    return typeof v === "object" ? JSON.stringify(v) : String(v)
  }

  function canEdit(r, c) {
    return editable && r >= 0 && c >= 0 && colEditable[c] === true && !deleted[r]
  }

  function beginEdit(r, c, initial) {
    if (!canEdit(r, c)) return false
    selRow = r
    selCol = c
    editInitial = initial === undefined ? rawText(valueAt(r, c)) : initial
    editRow = r
    editCol = c
    return true
  }

  function commitEdit(text, move) {
    var r = editRow, c = editCol
    editRow = -1
    grid.forceActiveFocus()
    if (r < 0) return
    var old = valueAt(r, c)
    if (text !== rawText(old) || (old === undefined && text !== "")) cellEdited(r, c, text)
    if (move === "right") {
      for (var n = c + 1; n < columns.length; n++) if (canEdit(r, n)) { beginEdit(r, n); return }
    } else if (move === "down" && r + 1 < rows.length) {
      selRow = r + 1
      list.positionViewAtIndex(selRow, ListView.Contain)
    }
  }

  function showRow(r) {
    Qt.callLater(function() { list.positionViewAtIndex(r, ListView.Contain) })
  }

  function cancelEdit() {
    editRow = -1
    grid.forceActiveFocus()
  }

  function setWidth(i, value) {
    var w = widths.slice()
    w[i] = Math.max(36, Math.round(value))
    widths = w
  }

  function selectedValue() {
    if (selRow < 0 || selCol < 0 || selRow >= rows.length) return undefined
    return valueAt(selRow, selCol)
  }

  function selectedRowList() {
    var out = []
    for (var k in selectedRows) if (selectedRows[k]) out.push(parseInt(k, 10))
    if (out.length === 0 && selRow >= 0) out.push(selRow)
    return out.sort(function(a, b) { return a - b })
  }

  function selectAll() {
    if (!rows.length) return
    var s = {}
    for (var i = 0; i < rows.length; i++) s[i] = true
    selectedRows = s
    anchorRow = 0
    if (selRow < 0) selRow = 0
    if (selCol < 0) selCol = 0
    grid.forceActiveFocus()
  }

  function selectionCount() {
    var n = 0
    for (var k in selectedRows) if (selectedRows[k]) n++
    return n
  }

  // Selected rows as tab-separated text (with a header line), for pasting
  // into a spreadsheet.
  function selectedRowsText() {
    var cell = function(v) {
      if (v === null || v === undefined) return ""
      return (typeof v === "object" ? JSON.stringify(v) : String(v)).replace(/[\t\n\r]/g, " ")
    }
    var out = [columns.map(cell).join("\t")]
    var list = selectedRowList()
    for (var i = 0; i < list.length; i++) {
      var line = []
      for (var c = 0; c < columns.length; c++) line.push(cell(valueAt(list[i], c)))
      out.push(line.join("\t"))
    }
    return out.join("\n") + "\n"
  }

  function selectRow(r, modifiers) {
    var s = {}
    if (modifiers & Qt.ShiftModifier && anchorRow >= 0) {
      for (var i = Math.min(anchorRow, r); i <= Math.max(anchorRow, r); i++) s[i] = true
    } else if (modifiers & Qt.ControlModifier) {
      s = Object.assign({}, selectedRows)
      if (s[r]) delete s[r]
      else s[r] = true
      anchorRow = r
    } else {
      s[r] = true
      anchorRow = r
    }
    selectedRows = s
    selRow = r
    if (selCol < 0) selCol = 0
    grid.forceActiveFocus()
  }

  // Local sort for read-only query results.
  function sortLocal(c) {
    var desc = sortCol === c ? !sortDesc : false
    var sorted = rows.slice().sort(function(a, b) {
      var x = a[c], y = b[c]
      if (x === y) return 0
      if (x === null || x === undefined) return 1
      if (y === null || y === undefined) return -1
      var r = (typeof x === "number" && typeof y === "number") ? x - y : String(x).localeCompare(String(y))
      return desc ? -r : r
    })
    sortCol = c
    sortDesc = desc
    rows = sorted
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

          MouseArea {
            anchors.fill: parent
            onClicked: grid.headerClicked(index)
          }

          Text {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 10
            verticalAlignment: Text.AlignVCenter
            text: String(grid.columns[index]) + (grid.sortCol === index ? (grid.sortDesc ? "  ↓" : "  ↑") : "")
            color: grid.editable && grid.colEditable[index] === false ? grid.muted : grid.foreground
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

    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: Rectangle {
      id: rowItem
      required property int index
      readonly property bool isDeleted: grid.deleted[index] === true
      readonly property bool isAdded: grid.isNew(index)
      readonly property bool isSelected: grid.selectedRows[index] === true
      width: grid.totalWidth
      height: grid.rowHeight
      color: isDeleted ? Util.alpha(grid.urgent, 0.16)
        : isAdded ? Util.alpha(grid.added, 0.12)
        : isSelected ? Util.alpha(grid.accent, 0.12)
        : (index % 2 ? Util.alpha(grid.foreground, 0.025) : "transparent")

      Row {
        height: parent.height

        // Row number: click selects the row (Ctrl toggles, Shift extends)
        Rectangle {
          width: grid.gutter
          height: parent.height
          color: rowItem.isSelected ? Util.alpha(grid.accent, 0.25) : "transparent"
          Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            rightPadding: 8
            text: rowItem.isDeleted ? "−" : (rowItem.isAdded ? "+" : rowItem.index + 1)
            color: rowItem.isDeleted ? grid.urgent : (rowItem.isAdded ? grid.added : grid.muted)
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize - 1
            font.bold: rowItem.isDeleted || rowItem.isAdded
          }
          MouseArea {
            anchors.fill: parent
            onClicked: function(m) { grid.selectRow(rowItem.index, m.modifiers) }
          }
        }

        Repeater {
          model: grid.columns.length

          delegate: Rectangle {
            id: cellItem
            required property int index
            readonly property int row: rowItem.index
            readonly property var value: grid.valueAt(row, index)
            readonly property bool selected: row === grid.selRow && index === grid.selCol
            readonly property bool edited: grid.isEdited(row, index)
            readonly property bool editing: row === grid.editRow && index === grid.editCol
            width: grid.widths[index] || 80
            height: rowItem.height
            color: edited ? Util.alpha(grid.accent, 0.22) : (selected ? Util.alpha(grid.accent, 0.18) : "transparent")
            border.width: selected || editing ? 1 : 0
            border.color: grid.accent

            Text {
              visible: !cellItem.editing
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              verticalAlignment: Text.AlignVCenter
              horizontalAlignment: typeof cellItem.value === "number" ? Text.AlignRight : Text.AlignLeft
              text: cellItem.value === undefined && rowItem.isAdded ? "DEFAULT" : grid.cellText(cellItem.value)
              color: cellItem.value === null || cellItem.value === undefined || rowItem.isDeleted ? grid.muted : grid.foreground
              font.family: grid.fontFamily
              font.pixelSize: grid.fontSize
              font.italic: cellItem.value === null || cellItem.value === undefined
              font.strikeout: rowItem.isDeleted
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            Loader {
              anchors.fill: parent
              active: cellItem.editing
              sourceComponent: TextField {
                text: grid.editInitial
                font.family: grid.fontFamily
                font.pixelSize: grid.fontSize
                color: grid.foreground
                selectionColor: Util.alpha(grid.accent, 0.35)
                leftPadding: 7
                rightPadding: 4
                topPadding: 0
                bottomPadding: 0
                background: Rectangle { color: Color.background; border.color: grid.accent; border.width: 1 }
                Component.onCompleted: {
                  forceActiveFocus()
                  if (grid.editInitial.length > 1) selectAll()
                  else cursorPosition = text.length
                }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { grid.cancelEdit(); event.accepted = true }
                  else if (event.key === Qt.Key_Tab) { grid.commitEdit(text, "right"); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { grid.commitEdit(text, "down"); event.accepted = true }
                }
                onActiveFocusChanged: if (!activeFocus && cellItem.editing) grid.commitEdit(text, "")
              }
            }

            Rectangle {
              anchors.right: parent.right
              width: 1
              height: parent.height
              color: Util.alpha(grid.foreground, 0.06)
            }

            MouseArea {
              anchors.fill: parent
              enabled: !cellItem.editing
              onClicked: function(m) {
                grid.selCol = cellItem.index
                if (m.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) grid.selectRow(cellItem.row, m.modifiers)
                else grid.selectRow(cellItem.row, 0)
              }
              onDoubleClicked: {
                if (!grid.beginEdit(cellItem.row, cellItem.index)) grid.cellActivated(cellItem.row, cellItem.index)
              }
            }
          }
        }
      }
    }
  }

  Keys.onPressed: function(event) {
    if (editRow >= 0) {
      // Typed before the cell editor took focus: keep the keystrokes.
      if (event.text && event.text.length === 1 && event.text >= " ") {
        editInitial += event.text
        event.accepted = true
      }
      return
    }
    var handled = true
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Down) selRow = Math.min(rows.length - 1, selRow + 1)
    else if (event.key === Qt.Key_Up) selRow = Math.max(0, selRow - 1)
    else if (event.key === Qt.Key_Right) selCol = Math.min(columns.length - 1, selCol + 1)
    else if (event.key === Qt.Key_Left) selCol = Math.max(0, selCol - 1)
    else if (event.key === Qt.Key_A && ctrl) { selectAll(); event.accepted = true; return }
    else if (event.key === Qt.Key_Home && ctrl) selRow = rows.length ? 0 : -1
    else if (event.key === Qt.Key_End && ctrl) selRow = rows.length - 1
    else if (event.key === Qt.Key_PageDown) selRow = Math.min(rows.length - 1, selRow + Math.max(1, Math.floor(list.height / rowHeight) - 1))
    else if (event.key === Qt.Key_PageUp) selRow = Math.max(0, selRow - Math.max(1, Math.floor(list.height / rowHeight) - 1))
    else if (event.key === Qt.Key_F2) beginEdit(selRow, selCol)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!beginEdit(selRow, selCol)) cellActivated(selRow, selCol)
    } else if (event.key === Qt.Key_Delete && editable) deleteRequested()
    else if (!ctrl && event.text && event.text.length === 1 && event.text >= " " && canEdit(selRow, selCol))
      beginEdit(selRow, selCol, event.text)
    else handled = false
    if (handled) {
      event.accepted = true
      if (selRow >= 0 && event.key !== Qt.Key_Delete) {
        var s = {}
        if (event.modifiers & Qt.ShiftModifier && anchorRow >= 0) {
          for (var i = Math.min(anchorRow, selRow); i <= Math.max(anchorRow, selRow); i++) s[i] = true
        } else {
          s[selRow] = true
          anchorRow = selRow
        }
        selectedRows = s
        list.positionViewAtIndex(selRow, ListView.Contain)
      }
    }
  }
}
