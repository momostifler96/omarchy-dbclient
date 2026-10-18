import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// Value picker for a foreign key cell: lists rows of the referenced table
// (key columns first, then a few descriptive columns), searchable on the
// server. Picking a row calls onPick(values) with one value per FK column.
Rectangle {
  id: dlg

  property var panel: null
  property bool opened: false
  property string connId: ""
  property var path: []
  property string column: ""
  property string current: ""      // value currently in the cell
  property var onPick: null
  property var result: null        // fk_lookup response
  property bool loading: false
  property string error: ""
  property int requestSeq: 0
  property int highlighted: 0

  function tr(k, a, b) { return panel ? panel.tr(k, a, b) : k }

  function open(conn, tablePath, col, currentValue, pick) {
    connId = conn
    path = tablePath
    column = col
    current = currentValue === null || currentValue === undefined ? "" : String(currentValue)
    onPick = pick
    result = null
    error = ""
    highlighted = 0
    search.text = ""
    opened = true
    load()
    Qt.callLater(function() { search.forceActiveFocus() })
  }

  function close() { opened = false }

  function load() {
    var seq = ++requestSeq
    loading = true
    panel.backend.request("fk_lookup", { connId: connId, path: path, column: column, search: search.text, limit: 300 },
                          function(ok, res, msg) {
      if (seq !== requestSeq) return
      loading = false
      if (!ok) { error = msg.error; result = null; return }
      error = ""
      result = res
      // Start on the current value when it is in the list.
      highlighted = 0
      for (var i = 0; i < res.rows.length; i++)
        if (String(res.rows[i][0]) === current) { highlighted = i; break }
      Qt.callLater(function() { list.positionViewAtIndex(highlighted, ListView.Center) })
    })
  }

  function choose(i) {
    if (!result || i < 0 || i >= result.rows.length) return
    var row = result.rows[i]
    // One value per FK column, taken from the matching referenced column.
    var values = result.fkColumns.map(function(c, k) {
      var v = row[result.columns.indexOf(result.refColumns[k])]
      return v === null || v === undefined ? null : (typeof v === "object" ? JSON.stringify(v) : String(v))
    })
    var f = onPick
    close()
    if (typeof f === "function") f(values)
  }

  function cellText(v) {
    if (v === null || v === undefined) return "NULL"
    return typeof v === "object" ? JSON.stringify(v) : String(v)
  }

  anchors.fill: parent
  visible: opened
  color: Util.alpha(Color.background, 0.7)

  Timer {
    id: searchTimer
    interval: 250
    onTriggered: dlg.load()
  }

  MouseArea { anchors.fill: parent; onClicked: dlg.close() }

  BorderSurface {
    anchors.centerIn: parent
    width: Math.min(parent.width - 60, 720)
    height: Math.min(parent.height - 60, 560)
    color: Color.popups.background
    borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    MouseArea { anchors.fill: parent }

    Column {
      id: head
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 16
      spacing: Style.spacing.md

      Text {
        width: parent.width
        text: I18n.glyph.link + "  " + dlg.tr("pickTitle", dlg.column, dlg.result ? dlg.result.label : "…")
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      TextField {
        id: search
        width: parent.width
        placeholderText: dlg.tr("pickSearch")
        onTextEdited: searchTimer.restart()
        Keys.onPressed: function(event) {
          var n = dlg.result ? dlg.result.rows.length : 0
          if (event.key === Qt.Key_Down) { dlg.highlighted = Math.min(n - 1, dlg.highlighted + 1); list.positionViewAtIndex(dlg.highlighted, ListView.Contain); event.accepted = true }
          else if (event.key === Qt.Key_Up) { dlg.highlighted = Math.max(0, dlg.highlighted - 1); list.positionViewAtIndex(dlg.highlighted, ListView.Contain); event.accepted = true }
          else if (event.key === Qt.Key_PageDown) { dlg.highlighted = Math.min(n - 1, dlg.highlighted + 10); list.positionViewAtIndex(dlg.highlighted, ListView.Contain); event.accepted = true }
          else if (event.key === Qt.Key_PageUp) { dlg.highlighted = Math.max(0, dlg.highlighted - 10); list.positionViewAtIndex(dlg.highlighted, ListView.Contain); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { dlg.choose(dlg.highlighted); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { dlg.close(); event.accepted = true }
        }
      }

      // Column titles
      Row {
        width: parent.width
        visible: dlg.result !== null && dlg.result.rows.length > 0
        Repeater {
          model: dlg.result ? dlg.result.columns : []
          delegate: Text {
            required property var modelData
            required property int index
            width: index === 0 ? 170 : Math.max(80, (head.width - 170) / Math.max(1, dlg.result.columns.length - 1))
            leftPadding: 8
            text: String(modelData)
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }
        }
      }
    }

    ListView {
      id: list
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: head.bottom
      anchors.bottom: footer.top
      anchors.margins: 16
      anchors.topMargin: 4
      clip: true
      model: dlg.result ? dlg.result.rows : []
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar {}

      delegate: Rectangle {
        id: entry
        required property var modelData
        required property int index
        readonly property bool isCurrent: String(modelData[0]) === dlg.current && dlg.current !== ""
        width: list.width
        height: 30
        radius: Style.cornerRadius
        color: index === dlg.highlighted ? Util.alpha(Color.accent, 0.2)
          : (rowMouse.containsMouse ? Util.alpha(Color.foreground, 0.06) : "transparent")

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          onClicked: dlg.highlighted = entry.index
          onDoubleClicked: dlg.choose(entry.index)
        }

        Row {
          anchors.fill: parent
          Repeater {
            model: entry.modelData.length
            delegate: Text {
              required property int index
              width: index === 0 ? 170 : Math.max(80, (list.width - 170) / Math.max(1, entry.modelData.length - 1))
              height: entry.height
              leftPadding: 8
              rightPadding: 6
              verticalAlignment: Text.AlignVCenter
              text: (index === 0 && entry.isCurrent ? I18n.glyph.check + " " : "") + dlg.cellText(entry.modelData[index])
              color: index === 0 ? Color.accent : (entry.modelData[index] === null ? Color.muted : Color.foreground)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: index === 0
              elide: Text.ElideRight
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: dlg.loading || dlg.error !== "" || (dlg.result !== null && dlg.result.rows.length === 0)
        width: parent.width - 40
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: dlg.loading ? dlg.tr("loading") : (dlg.error !== "" ? dlg.error : dlg.tr("pickEmpty"))
        color: dlg.error !== "" ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Item {
      id: footer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 16
      height: Style.spacing.controlHeight

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: dlg.result ? dlg.tr("pickCount", dlg.result.rows.length) : ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.lg
        Button {
          text: dlg.tr("cancel")
          bordered: true
          onClicked: dlg.close()
        }
        Button {
          text: dlg.tr("pickChoose")
          iconText: I18n.glyph.check
          bordered: true
          selected: true
          enabled: dlg.result !== null && dlg.result.rows.length > 0
          onClicked: dlg.choose(dlg.highlighted)
        }
      }
    }
  }
}
