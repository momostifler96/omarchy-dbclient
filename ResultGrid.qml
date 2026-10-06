import QtQuick
import QtQuick.Controls
import qs.Commons
import "I18n.js" as I18n

// Spreadsheet-style view of one result set. A vertical ListView recycles row
// delegates; the header follows its horizontal scroll. Column widths are
// estimated from the data and can be dragged on the header edges.
//
// Columns keep their data index everywhere (selCol, edits, sortCol); only
// the display goes through `visibleCols` (the user's order, minus hidden
// columns). Drag a header to move it, click to sort, right-click for the
// column menu, or use the eye button in the corner to show/hide columns.
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

  // column layout (data indexes)
  property var order: []
  property var hidden: ({})
  readonly property var visibleCols: order.filter(function(c) { return !hidden[c] })
  readonly property int hiddenCount: order.length - visibleCols.length
  property int dropPos: -1             // display position while dragging a header
  property int resizingCol: -1
  property bool columnsOpen: false
  property var labels: ({ columns: "Columns", showAll: "Show all", reset: "Reset" })

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
    for (var i = 0; i < visibleCols.length; i++) w += widths[visibleCols[i]] || 80
    return w
  }

  signal cellActivated(int row, int col)
  signal cellEdited(int row, int col, var value)
  signal headerClicked(int col)
  signal deleteRequested()
  signal sortRequested(int col, bool desc)
  signal headerMenuRequested(int col, real x, real y)   // grid coordinates
  signal layoutEdited()

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
    columnsOpen = false
    order = cols.map(function(c, i) { return i })
    hidden = ({})
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
      var vis = visibleCols
      for (var n = vis.indexOf(c) + 1; n < vis.length; n++) if (canEdit(r, vis[n])) { beginEdit(r, vis[n]); return }
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

  // ---- column layout ------------------------------------------------------
  function firstCol() { return visibleCols.length ? visibleCols[0] : -1 }

  // Next visible column from the selected one, `dir` = ±1.
  function stepCol(dir) {
    var v = visibleCols, p = v.indexOf(selCol)
    if (p < 0) return firstCol()
    return v[Math.max(0, Math.min(v.length - 1, p + dir))]
  }

  // Display position (0…visible count) a header dropped at `x` lands on;
  // x is in header-row coordinates.
  function dropPosAt(x) {
    var start = gutter, v = visibleCols
    for (var i = 0; i < v.length; i++) {
      var w = widths[v[i]] || 80
      if (x < start + w / 2) return i
      start += w
    }
    return v.length
  }

  function dropX(pos) {
    var x = gutter, v = visibleCols
    for (var i = 0; i < pos && i < v.length; i++) x += widths[v[i]] || 80
    return x
  }

  // Move column `col` to display position `pos` (as returned by dropPosAt,
  // i.e. counted with the column still in place).
  function moveColumn(col, pos) {
    var v = visibleCols, cur = v.indexOf(col)
    if (cur < 0 || pos === cur || pos === cur + 1) return
    var rest = v.filter(function(c) { return c !== col })
    if (pos > cur) pos--
    var o = order.filter(function(c) { return c !== col })
    var at = pos < rest.length ? o.indexOf(rest[pos]) : o.indexOf(rest[rest.length - 1]) + 1
    o.splice(at, 0, col)
    order = o
    layoutEdited()
  }

  // Move `col` one step in the full order (hidden columns included).
  function shiftColumn(col, dir) {
    var o = order.slice(), i = o.indexOf(col), j = i + dir
    if (i < 0 || j < 0 || j >= o.length) return
    o[i] = o[j]
    o[j] = col
    order = o
    layoutEdited()
  }

  function setHidden(col, hide) {
    if (!hide === !hidden[col]) return
    if (hide && visibleCols.length <= 1) return   // keep at least one column
    var h = Object.assign({}, hidden)
    if (hide) h[col] = true
    else delete h[col]
    hidden = h
    if (hide && selCol === col) selCol = firstCol()
    layoutEdited()
  }

  function showAllColumns() {
    hidden = ({})
    layoutEdited()
  }

  function clearLayout() {
    if (hiddenCount === 0 && order.every(function(c, i) { return c === i })) return
    order = columns.map(function(c, i) { return i })
    hidden = ({})
  }

  function resetLayout() {
    order = columns.map(function(c, i) { return i })
    hidden = ({})
    layoutEdited()
  }

  // Layout by column name, so it survives reloads and re-runs.
  function layoutState() {
    var w = {}
    for (var c = 0; c < columns.length; c++) w[columns[c]] = widths[c]
    return { order: order.map(function(c) { return columns[c] }),
             hidden: order.filter(function(c) { return hidden[c] }).map(function(c) { return columns[c] }),
             widths: w }
  }

  function applyLayout(l) {
    if (!l || !columns.length) return
    var names = columns
    var o = (l.order || []).map(function(n) { return names.indexOf(n) }).filter(function(i) { return i >= 0 })
    for (var i = 0; i < names.length; i++) if (o.indexOf(i) < 0) o.push(i)
    var h = {}
    ;(l.hidden || []).forEach(function(n) { var k = names.indexOf(n); if (k >= 0) h[k] = true })
    if (o.every(function(c) { return h[c] })) h = {}
    var w = widths.slice()
    for (var c = 0; c < names.length; c++) if (l.widths && l.widths[names[c]] > 0) w[c] = l.widths[names[c]]
    order = o
    hidden = h
    widths = w
    if (selCol >= 0 && h[selCol]) selCol = firstCol()
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
    if (selCol < 0) selCol = firstCol()
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
    var vis = visibleCols
    var out = [vis.map(function(c) { return cell(columns[c]) }).join("\t")]
    var list = selectedRowList()
    for (var i = 0; i < list.length; i++) {
      var line = []
      for (var k = 0; k < vis.length; k++) line.push(cell(valueAt(list[i], vis[k])))
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
    if (selCol < 0) selCol = firstCol()
    grid.forceActiveFocus()
  }

  // Local sort for read-only query results.
  function sortLocal(c, forceDesc) {
    var desc = forceDesc !== undefined ? forceDesc : (sortCol === c ? !sortDesc : false)
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
      id: headerRow
      x: -list.contentX
      height: parent.height

      // Corner: show / hide columns
      Item {
        width: grid.gutter
        height: parent.height
        z: grid.visibleCols.length + 1

        Text {
          anchors.centerIn: parent
          text: I18n.glyph.eye
          color: grid.hiddenCount > 0 || grid.columnsOpen ? grid.accent : (cornerMouse.containsMouse ? grid.foreground : grid.muted)
          font.family: grid.fontFamily
          font.pixelSize: grid.fontSize
        }
        Text {
          visible: grid.hiddenCount > 0
          anchors.right: parent.right
          anchors.rightMargin: 4
          anchors.top: parent.top
          anchors.topMargin: 2
          text: grid.hiddenCount
          color: grid.accent
          font.family: grid.fontFamily
          font.pixelSize: Math.max(8, grid.fontSize - 4)
          font.bold: true
        }
        MouseArea {
          id: cornerMouse
          anchors.fill: parent
          hoverEnabled: true
          enabled: grid.columns.length > 0
          cursorShape: Qt.PointingHandCursor
          onClicked: grid.columnsOpen = !grid.columnsOpen
        }
      }

      Repeater {
        model: grid.visibleCols

        delegate: Item {
          id: headCell
          required property int modelData
          required property int index
          readonly property int col: modelData
          readonly property bool sorted: grid.sortCol === col
          width: grid.widths[col] || 80
          height: header.height
          // Earlier cells on top, so a resize handle can overlap the next one.
          z: grid.visibleCols.length - index

          Rectangle {
            anchors.fill: parent
            color: headMouse.dragging ? Util.alpha(grid.accent, 0.18)
              : (headMouse.containsMouse ? Util.alpha(grid.foreground, 0.05) : "transparent")
          }

          MouseArea {
            id: headMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            property real pressX: 0
            property bool dragging: false
            property bool moved: false
            onPressed: function(m) { pressX = m.x; dragging = false; moved = false }
            onPositionChanged: function(m) {
              if (!pressed || !(m.buttons & Qt.LeftButton)) return
              if (!dragging && Math.abs(m.x - pressX) > 6) dragging = true
              if (dragging) grid.dropPos = grid.dropPosAt(mapToItem(headerRow, m.x, 0).x)
            }
            onReleased: {
              if (!dragging) return
              var pos = grid.dropPos
              dragging = false
              moved = true
              grid.dropPos = -1
              if (pos >= 0) grid.moveColumn(headCell.col, pos)
            }
            onCanceled: { dragging = false; grid.dropPos = -1 }
            onClicked: function(m) {
              if (moved) return
              if (m.button === Qt.RightButton) {
                var p = mapToItem(grid, m.x, m.y)
                grid.headerMenuRequested(headCell.col, p.x, p.y)
              } else grid.headerClicked(headCell.col)
            }
          }

          Text {
            id: headLabel
            anchors.left: parent.left
            anchors.right: sortGlyph.left
            anchors.leftMargin: 8
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: String(grid.columns[headCell.col])
            color: grid.editable && grid.colEditable[headCell.col] === false ? grid.muted : grid.foreground
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize
            font.bold: true
            elide: Text.ElideRight
          }

          // Sort state; a faint ↕ on hover says "click to sort".
          Text {
            id: sortGlyph
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: headCell.sorted ? (grid.sortDesc ? I18n.glyph.sortDown : I18n.glyph.sortUp) : I18n.glyph.sortBoth
            visible: headCell.sorted || headMouse.containsMouse
            color: headCell.sorted ? grid.accent : grid.muted
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize - 1
          }

          Rectangle {
            anchors.right: parent.right
            width: resizeMouse.containsMouse || resizeMouse.pressed ? 2 : 1
            height: parent.height
            color: resizeMouse.containsMouse || resizeMouse.pressed ? grid.accent : Util.alpha(grid.foreground, 0.12)
          }

          // Resize handle: 16 px wide, centered on the column edge.
          MouseArea {
            id: resizeMouse
            x: parent.width - 8
            width: 16
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            property real startX: 0
            property real startW: 0
            onPressed: function(m) {
              startX = mapToItem(grid, m.x, 0).x
              startW = grid.widths[headCell.col]
              grid.resizingCol = headCell.col
            }
            onPositionChanged: function(m) {
              if (pressed) grid.setWidth(headCell.col, startW + mapToItem(grid, m.x, 0).x - startX)
            }
            onReleased: { grid.resizingCol = -1; grid.layoutEdited() }
            onCanceled: grid.resizingCol = -1
            onDoubleClicked: { grid.setWidth(headCell.col, 360); grid.layoutEdited() }
          }
        }
      }
    }

    // Where a dragged header will land
    Rectangle {
      visible: grid.dropPos >= 0
      x: grid.dropX(grid.dropPos) - list.contentX - 1
      width: 3
      height: parent.height
      color: grid.accent
    }
  }

  // Guide line under the column being resized
  Rectangle {
    visible: grid.resizingCol >= 0
    z: 5
    x: grid.resizingCol >= 0 ? grid.dropX(grid.visibleCols.indexOf(grid.resizingCol) + 1) - list.contentX - 1 : 0
    y: header.height
    width: 1
    height: grid.height - header.height
    color: Util.alpha(grid.accent, 0.6)
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
          model: grid.visibleCols

          delegate: Rectangle {
            id: cellItem
            required property int modelData
            readonly property int col: modelData
            readonly property int row: rowItem.index
            readonly property var value: grid.valueAt(row, col)
            readonly property bool selected: row === grid.selRow && col === grid.selCol
            readonly property bool edited: grid.isEdited(row, col)
            readonly property bool editing: row === grid.editRow && col === grid.editCol
            width: grid.widths[col] || 80
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
                grid.selCol = cellItem.col
                if (m.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) grid.selectRow(cellItem.row, m.modifiers)
                else grid.selectRow(cellItem.row, 0)
              }
              onDoubleClicked: {
                if (!grid.beginEdit(cellItem.row, cellItem.col)) grid.cellActivated(cellItem.row, cellItem.col)
              }
            }
          }
        }
      }
    }
  }

  // ---- column chooser (eye button) ---------------------------------------
  MouseArea {
    anchors.fill: parent
    visible: grid.columnsOpen
    z: 20
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: grid.columnsOpen = false
    onWheel: function(w) { w.accepted = true }
  }

  Rectangle {
    id: chooser
    visible: grid.columnsOpen
    z: 21
    x: 4
    y: header.height + 2
    width: Math.min(300, grid.width - 8)
    height: Math.min(chooserHead.height + 8 + grid.order.length * 28 + 8, grid.height - header.height - 8)
    radius: Style.cornerRadius
    color: Color.popups.background
    border.color: Color.popups.border
    border.width: Style.normalBorderWidth

    MouseArea { anchors.fill: parent; onWheel: function(w) { w.accepted = false } }

    Item {
      id: chooserHead
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 8
      height: 24

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: grid.labels.columns + "  " + grid.visibleCols.length + "/" + grid.order.length
        color: grid.muted
        font.family: grid.fontFamily
        font.pixelSize: grid.fontSize - 1
        font.bold: true
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 12
        Repeater {
          model: [{ text: grid.labels.showAll, run: grid.showAllColumns }, { text: grid.labels.reset, run: grid.resetLayout }]
          delegate: Text {
            required property var modelData
            text: modelData.text
            color: linkMouse.containsMouse ? grid.foreground : grid.accent
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize - 1
            MouseArea {
              id: linkMouse
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: parent.modelData.run()
            }
          }
        }
      }
    }

    ListView {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: chooserHead.bottom
      anchors.bottom: parent.bottom
      anchors.margins: 4
      anchors.topMargin: 4
      clip: true
      model: grid.order
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar {}

      delegate: Rectangle {
        id: chooserRow
        required property int modelData
        required property int index
        readonly property int col: modelData
        readonly property bool shown: !grid.hidden[col]
        width: ListView.view.width
        height: 28
        radius: Style.cornerRadius
        color: rowMouse.containsMouse ? Util.alpha(grid.foreground, 0.07) : "transparent"

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          onClicked: grid.setHidden(chooserRow.col, chooserRow.shown)
        }

        Text {
          id: check
          anchors.left: parent.left
          anchors.leftMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          width: 18
          text: chooserRow.shown ? I18n.glyph.eye : I18n.glyph.eyeClosed
          color: chooserRow.shown ? grid.accent : grid.muted
          font.family: grid.fontFamily
          font.pixelSize: grid.fontSize
        }
        Text {
          anchors.left: check.right
          anchors.leftMargin: 8
          anchors.right: arrows.left
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          text: String(grid.columns[chooserRow.col])
          color: chooserRow.shown ? grid.foreground : grid.muted
          font.family: grid.fontFamily
          font.pixelSize: grid.fontSize
          font.strikeout: !chooserRow.shown
          elide: Text.ElideRight
        }
        Row {
          id: arrows
          anchors.right: parent.right
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          visible: rowMouse.containsMouse || upMouse.containsMouse || downMouse.containsMouse
          spacing: 2
          Text {
            text: I18n.glyph.arrowUp
            color: upMouse.containsMouse ? grid.accent : grid.muted
            opacity: chooserRow.index > 0 ? 1 : 0.3
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize
            MouseArea { id: upMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; onClicked: grid.shiftColumn(chooserRow.col, -1) }
          }
          Text {
            text: I18n.glyph.arrowDown
            color: downMouse.containsMouse ? grid.accent : grid.muted
            opacity: chooserRow.index < grid.order.length - 1 ? 1 : 0.3
            font.family: grid.fontFamily
            font.pixelSize: grid.fontSize
            MouseArea { id: downMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; onClicked: grid.shiftColumn(chooserRow.col, 1) }
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
    else if (event.key === Qt.Key_Right) selCol = stepCol(1)
    else if (event.key === Qt.Key_Left) selCol = stepCol(-1)
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
