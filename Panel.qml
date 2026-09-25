import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// DB client window: connection tree on the left, query tabs with an editor
// and a result grid on the right. All database work happens in
// backend/dbclient.py (see Backend.qml); this file only holds UI state.
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "momoledev.dbclient"
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))

  // ---- lifecycle ----------------------------------------------------------
  property bool opened: false
  property bool closingFromHost: false

  function open(payloadJson) {
    closingFromHost = false
    opened = true
    window.visible = true
    if (!ready) init()
    // Optional payload: {"connId": "...", "database": "...", "text": "...", "run": true}
    // opens a query tab (used by `omarchy-dbclient query`).
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.connId || payload.text) {
      var start = function() {
        openQuery(payload.connId || "", payload.database || "", payload.text || "", payload.title || "", payload.run === true)
      }
      if (ready) start()
      else pendingOpen = start
    }
    Qt.callLater(function() { if (editor) editor.forceActiveFocus() })
  }

  function close() {
    saveEditor()
    saveState()
    closingFromHost = true
    window.visible = false
    closingFromHost = false
    opened = false
  }

  function toggle() {
    if (opened) requestClose()
    else open("")
  }

  // Single-argument entry points for `omarchy-shell shell call momoledev.dbclient <fn> <arg>`.
  function expand(connId) {
    if (!opened) open("")
    var go = function() { if (!stateFor(nodeKey(connId, [])).expanded) toggleNode(connId, [], false) }
    if (ready) go()
    else pendingOpen = go
  }

  function newConnection() {
    if (!opened) open("")
    connDialog.openNew()
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // ---- i18n + theme -------------------------------------------------------
  property string language: "auto"
  readonly property string lang: I18n.resolve(language, Qt.locale().name)
  function tr(k, a, b) { return I18n.tr(lang, k, a, b) }

  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color line: Util.alpha(fg, 0.12)
  readonly property string fontFamily: Style.font.family
  readonly property int fontSize: Style.font.body

  // ---- data ---------------------------------------------------------------
  property bool ready: false
  property var connections: []
  property var drivers: ({})
  property string venvPath: ""

  property var treeState: ({})     // key -> { expanded, loading, error, children }
  property var treeRows: []
  property string selectedKey: ""

  property var tabs: []
  property int currentTab: -1
  property int tabCounter: 0
  readonly property var tab: currentTab >= 0 && currentTab < tabs.length ? tabs[currentTab] : null
  readonly property var tabConn: tab ? connById(tab.connId) : null
  readonly property var tabResult: tab && tab.results.length ? tab.results[Math.min(tab.resultIndex, tab.results.length - 1)] : null

  property string toastText: ""

  function init() {
    backend.request("hello", {}, function(ok, res, msg) {
      if (!ok) { toast(msg.error); return }
      drivers = res.drivers
      venvPath = res.venv
      language = (res.settings && res.settings.language) || "auto"
      restoreState(res.state || {})
      loadConnections(function() {
        ready = true
        if (pendingOpen) { var f = pendingOpen; pendingOpen = null; f() }
      })
    })
  }

  property var pendingOpen: null

  // Open tabs survive closing the window (the panel stays loaded) and shell
  // restarts (tabs.json in ~/.local/state/omarchy-dbclient).
  function restoreState(state) {
    var saved = Array.isArray(state.tabs) ? state.tabs : []
    var list = []
    for (var i = 0; i < saved.length; i++) {
      var t = saved[i]
      tabCounter = Math.max(tabCounter, t.uid || 0)
      list.push({ uid: t.uid || (i + 1), title: t.title || tr("queryTab", i + 1), connId: t.connId || "",
                  database: t.database || "", text: t.text || "", results: [], resultIndex: 0,
                  running: false, error: "", elapsedMs: 0 })
    }
    if (list.length) {
      tabs = list
      currentTab = Math.max(0, Math.min(state.current || 0, list.length - 1))
      loadEditor()
    } else if (tabs.length === 0) {
      newTab("", "", "")
    }
  }

  function saveState() {
    if (!ready) return
    saveEditor()
    var list = tabs.map(function(t) {
      return { uid: t.uid, title: t.title, connId: t.connId, database: t.database, text: t.text }
    })
    backend.request("save_state", { state: { tabs: list, current: currentTab } }, null)
  }

  Timer {
    id: saveStateTimer
    interval: 1500
    onTriggered: root.saveState()
  }

  function setLanguage(l) {
    language = l
    backend.request("set_settings", { settings: { language: l } }, null)
  }

  function toast(text) {
    toastText = text
    toastTimer.restart()
  }

  function connById(id) {
    for (var i = 0; i < connections.length; i++) if (connections[i].id === id) return connections[i]
    return null
  }

  function loadConnections(then) {
    backend.request("list_connections", {}, function(ok, res, msg) {
      if (!ok) { toast(msg.error); return }
      connections = res
      rebuildTree()
      if (tab && !tab.connId && res.length) updateTab(tab.uid, { connId: res[0].id })
      if (typeof then === "function") then()
    })
  }

  function setConnected(connId, value) {
    var list = connections.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === connId && list[i].connected !== value) {
        list[i] = Object.assign({}, list[i], { connected: value })
        connections = list
        return
      }
    }
  }

  // ---- drivers ------------------------------------------------------------
  function promptDriver(type, then) {
    driverDialog.prompt(type, then)
  }

  function handleError(msg, retry) {
    if (msg && msg.code === "driver_missing") {
      promptDriver(msg.type, retry)
      return true
    }
    return false
  }

  // ---- tree ---------------------------------------------------------------
  function nodeKey(connId, path) { return connId + "|" + JSON.stringify(path || []) }

  function stateFor(key) { return treeState[key] || { expanded: false, loading: false, error: "", children: null } }

  function setState(key, fields) {
    var s = Object.assign({}, treeState)
    s[key] = Object.assign({}, stateFor(key), fields)
    treeState = s
    rebuildTree()
  }

  function toggleNode(connId, path, leaf) {
    var key = nodeKey(connId, path)
    selectedKey = key
    if (leaf) return
    var st = stateFor(key)
    if (st.expanded) { setState(key, { expanded: false }); return }
    setState(key, { expanded: true })
    if (st.children === null && !st.loading) loadChildren(connId, path)
  }

  function loadChildren(connId, path) {
    var key = nodeKey(connId, path)
    setState(key, { loading: true, error: "" })
    backend.request("children", { connId: connId, path: path }, function(ok, res, msg) {
      if (ok) {
        setConnected(connId, true)
        setState(key, { loading: false, children: res, error: "" })
      } else {
        setState(key, { loading: false, expanded: path.length > 0, error: msg.error })
        if (handleError(msg, function() { loadChildren(connId, path); setState(key, { expanded: true }) })) return
        if (path.length === 0) toast(msg.error)
      }
    })
  }

  function refreshNode(connId, path) {
    var key = nodeKey(connId, path)
    var prefix = connId + "|"
    var s = Object.assign({}, treeState)
    // Drop cached descendants too: their paths start with the same connId.
    if (path.length === 0) {
      for (var k in s) if (k.indexOf(prefix) === 0 && k !== key) delete s[k]
    }
    s[key] = Object.assign({}, stateFor(key), { children: null, expanded: true })
    treeState = s
    loadChildren(connId, path)
  }

  function disconnect(connId) {
    backend.request("disconnect", { connId: connId }, null)
    var s = Object.assign({}, treeState)
    for (var k in s) if (k.indexOf(connId + "|") === 0) delete s[k]
    treeState = s
    setConnected(connId, false)
    rebuildTree()
  }

  function rebuildTree() {
    var rows = []
    for (var i = 0; i < connections.length; i++) {
      var c = connections[i]
      var key = nodeKey(c.id, [])
      var st = stateFor(key)
      rows.push({ key: key, connId: c.id, depth: 0, isConn: true, conn: c, path: [], leaf: false,
                  label: c.name, detail: connDetail(c), kind: c.type, expanded: st.expanded, action: "",
                  database: "" })
      if (st.expanded) addChildren(rows, c.id, [], 1)
    }
    treeRows = rows
  }

  function addChildren(rows, connId, path, depth) {
    var st = stateFor(nodeKey(connId, path))
    if (st.loading) rows.push({ key: nodeKey(connId, path) + "#loading", connId: connId, depth: depth, placeholder: true,
                                label: tr("loading"), kind: "info", leaf: true, path: path })
    if (st.error) rows.push({ key: nodeKey(connId, path) + "#error", connId: connId, depth: depth, placeholder: true,
                              label: st.error, kind: "error", leaf: true, path: path })
    if (!st.children) return
    if (st.children.length === 0 && !st.loading)
      rows.push({ key: nodeKey(connId, path) + "#empty", connId: connId, depth: depth, placeholder: true,
                  label: tr("empty"), kind: "info", leaf: true, path: path })
    for (var i = 0; i < st.children.length; i++) {
      var n = st.children[i]
      var key = nodeKey(connId, n.path)
      var cst = stateFor(key)
      rows.push({ key: key, connId: connId, depth: depth, isConn: false, path: n.path, leaf: n.leaf,
                  label: n.label, detail: n.detail, kind: n.kind, expanded: cst.expanded, action: n.action,
                  database: n.database })
      if (cst.expanded && !n.leaf) addChildren(rows, connId, n.path, depth + 1)
    }
  }

  function connDetail(c) {
    if (c.type === "sqlite") return String(c.file || "").replace(/^.*\//, "")
    if (c.uri) return c.uri.replace(/\/\/[^@]*@/, "//")
    return (c.host || "localhost") + (c.port ? ":" + c.port : "")
  }

  function openNodeAction(row) {
    if (row.action) openQuery(row.connId, row.database, row.action, row.label, true)
  }

  // Reuse the current tab when it is blank, otherwise open a new one.
  function openQuery(connId, database, text, title, run) {
    var t = tab
    if (t && !editor.text.trim() && !t.results.length && !t.running) {
      updateTab(t.uid, { connId: connId || t.connId, database: database || "", title: title || t.title })
      editor.text = text
    } else {
      newTab(connId, database, text, title)
    }
    if (run) runQuery()
  }

  // ---- tabs ---------------------------------------------------------------
  function newTab(connId, database, text, title) {
    saveEditor()
    tabCounter++
    var list = tabs.slice()
    var fallback = tab ? tab.connId : (connections.length ? connections[0].id : "")
    list.push({ uid: tabCounter, title: title || tr("queryTab", tabCounter), connId: connId || fallback,
                database: database || "", text: text || "", results: [], resultIndex: 0,
                running: false, error: "", elapsedMs: 0 })
    tabs = list
    currentTab = list.length - 1
    loadEditor()
    saveStateTimer.restart()
  }

  function tabIndex(uid) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].uid === uid) return i
    return -1
  }

  function updateTab(uid, fields) {
    var i = tabIndex(uid)
    if (i < 0) return
    var list = tabs.slice()
    list[i] = Object.assign({}, list[i], fields)
    tabs = list
    saveStateTimer.restart()
    if (i === currentTab && (fields.results !== undefined || fields.resultIndex !== undefined)) showResult()
  }

  function selectTab(i) {
    if (i === currentTab || i < 0 || i >= tabs.length) return
    saveEditor()
    currentTab = i
    loadEditor()
  }

  function closeTab(i) {
    saveEditor()
    var list = tabs.slice()
    list.splice(i, 1)
    tabs = list
    if (list.length === 0) {
      currentTab = -1
      newTab("", "", "")
      return
    }
    currentTab = Math.min(currentTab > i ? currentTab - 1 : currentTab, list.length - 1)
    loadEditor()
    saveStateTimer.restart()
  }

  property bool loadingEditor: false

  function saveEditor() {
    if (!tab || !editor || loadingEditor) return
    if (tab.text === editor.text) return
    tab.text = editor.text   // silent: typing must not rebuild the tab strip
    saveStateTimer.restart()
  }

  function loadEditor() {
    if (!editor) return
    loadingEditor = true
    editor.text = tab ? tab.text : ""
    loadingEditor = false
    showResult()
  }

  function showResult() {
    grid.setResult(tabResult && tabResult.columns.length ? tabResult : null)
  }

  // ---- queries ------------------------------------------------------------
  function runQuery() {
    saveEditor()
    var t = tab
    if (!t) return
    if (!t.connId || !connById(t.connId)) { toast(tr("noConnection")); return }
    var text = editor.selectedText && editor.selectedText.trim() ? editor.selectedText : editor.text
    if (!text.trim() || t.running) return
    var uid = t.uid
    updateTab(uid, { running: true, error: "" })
    backend.request("query", { connId: t.connId, database: t.database, text: text, limit: limitValue() },
                    function(ok, res, msg) {
      if (ok) {
        setConnected(t.connId, true)
        var results = res.results
        // Prefer the last result that has rows; otherwise the last message.
        var idx = results.length - 1
        for (var i = results.length - 1; i >= 0; i--) if (results[i].columns.length) { idx = i; break }
        updateTab(uid, { running: false, results: results, resultIndex: Math.max(0, idx), elapsedMs: res.elapsedMs, error: "" })
      } else {
        updateTab(uid, { running: false, error: msg.error })
        handleError(msg, function() { selectTab(tabIndex(uid)); runQuery() })
      }
    })
  }

  function limitValue() {
    var n = parseInt(limitField.text, 10)
    return isFinite(n) && n > 0 ? n : 1000
  }

  function editorHint() {
    var c = tabConn
    if (!c) return tr("noConnection")
    if (c.type === "redis") return tr("redisHint")
    if (c.type === "mongodb") return tr("mongoHint")
    return tr("sqlHint")
  }

  // ---- export -------------------------------------------------------------
  function csvCell(v) {
    if (v === null || v === undefined) return ""
    var s = typeof v === "object" ? JSON.stringify(v) : String(v)
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s
  }

  function toCsv(res) {
    var out = [res.columns.map(csvCell).join(",")]
    for (var i = 0; i < res.rows.length; i++) out.push(res.rows[i].map(csvCell).join(","))
    return out.join("\n") + "\n"
  }

  function toJson(res) {
    if (res.documents) return "[\n" + res.documents.join(",\n") + "\n]\n"
    var list = []
    for (var i = 0; i < res.rows.length; i++) {
      var o = {}
      for (var c = 0; c < res.columns.length; c++) o[res.columns[c]] = res.rows[i][c]
      list.push(o)
    }
    return JSON.stringify(list, null, 2) + "\n"
  }

  function copyText(text) {
    Quickshell.clipboardText = text
    toast(tr("copied"))
  }

  function exportCsv() {
    if (!tabResult) return
    var stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19)
    var path = Quickshell.env("HOME") + "/Downloads/dbclient-" + stamp + ".csv"
    backend.request("write_file", { path: path, content: toCsv(tabResult) }, function(ok, res, msg) {
      toast(ok ? tr("exported", res) : msg.error)
    })
  }

  function showCell(row, col) {
    var r = tabResult
    if (!r) return
    var v = r.rows[row][col]
    var text = v === null || v === undefined ? "NULL" : (typeof v === "object" ? JSON.stringify(v, null, 2) : String(v))
    if (typeof v === "string" && /^[\[{]/.test(v)) {
      try { text = JSON.stringify(JSON.parse(v), null, 2) } catch (e) {}
    }
    if (r.documents && col === 0 && r.columns[0] === "_id") {
      try { text = JSON.stringify(JSON.parse(r.documents[row]), null, 2) } catch (e) {}
    }
    cellDialog.title = String(r.columns[col])
    cellDialog.value = text
    cellDialog.opened = true
  }

  // ---- backend ------------------------------------------------------------
  property alias backend: backendItem

  Backend {
    id: backendItem
    script: root.pluginDir + "backend/dbclient.py"
    onEvent: function(msg) {
      if (msg.event === "drivers") root.drivers = msg.result.drivers
      driverDialog.onBackendEvent(msg)
    }
    onCrashed: function(reason) {
      root.toast(root.tr("backendCrashed", reason))
      // Sessions died with the process: collapse everything.
      root.treeState = ({})
      var list = root.connections.map(function(c) { return Object.assign({}, c, { connected: false }) })
      root.connections = list
      root.rebuildTree()
    }
  }

  Timer {
    id: toastTimer
    interval: 3500
    onTriggered: root.toastText = ""
  }

  // ---- window -------------------------------------------------------------
  FloatingWindow {
    id: window
    title: root.tr("title")
    color: root.bg
    implicitWidth: 1280
    implicitHeight: 800
    minimumSize: Qt.size(820, 520)
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost) {
        root.saveEditor()
        root.opened = false
        if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
      }
    }

    Shortcut { sequences: ["Ctrl+Return", "Ctrl+Enter", "F5"]; onActivated: root.runQuery() }
    Shortcut { sequence: "Ctrl+T"; onActivated: root.newTab("", "", "") }
    Shortcut { sequence: "Ctrl+W"; onActivated: if (root.currentTab >= 0) root.closeTab(root.currentTab) }
    Shortcut { sequence: "Ctrl+N"; onActivated: connDialog.openNew() }
    Shortcut { sequence: "Ctrl+Tab"; onActivated: root.selectTab((root.currentTab + 1) % root.tabs.length) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: root.selectTab((root.currentTab - 1 + root.tabs.length) % root.tabs.length) }
    Shortcut {
      sequence: "Escape"
      onActivated: {
        if (cellDialog.opened) cellDialog.opened = false
        else if (driverDialog.opened && !driverDialog.busy) driverDialog.close()
        else if (connDialog.opened) connDialog.close()
        else if (deleteConfirm.opened) deleteConfirm.opened = false
      }
    }
    Shortcut {
      sequences: [StandardKey.Copy]
      enabled: grid.activeFocus && grid.selRow >= 0
      onActivated: {
        var v = grid.selectedValue()
        root.copyText(v === null || v === undefined ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v)))
      }
    }

    SplitView {
      anchors.fill: parent
      orientation: Qt.Horizontal

      handle: Rectangle {
        implicitWidth: 1
        color: SplitHandle.hovered || SplitHandle.pressed ? root.accent : root.line
      }

      // ---- sidebar --------------------------------------------------------
      Item {
        SplitView.preferredWidth: 300
        SplitView.minimumWidth: 200

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.fg, 0.025)
        }

        Item {
          id: sideHeader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: 40

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: root.tr("connections").toUpperCase()
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Button {
              iconText: I18n.glyph.add
              tooltipText: root.tr("newConnection") + " (Ctrl+N)"
              onClicked: connDialog.openNew()
            }
            Button {
              iconText: I18n.glyph.drivers
              tooltipText: root.tr("drivers")
              onClicked: driverDialog.showList()
            }
          }
        }

        ListView {
          id: tree
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: sideHeader.bottom
          anchors.bottom: sideFooter.top
          clip: true
          model: root.treeRows
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar {}

          delegate: Rectangle {
            id: rowDelegate
            required property var modelData
            readonly property var r: modelData
            readonly property bool hovered: rowMouse.containsMouse
            width: tree.width
            height: r.isConn ? 32 : 26
            color: root.selectedKey === r.key ? Util.alpha(root.accent, 0.14)
              : (hovered ? Util.alpha(root.fg, 0.05) : "transparent")

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(m) {
                if (rowDelegate.r.placeholder) return
                if (m.button === Qt.MiddleButton && rowDelegate.r.action) { root.openNodeAction(rowDelegate.r); return }
                root.toggleNode(rowDelegate.r.connId, rowDelegate.r.path, rowDelegate.r.leaf)
              }
              onDoubleClicked: if (rowDelegate.r.action) root.openNodeAction(rowDelegate.r)
            }

            Row {
              anchors.left: parent.left
              anchors.leftMargin: 8 + rowDelegate.r.depth * 14
              anchors.right: actions.visible ? actions.left : parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6

              Text {
                width: 12
                anchors.verticalCenter: parent.verticalCenter
                text: rowDelegate.r.leaf ? "" : (rowDelegate.r.expanded ? I18n.glyph.chevronDown : I18n.glyph.chevronRight)
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: kindIcon
                anchors.verticalCenter: parent.verticalCenter
                text: rowDelegate.r.isConn ? I18n.types[rowDelegate.r.kind].icon
                  : (rowDelegate.r.kind === "error" ? I18n.glyph.warning : (I18n.kindIcons[rowDelegate.r.kind] || ""))
                color: rowDelegate.r.isConn ? I18n.types[rowDelegate.r.kind].color
                  : (rowDelegate.r.kind === "error" ? root.urgent : root.muted)
                font.family: root.fontFamily
                font.pixelSize: rowDelegate.r.isConn ? Style.font.iconLarge : Style.font.body
              }

              Text {
                id: labelText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width - 12 - kindIcon.width - 12 - (dot.visible ? 14 : 0))
                text: rowDelegate.r.label
                color: rowDelegate.r.kind === "error" ? root.urgent : (rowDelegate.r.placeholder ? root.muted : root.fg)
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                font.bold: rowDelegate.r.isConn === true
                font.italic: rowDelegate.r.placeholder === true
                elide: Text.ElideRight
              }

              Rectangle {
                id: dot
                visible: rowDelegate.r.isConn === true && rowDelegate.r.conn.connected === true
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 3.5
                color: "#4caf50"
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - x)
                text: rowDelegate.r.detail || ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.rightMargin: 4
              anchors.verticalCenter: parent.verticalCenter
              visible: rowDelegate.hovered && !rowDelegate.r.placeholder && (rowDelegate.r.isConn || rowDelegate.r.action || !rowDelegate.r.leaf)
              spacing: 0

              Button {
                visible: !!rowDelegate.r.action
                iconText: I18n.glyph.play
                tooltipText: root.tr("run")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: root.openNodeAction(rowDelegate.r)
              }
              Button {
                visible: rowDelegate.r.isConn === true
                iconText: I18n.glyph.newFile
                tooltipText: root.tr("newQuery")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: root.newTab(rowDelegate.r.connId, "", "")
              }
              Button {
                visible: !rowDelegate.r.leaf
                iconText: I18n.glyph.refresh
                tooltipText: root.tr("refresh")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: root.refreshNode(rowDelegate.r.connId, rowDelegate.r.path)
              }
              Button {
                visible: rowDelegate.r.isConn === true && rowDelegate.r.conn.connected === true
                iconText: I18n.glyph.disconnect
                tooltipText: root.tr("disconnect")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: root.disconnect(rowDelegate.r.connId)
              }
              Button {
                visible: rowDelegate.r.isConn === true
                iconText: I18n.glyph.edit
                tooltipText: root.tr("edit")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: connDialog.openEdit(rowDelegate.r.conn)
              }
              Button {
                visible: rowDelegate.r.isConn === true
                iconText: I18n.glyph.trash
                tooltipText: root.tr("remove")
                horizontalPadding: 5; verticalPadding: 2
                onClicked: {
                  deleteConfirm.connId = rowDelegate.r.connId
                  deleteConfirm.message = root.tr("deleteConfirm", rowDelegate.r.label)
                  deleteConfirm.selectedIndex = 0
                  deleteConfirm.opened = true
                }
              }
            }
          }

          // Empty state
          Column {
            anchors.centerIn: parent
            visible: root.ready && root.connections.length === 0
            spacing: Style.spacing.lg
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tr("noConnections")
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
            }
            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tr("addFirst")
              iconText: I18n.glyph.add
              bordered: true
              onClicked: connDialog.openNew()
            }
          }
        }

        Item {
          id: sideFooter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 34

          Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.line }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Repeater {
              model: ["auto", "en", "fr"]
              delegate: Button {
                required property string modelData
                text: modelData.toUpperCase()
                fontSize: Style.font.caption
                horizontalPadding: 6; verticalPadding: 2
                selected: root.language === modelData
                onClicked: root.setLanguage(modelData)
              }
            }
          }
        }
      }

      // ---- main area ------------------------------------------------------
      Item {
        SplitView.fillWidth: true

        // Tab strip
        Item {
          id: tabStrip
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: 38

          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }

          ListView {
            id: tabList
            anchors.left: parent.left
            anchors.right: addTab.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            orientation: ListView.Horizontal
            clip: true
            model: root.tabs
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: tabItem
              required property var modelData
              required property int index
              readonly property bool current: index === root.currentTab
              readonly property var conn: root.connById(modelData.connId)
              width: Math.min(240, tabRow.implicitWidth + 24)
              height: tabList.height
              color: current ? root.bg : (tabMouse.containsMouse ? Util.alpha(root.fg, 0.04) : Util.alpha(root.fg, 0.02))

              Rectangle { visible: tabItem.current; anchors.top: parent.top; width: parent.width; height: 2; color: root.accent }
              Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: root.line }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onClicked: function(m) {
                  if (m.button === Qt.MiddleButton) root.closeTab(tabItem.index)
                  else root.selectTab(tabItem.index)
                }
              }

              Row {
                id: tabRow
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: tabItem.conn ? I18n.types[tabItem.conn.type].icon : ""
                  color: tabItem.conn ? I18n.types[tabItem.conn.type].color : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, 150)
                  text: tabItem.modelData.title
                  color: tabItem.current ? root.fg : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSize
                  elide: Text.ElideRight
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: tabItem.modelData.running ? "…" : I18n.glyph.close
                  color: closeMouse.containsMouse ? root.urgent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    onClicked: root.closeTab(tabItem.index)
                  }
                }
              }
            }
          }

          Button {
            id: addTab
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            iconText: I18n.glyph.add
            tooltipText: root.tr("newQuery") + " (Ctrl+T)"
            onClicked: root.newTab("", "", "")
          }
        }

        // Toolbar
        Row {
          id: toolbar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: tabStrip.bottom
          anchors.margins: 8
          height: Style.spacing.controlHeight
          spacing: Style.spacing.lg

          Dropdown {
            id: connPicker
            width: 240
            showLabel: false
            value: root.tab ? root.tab.connId : ""
            options: root.connections.map(function(c) { return { value: c.id, label: c.name } })
            onChanged: function(v) { if (root.tab) root.updateTab(root.tab.uid, { connId: v }) }
          }

          TextField {
            id: dbField
            width: 170
            text: root.tab ? root.tab.database : ""
            placeholderText: root.tr("database")
            onTextEdited: if (root.tab) root.tab.database = text
            onEditingFinished: if (root.tab && root.tab.database !== text) root.updateTab(root.tab.uid, { database: text })
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.tr("limit")
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: limitField
            width: 80
            text: "1000"
            validator: IntValidator { bottom: 1; top: 100000 }
          }

          Button {
            text: root.tab && root.tab.running ? root.tr("running") : root.tr("run")
            iconText: I18n.glyph.play
            iconSpinning: root.tab ? root.tab.running : false
            tooltipText: root.tr("runHint")
            bordered: true
            selected: true
            enabled: root.tab ? !root.tab.running : false
            onClicked: root.runQuery()
          }
        }

        // Editor + results, vertically resizable
        SplitView {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: toolbar.bottom
          anchors.bottom: statusBar.top
          anchors.topMargin: 8
          orientation: Qt.Vertical

          handle: Rectangle {
            implicitHeight: 1
            color: SplitHandle.hovered || SplitHandle.pressed ? root.accent : root.line
          }

          ScrollView {
            id: editorScroll
            SplitView.preferredHeight: 260
            SplitView.minimumHeight: 80
            clip: true

            TextArea {
              id: editor
              font.family: root.fontFamily
              font.pixelSize: root.fontSize + 1
              color: root.fg
              selectionColor: Util.alpha(root.accent, 0.35)
              selectedTextColor: root.fg
              placeholderText: root.editorHint()
              placeholderTextColor: root.muted
              wrapMode: TextEdit.NoWrap
              selectByMouse: true
              persistentSelection: true
              leftPadding: 14
              topPadding: 10
              background: Rectangle { color: "transparent" }
              onTextChanged: if (!root.loadingEditor) saveStateTimer.restart()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ControlModifier)) {
                  editor.insert(editor.cursorPosition, "  ")
                  event.accepted = true
                }
              }
            }
          }

          // Results pane
          Item {
            SplitView.fillHeight: true
            SplitView.minimumHeight: 120

            // Result selector when a run produced several result sets
            Row {
              id: resultTabs
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.margins: 6
              height: visible ? Style.spacing.controlHeight : 0
              visible: root.tab !== null && root.tab.results.length > 1
              spacing: 2
              Repeater {
                model: root.tab ? root.tab.results.length : 0
                delegate: Button {
                  required property int index
                  text: root.tr("result", index + 1)
                  fontSize: Style.font.bodySmall
                  selected: root.tab && root.tab.resultIndex === index
                  onClicked: root.updateTab(root.tab.uid, { resultIndex: index })
                }
              }
            }

            ResultGrid {
              id: grid
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: resultTabs.bottom
              anchors.bottom: parent.bottom
              anchors.topMargin: resultTabs.visible ? 6 : 0
              visible: root.tabResult !== null && root.tabResult.columns.length > 0 && !(root.tab && root.tab.error)
              foreground: root.fg
              accent: root.accent
              muted: root.muted
              fontFamily: root.fontFamily
              fontSize: root.fontSize
              onCellActivated: function(r, c) { root.showCell(r, c) }
            }

            // Message / error / empty state
            Text {
              anchors.fill: parent
              anchors.margins: 16
              visible: !grid.visible
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              verticalAlignment: root.tab && root.tab.error ? Text.AlignTop : Text.AlignVCenter
              horizontalAlignment: root.tab && root.tab.error ? Text.AlignLeft : Text.AlignHCenter
              color: root.tab && root.tab.error ? root.urgent : root.muted
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
              text: {
                if (!root.tab) return ""
                if (root.tab.error) return I18n.glyph.warning + "  " + root.tab.error
                if (root.tabResult) {
                  var lines = []
                  for (var i = 0; i < root.tab.results.length; i++) {
                    var r = root.tab.results[i]
                    lines.push((r.message || root.tr("rows", r.rowCount)) + "   — " + r.statement.replace(/\s+/g, " ").slice(0, 90))
                  }
                  return lines.join("\n")
                }
                return root.tr("noResult")
              }
            }
          }
        }

        // Status bar
        Item {
          id: statusBar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 34

          Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.line }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: {
              var r = root.tabResult
              if (!r || !root.tab || root.tab.error) return root.tab && root.tab.running ? root.tr("running") : ""
              var s = r.columns.length ? (r.rowCount === 1 ? root.tr("row") : root.tr("rows", r.rowCount)) : r.message
              if (r.truncated) s += " (" + root.tr("truncated", r.rowCount) + ")"
              return s + " · " + root.tab.elapsedMs + " ms"
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.toastText !== ""
            text: root.toastText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
            width: Math.min(implicitWidth, parent.width - 420)
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: grid.visible
            spacing: 2

            Button {
              text: root.tr("copyCsv")
              iconText: I18n.glyph.copy
              fontSize: Style.font.bodySmall
              onClicked: root.copyText(root.toCsv(root.tabResult))
            }
            Button {
              text: root.tr("copyJson")
              iconText: I18n.glyph.copy
              fontSize: Style.font.bodySmall
              onClicked: root.copyText(root.toJson(root.tabResult))
            }
            Button {
              text: root.tr("exportCsv")
              iconText: I18n.glyph.exportFile
              fontSize: Style.font.bodySmall
              onClicked: root.exportCsv()
            }
          }
        }
      }
    }

    // ---- overlays ---------------------------------------------------------
    ConnectionDialog {
      id: connDialog
      anchors.fill: parent
      panel: root
      onSaved: function(conn) {
        root.toast(root.tr("savedConnection"))
        // Editing drops the live session; forget its cached tree.
        var s = Object.assign({}, root.treeState)
        for (var k in s) if (k.indexOf(conn.id + "|") === 0) delete s[k]
        root.treeState = s
        root.loadConnections(function() {
          if (root.tab && !root.connById(root.tab.connId)) root.updateTab(root.tab.uid, { connId: conn.id })
          root.toggleNode(conn.id, [], false)
        })
      }
    }

    DriverDialog {
      id: driverDialog
      anchors.fill: parent
      panel: root
    }

    ConfirmDialog {
      id: deleteConfirm
      property string connId: ""
      anchors.fill: parent
      cancelText: root.tr("cancel")
      confirmText: root.tr("remove")
      onCanceled: opened = false
      onConfirmed: {
        opened = false
        var id = connId
        root.backend_deleteConnection(id)
      }
    }

    // Full cell value viewer
    Rectangle {
      id: cellDialog
      property bool opened: false
      property string title: ""
      property string value: ""
      anchors.fill: parent
      visible: opened
      color: Util.alpha(root.bg, 0.7)

      MouseArea { anchors.fill: parent; onClicked: cellDialog.opened = false }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(parent.width - 60, 760)
        height: Math.min(parent.height - 60, 520)
        color: Color.popups.background
        borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
        radius: Style.cornerRadius

        MouseArea { anchors.fill: parent }

        Text {
          id: cellTitle
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: 16
          text: cellDialog.title
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        ScrollView {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: cellTitle.bottom
          anchors.bottom: cellButtons.top
          anchors.margins: 16
          clip: true
          TextArea {
            readOnly: true
            selectByMouse: true
            text: cellDialog.value
            color: root.fg
            wrapMode: TextEdit.WrapAnywhere
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            background: Rectangle { color: Util.alpha(root.fg, 0.04); radius: Style.cornerRadius }
          }
        }

        Row {
          id: cellButtons
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 16
          spacing: Style.spacing.lg
          Button {
            text: root.tr("copy")
            iconText: I18n.glyph.copy
            bordered: true
            onClicked: root.copyText(cellDialog.value)
          }
          Button {
            text: root.tr("close")
            bordered: true
            onClicked: cellDialog.opened = false
          }
        }
      }
    }
  }

  function backend_deleteConnection(id) {
    backend.request("delete_connection", { connId: id }, function(ok, res, msg) {
      if (!ok) { toast(msg.error); return }
      var s = Object.assign({}, treeState)
      for (var k in s) if (k.indexOf(id + "|") === 0) delete s[k]
      treeState = s
      loadConnections()
    })
  }

  Component.onDestruction: backend.stop()
}
