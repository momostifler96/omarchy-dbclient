import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// DB client window: schema tree on the left; on the right, tabs that are
// either query tabs (editor + results) or table tabs (editable data grid).
// All database work happens in backend/dbclient.py (see Backend.qml); this
// file only holds UI state.
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
    Qt.callLater(function() { if (editor && !tabIsTable) editor.forceActiveFocus() })
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

  // {"connId": "...", "path": [...], "label": "...", "database": "..."}
  function openTableJson(arg) {
    if (!opened) open("")
    var o = JSON.parse(arg)
    var go = function() { openTable({ connId: o.connId, path: o.path, label: o.label || o.path[o.path.length - 1],
                                      database: o.database || "" }) }
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

  // A tab is { uid, kind: "query"|"table", title, connId, database, … }
  //   query: text, results, resultIndex, running, error, elapsedMs
  //   table: path, where, order, desc, offset, data, edits, deleted, inserted, loading, error
  property var tabs: []
  property int currentTab: -1
  property int tabCounter: 0
  readonly property var tab: currentTab >= 0 && currentTab < tabs.length ? tabs[currentTab] : null
  readonly property bool tabIsTable: tab !== null && tab.kind === "table"
  readonly property var tabConn: tab ? connById(tab.connId) : null
  readonly property var tabResult: tab && !tabIsTable && tab.results.length ? tab.results[Math.min(tab.resultIndex, tab.results.length - 1)] : null
  readonly property var tabData: tabIsTable ? tab.data : null
  readonly property int pendingCount: tabIsTable ? buildChanges(tab).length : 0

  // Text fields lose their binding once typed in: resync them per tab.
  onCurrentTabChanged: {
    if (filterField) filterField.text = tabIsTable ? tab.where : ""
    if (dbField) dbField.text = tab ? tab.database : ""
  }

  property string toastText: ""
  property bool toastError: false
  property var pendingOpen: null

  function init() {
    backend.request("hello", {}, function(ok, res, msg) {
      if (!ok) { toast(msg.error, true); return }
      drivers = res.drivers
      venvPath = res.venv
      language = (res.settings && res.settings.language) || "auto"
      restoreState(res.state || {})
      loadConnections(function() {
        ready = true
        if (tabIsTable && !tab.data) loadTable(tab.uid)
        if (pendingOpen) { var f = pendingOpen; pendingOpen = null; f() }
      })
    })
  }

  // Open tabs survive closing the window (the panel stays loaded) and shell
  // restarts (tabs.json in ~/.local/state/omarchy-dbclient).
  function restoreState(state) {
    var saved = Array.isArray(state.tabs) ? state.tabs : []
    var list = []
    for (var i = 0; i < saved.length; i++) {
      var t = saved[i]
      tabCounter = Math.max(tabCounter, t.uid || 0)
      if (t.kind === "table") list.push(tableTab(t.uid || (i + 1), t.connId, t.database, t.path, t.title, t))
      else list.push(queryTab(t.uid || (i + 1), t.connId, t.database, t.text, t.title || tr("queryTab", i + 1)))
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
      if (t.kind === "table")
        return { uid: t.uid, kind: "table", title: t.title, connId: t.connId, database: t.database, path: t.path,
                 where: t.where, order: t.order, desc: t.desc }
      return { uid: t.uid, kind: "query", title: t.title, connId: t.connId, database: t.database, text: t.text }
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

  function toast(text, isError) {
    toastText = String(text || "").split("\n")[0]
    toastError = isError === true
    toastTimer.interval = isError ? 7000 : 3500
    toastTimer.restart()
  }

  function connById(id) {
    for (var i = 0; i < connections.length; i++) if (connections[i].id === id) return connections[i]
    return null
  }

  function loadConnections(then) {
    backend.request("list_connections", {}, function(ok, res, msg) {
      if (!ok) { toast(msg.error, true); return }
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

  // ---- confirmations ------------------------------------------------------
  function ask(title, message, sql, confirmText, danger, onYes) {
    askDialog.title = title
    askDialog.message = message
    askDialog.sql = sql || ""
    askDialog.confirmText = confirmText
    askDialog.danger = danger === true
    askDialog.onYes = onYes
    askDialog.opened = true
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
        if (path.length === 0) toast(msg.error, true)
      }
    })
  }

  function refreshNode(connId, path) {
    var key = nodeKey(connId, path)
    var s = Object.assign({}, treeState)
    // Drop cached descendants: a refresh reloads the whole subtree.
    for (var k in s) {
      if (k === key || k.indexOf(connId + "|") !== 0) continue
      var p = JSON.parse(k.slice(connId.length + 1))
      if (path.length === 0 || isDescendant(p, path)) delete s[k]
    }
    s[key] = Object.assign({}, stateFor(key), { children: null, expanded: true })
    treeState = s
    loadChildren(connId, path)
  }

  // Child paths are built by the backend, so descendants are recognised by
  // containing every non-kind segment of the parent path.
  function isDescendant(p, parent) {
    if (p.length <= 1) return false
    for (var i = 1; i < parent.length; i++) if (p.indexOf(parent[i]) < 0) return false
    return true
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
      rows.push({ key: key, connId: c.id, depth: 0, isConn: true, conn: c, path: [], parentPath: [], leaf: false,
                  label: c.name, detail: connDetail(c), kind: c.type, expanded: st.expanded, action: "",
                  database: "", ops: [], open: "" })
      if (st.expanded) addChildren(rows, c.id, [], 1)
    }
    treeRows = rows
  }

  function addChildren(rows, connId, path, depth) {
    var st = stateFor(nodeKey(connId, path))
    var base = { connId: connId, depth: depth, placeholder: true, leaf: true, path: path, parentPath: path, ops: [] }
    if (st.loading) rows.push(Object.assign({ key: nodeKey(connId, path) + "#loading", label: tr("loading"), kind: "info" }, base))
    if (st.error) rows.push(Object.assign({ key: nodeKey(connId, path) + "#error", label: st.error, kind: "error" }, base))
    if (!st.children) return
    if (st.children.length === 0 && !st.loading)
      rows.push(Object.assign({ key: nodeKey(connId, path) + "#empty", label: tr("empty"), kind: "info" }, base))
    for (var i = 0; i < st.children.length; i++) {
      var n = st.children[i]
      var key = nodeKey(connId, n.path)
      var cst = stateFor(key)
      rows.push({ key: key, connId: connId, depth: depth, isConn: false, path: n.path, parentPath: path, leaf: n.leaf,
                  label: n.kind === "folder" ? tr("f_" + n.label) : n.label, rawLabel: n.label,
                  detail: n.detail, kind: n.kind, expanded: cst.expanded, action: n.action,
                  database: n.database, ops: n.ops || [], open: n.open || "" })
      if (cst.expanded && !n.leaf) addChildren(rows, connId, n.path, depth + 1)
    }
  }

  function connDetail(c) {
    if (c.type === "sqlite") return String(c.file || "").replace(/^.*\//, "")
    if (c.uri) return c.uri.replace(/\/\/[^@]*@/, "//")
    return (c.host || "localhost") + (c.port ? ":" + c.port : "")
  }

  // ---- object actions -----------------------------------------------------
  function activateRow(row) {
    if (row.placeholder || row.isConn) return
    if (row.open === "data") openTable(row)
    else if (row.open === "ddl") runOp(row, "ddl")
    else if (row.action) openQuery(row.connId, row.database, row.action, row.label, true)
  }

  function opLabel(row, op) {
    if (op === "create") {
      if (row.kind === "folder") return tr("create") + " " + row.label.toLowerCase()
      var type = connById(row.connId) ? connById(row.connId).type : ""
      if (type === "postgresql") return tr("newSchema")
      if (type === "mongodb") return tr("newCollection")
      if (type === "redis") return tr("newKey")
      return tr("create")
    }
    return tr({ data: "openData", select: "selectQuery", ddl: "ddl", create_index: "createIndex",
                truncate: "truncate", refresh: "refreshMv", drop: "drop" }[op] || op)
  }

  function opIcon(op) {
    return { data: I18n.glyph.table, select: I18n.glyph.play, ddl: I18n.glyph.code, create: I18n.glyph.add,
             create_index: I18n.glyph.add, truncate: I18n.glyph.discard, refresh: I18n.glyph.refresh,
             drop: I18n.glyph.trash }[op] || ""
  }

  function runOp(row, op) {
    if (op === "data") { openTable(row); return }
    if (op === "select") { openQuery(row.connId, row.database, row.action, row.label, true); return }
    backend.request("object_sql", { connId: row.connId, path: row.path, op: op }, function(ok, res, msg) {
      if (!ok) { if (!handleError(msg, null)) toast(msg.error, true); return }
      var database = res.database || row.database || ""
      if (!res.confirm) {
        newTab(row.connId, database, res.sql, res.title || row.label)
        return
      }
      ask(tr("confirmRunTitle"), op === "drop" || op === "truncate" ? tr("confirmDrop") : "", res.sql,
          opLabel(row, op), op === "drop" || op === "truncate", function() {
        executeSql(row.connId, database, res.sql, function() {
          if (op === "drop") refreshNode(row.connId, row.parentPath)
          else if (tabIsTable) loadTable(tab.uid)
        })
      })
    })
  }

  function executeSql(connId, database, sql, then) {
    backend.request("query", { connId: connId, database: database, text: sql, limit: 100 }, function(ok, res, msg) {
      if (!ok) { toast(msg.error, true); return }
      toast(tr("done"))
      if (typeof then === "function") then()
    })
  }

  function rowMenu(row) {
    var items = []
    if (row.isConn) {
      var type = row.conn.type
      items.push({ text: tr("newQuery"), icon: I18n.glyph.newFile, run: function() { newTab(row.connId, "", "") } })
      if (type === "mysql" || type === "postgresql" || type === "clickhouse")
        items.push({ text: tr("newDatabase"), icon: I18n.glyph.database, run: function() { runOp(row, "create") } })
      items.push({ text: tr("refresh"), icon: I18n.glyph.refresh, run: function() { refreshNode(row.connId, []) } })
      if (row.conn.connected)
        items.push({ text: tr("disconnect"), icon: I18n.glyph.disconnect, run: function() { disconnect(row.connId) } })
      items.push(null)
      items.push({ text: tr("edit"), icon: I18n.glyph.edit, run: function() { connDialog.openEdit(row.conn) } })
      items.push({ text: tr("remove"), icon: I18n.glyph.trash, danger: true, run: function() { confirmDeleteConnection(row) } })
      return items
    }
    for (var i = 0; i < row.ops.length; i++) {
      var op = row.ops[i]
      if (op === "drop" || op === "truncate") continue
      items.push({ text: opLabel(row, op), icon: opIcon(op), run: (function(o) { return function() { runOp(row, o) } })(op) })
    }
    if (!row.leaf) items.push({ text: tr("refresh"), icon: I18n.glyph.refresh, run: function() { refreshNode(row.connId, row.path) } })
    if (row.kind !== "folder")
      items.push({ text: tr("copyName"), icon: I18n.glyph.copy, run: function() { copyText(row.rawLabel || row.label) } })
    var danger = row.ops.filter(function(o) { return o === "truncate" || o === "drop" })
    if (danger.length) items.push(null)
    for (var j = 0; j < danger.length; j++)
      items.push({ text: opLabel(row, danger[j]), icon: opIcon(danger[j]), danger: true,
                   run: (function(o) { return function() { runOp(row, o) } })(danger[j]) })
    return items
  }

  function confirmDeleteConnection(row) {
    ask(tr("remove"), tr("deleteConfirm", row.label), "", tr("remove"), true, function() {
      backend.request("delete_connection", { connId: row.connId }, function(ok, res, msg) {
        if (!ok) { toast(msg.error, true); return }
        var s = Object.assign({}, treeState)
        for (var k in s) if (k.indexOf(row.connId + "|") === 0) delete s[k]
        treeState = s
        loadConnections()
      })
    })
  }

  // ---- tabs ---------------------------------------------------------------
  function queryTab(uid, connId, database, text, title) {
    return { uid: uid, kind: "query", title: title, connId: connId || "", database: database || "",
             text: text || "", results: [], resultIndex: 0, running: false, error: "", elapsedMs: 0 }
  }

  function tableTab(uid, connId, database, path, title, saved) {
    saved = saved || {}
    return { uid: uid, kind: "table", title: title, connId: connId, database: database || "", path: path,
             where: saved.where || "", order: saved.order || "", desc: saved.desc === true, offset: 0,
             data: null, edits: {}, deleted: {}, inserted: 0, loading: false, error: "", elapsedMs: 0 }
  }

  function newTab(connId, database, text, title) {
    saveEditor()
    tabCounter++
    var list = tabs.slice()
    var fallback = tab ? tab.connId : (connections.length ? connections[0].id : "")
    list.push(queryTab(tabCounter, connId || fallback, database, text, title || tr("queryTab", tabCounter)))
    tabs = list
    currentTab = list.length - 1
    loadEditor()
    saveStateTimer.restart()
  }

  // Reuse the current tab when it is a blank query tab, otherwise open a new one.
  function openQuery(connId, database, text, title, run) {
    var t = tab
    if (t && t.kind === "query" && !editor.text.trim() && !t.results.length && !t.running) {
      updateTab(t.uid, { connId: connId || t.connId, database: database || "", title: title || t.title })
      editor.text = text
    } else {
      newTab(connId, database, text, title)
    }
    if (run) runQuery()
  }

  function openTable(row) {
    var key = JSON.stringify(row.path)
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].kind === "table" && tabs[i].connId === row.connId && JSON.stringify(tabs[i].path) === key) {
        selectTab(i)
        return
      }
    }
    saveEditor()
    tabCounter++
    var list = tabs.slice()
    list.push(tableTab(tabCounter, row.connId, row.database, row.path, row.label))
    tabs = list
    currentTab = list.length - 1
    loadEditor()
    loadTable(tabCounter)
    saveStateTimer.restart()
  }

  function tabIndex(uid) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].uid === uid) return i
    return -1
  }

  function tabByUid(uid) {
    var i = tabIndex(uid)
    return i >= 0 ? tabs[i] : null
  }

  function updateTab(uid, fields) {
    var i = tabIndex(uid)
    if (i < 0) return
    var list = tabs.slice()
    list[i] = Object.assign({}, list[i], fields)
    tabs = list
    saveStateTimer.restart()
    if (i === currentTab && (fields.results !== undefined || fields.resultIndex !== undefined
                             || fields.data !== undefined || fields.inserted !== undefined)) showResult()
  }

  function selectTab(i) {
    if (i === currentTab || i < 0 || i >= tabs.length) return
    saveEditor()
    currentTab = i
    loadEditor()
    if (tabIsTable && !tab.data && !tab.loading && ready) loadTable(tab.uid)
  }

  function closeTab(i) {
    var t = tabs[i]
    if (t && t.kind === "table" && buildChanges(t).length) {
      ask(tr("discard"), tr("discardConfirm", t.title), "", tr("discard"), true, function() { doCloseTab(tabIndex(t.uid)) })
      return
    }
    doCloseTab(i)
  }

  function doCloseTab(i) {
    if (i < 0) return
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
    if (tabIsTable && !tab.data && !tab.loading) loadTable(tab.uid)
    saveStateTimer.restart()
  }

  property bool loadingEditor: false

  function saveEditor() {
    if (!tab || tab.kind !== "query" || !editor || loadingEditor) return
    if (tab.text === editor.text) return
    tab.text = editor.text   // silent: typing must not rebuild the tab strip
    saveStateTimer.restart()
  }

  function loadEditor() {
    if (!editor) return
    loadingEditor = true
    editor.text = tab && tab.kind === "query" ? tab.text : ""
    loadingEditor = false
    showResult()
  }

  function showResult() {
    if (tabIsTable) {
      var d = tab.data
      if (!d) { grid.setResult(null); return }
      var rows = d.rows.slice()
      for (var i = 0; i < tab.inserted; i++) rows.push([])
      grid.setResult({ columns: d.columns, rows: rows }, true)
      grid.sortCol = d.columns.indexOf(tab.order)
      grid.sortDesc = tab.desc
    } else {
      grid.setResult(tabResult && tabResult.columns.length ? tabResult : null)
      grid.sortCol = -1
    }
  }

  // ---- queries ------------------------------------------------------------
  function runQuery() {
    if (tabIsTable) { reloadTable(); return }
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

  function pageSize() {
    var n = parseInt(pageField.text, 10)
    return isFinite(n) && n > 0 ? n : 200
  }

  function editorHint() {
    var c = tabConn
    if (!c) return tr("noConnection")
    if (c.type === "redis") return tr("redisHint")
    if (c.type === "mongodb") return tr("mongoHint")
    return tr("sqlHint")
  }

  // ---- table editor -------------------------------------------------------
  function loadTable(uid) {
    var t = tabByUid(uid)
    if (!t) return
    updateTab(uid, { loading: true, error: "" })
    backend.request("table_data", { connId: t.connId, path: t.path, where: t.where, order: t.order, desc: t.desc,
                                    offset: t.offset, limit: pageSize() }, function(ok, res, msg) {
      if (ok) {
        setConnected(t.connId, true)
        updateTab(uid, { loading: false, data: res, edits: {}, deleted: {}, inserted: 0, error: "",
                         elapsedMs: res.elapsedMs })
        if (tab && tab.uid === uid) grid.forceActiveFocus()
      } else {
        updateTab(uid, { loading: false, error: msg.error })
        if (!handleError(msg, function() { loadTable(uid) })) toast(msg.error, true)
      }
    })
  }

  // Reload after checking for unsaved edits; `change` tweaks the query first.
  function reloadTable(change) {
    var t = tab
    if (!tabIsTable) return
    var go = function() {
      if (change) updateTab(t.uid, change)
      loadTable(t.uid)
    }
    if (buildChanges(t).length) ask(tr("discard"), tr("discardConfirm", t.title), "", tr("discard"), true, go)
    else go()
  }

  function sortTable(col) {
    var name = tab.data.columns[col]
    reloadTable({ order: name, desc: tab.order === name ? !tab.desc : false, offset: 0 })
  }

  function setCell(r, c, value) {
    var t = tab
    var edits = Object.assign({}, t.edits)
    var key = r + ":" + c
    var base = t.data.rows.length
    var original = r < base ? t.data.rows[r][c] : undefined
    var originalText = original === null || original === undefined ? null
      : (typeof original === "object" ? JSON.stringify(original) : String(original))
    if (r < base && value === originalText) delete edits[key]
    else edits[key] = value
    updateTab(t.uid, { edits: edits })
  }

  function addRow() {
    var t = tab
    if (!tabIsTable || !t.data || !t.data.editable) return
    updateTab(t.uid, { inserted: t.inserted + 1 })
    var r = t.data.rows.length + t.inserted
    // Start typing in the first editable column that is not part of the key
    // (keys are usually generated: identity, AUTOINCREMENT, ObjectId…).
    var c = -1
    for (var i = 0; i < t.data.columns.length && c < 0; i++)
      if (t.data.colEditable[i] && t.data.keyColumns.indexOf(t.data.columns[i]) < 0) c = i
    if (c < 0) c = t.data.colEditable.indexOf(true)
    grid.selectRow(r, 0)
    grid.showRow(r)
    if (c >= 0) grid.beginEdit(r, c)
  }

  function toggleDeleteRows() {
    var t = tab
    if (!tabIsTable || !t.data || !t.data.editable) return
    var rows = grid.selectedRowList()
    if (!rows.length) return
    var deleted = Object.assign({}, t.deleted)
    var allDeleted = rows.every(function(r) { return deleted[r] })
    rows.forEach(function(r) { if (allDeleted) delete deleted[r]; else deleted[r] = true })
    updateTab(t.uid, { deleted: deleted })
  }

  function setNull() {
    if (grid.canEdit(grid.selRow, grid.selCol)) setCell(grid.selRow, grid.selCol, null)
  }

  function discardChanges() {
    if (tabIsTable) updateTab(tab.uid, { edits: {}, deleted: {}, inserted: 0 })
  }

  function buildChanges(t) {
    if (!t || t.kind !== "table" || !t.data) return []
    var d = t.data, base = d.rows.length, byRow = {}, changes = []
    for (var k in t.edits) {
      var p = k.split(":")
      var r = parseInt(p[0], 10)
      if (!byRow[r]) byRow[r] = {}
      byRow[r][d.columns[parseInt(p[1], 10)]] = t.edits[k]
    }
    for (var i = 0; i < base; i++) {
      if (t.deleted[i]) changes.push({ op: "delete", key: d.keys[i] })
      else if (byRow[i]) changes.push({ op: "update", key: d.keys[i], values: byRow[i] })
    }
    for (var j = base; j < base + t.inserted; j++)
      if (!t.deleted[j]) changes.push({ op: "insert", values: byRow[j] || {} })
    return changes
  }

  function saveTable() {
    var t = tab
    if (!tabIsTable) return
    var changes = buildChanges(t)
    if (!changes.length) return
    updateTab(t.uid, { loading: true, error: "" })
    backend.request("apply_changes", { connId: t.connId, path: t.path, changes: changes }, function(ok, res, msg) {
      if (ok) {
        toast(tr("saved", changes.length))
        updateTab(t.uid, { edits: {}, deleted: {}, inserted: 0 })
        loadTable(t.uid)
      } else {
        updateTab(t.uid, { loading: false, error: msg.error })
        toast(msg.error, true)
      }
    })
  }

  function filterHint() {
    var c = tabConn
    if (c && c.type === "mongodb") return tr("filterMongo")
    if (c && c.type === "redis") return tr("filterRedis")
    return tr("filterSql")
  }

  // ---- export -------------------------------------------------------------
  function currentGridResult() {
    return tabIsTable ? tabData : tabResult
  }

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
    var res = currentGridResult()
    if (!res) return
    var stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19)
    var path = Quickshell.env("HOME") + "/Downloads/dbclient-" + stamp + ".csv"
    backend.request("write_file", { path: path, content: toCsv(res) }, function(ok, res2, msg) {
      toast(ok ? tr("exported", res2) : msg.error, !ok)
    })
  }

  function showCell(row, col) {
    var r = currentGridResult()
    if (!r || row >= r.rows.length) return
    var v = grid.valueAt(row, col)
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
      root.toast(root.tr("backendCrashed", reason), true)
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
    Shortcut { sequence: "Ctrl+S"; enabled: root.tabIsTable; onActivated: root.saveTable() }
    Shortcut { sequence: "Ctrl+I"; enabled: root.tabIsTable; onActivated: root.addRow() }
    Shortcut { sequence: "Ctrl+T"; onActivated: root.newTab("", "", "") }
    Shortcut { sequence: "Ctrl+W"; onActivated: if (root.currentTab >= 0) root.closeTab(root.currentTab) }
    Shortcut { sequence: "Ctrl+N"; onActivated: connDialog.openNew() }
    Shortcut { sequence: "Ctrl+Tab"; onActivated: root.selectTab((root.currentTab + 1) % root.tabs.length) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: root.selectTab((root.currentTab - 1 + root.tabs.length) % root.tabs.length) }
    Shortcut {
      sequence: "Escape"
      onActivated: {
        if (grid.editRow >= 0) grid.cancelEdit()
        else if (contextMenu.opened) contextMenu.close()
        else if (cellDialog.opened) cellDialog.opened = false
        else if (askDialog.opened) askDialog.opened = false
        else if (driverDialog.opened && !driverDialog.busy) driverDialog.close()
        else if (connDialog.opened) connDialog.close()
      }
    }
    Shortcut {
      sequences: [StandardKey.Copy]
      enabled: grid.activeFocus && grid.selRow >= 0 && grid.editRow < 0
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
            readonly property bool hovered: rowMouse.containsMouse || actions.hovering
            readonly property var quickOps: r.isConn ? [] : r.ops.filter(function(o) { return o === "data" || o === "ddl" || o === "create" })
            width: tree.width
            height: r.isConn ? 32 : 26
            color: root.selectedKey === r.key ? Util.alpha(root.accent, 0.14)
              : (hovered ? Util.alpha(root.fg, 0.05) : "transparent")

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
              onClicked: function(m) {
                var row = rowDelegate.r
                if (row.placeholder) return
                if (m.button === Qt.RightButton) {
                  root.selectedKey = row.key
                  var p = rowMouse.mapToItem(contextMenu, m.x, m.y)
                  contextMenu.popup(root.rowMenu(row), p.x, p.y)
                  return
                }
                if (m.button === Qt.MiddleButton) { root.activateRow(row); return }
                root.toggleNode(row.connId, row.path, row.leaf)
              }
              onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) root.activateRow(rowDelegate.r) }
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
                  : (rowDelegate.r.kind === "error" ? root.urgent
                     : (rowDelegate.r.kind === "folder" ? root.accent : root.muted))
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
                font.bold: rowDelegate.r.isConn === true || rowDelegate.r.kind === "folder"
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

            // Hover actions; everything else is in the right-click menu.
            Row {
              id: actions
              readonly property bool hovering: hoverWatch.hovered
              anchors.right: parent.right
              anchors.rightMargin: 4
              anchors.verticalCenter: parent.verticalCenter
              visible: rowDelegate.hovered && !rowDelegate.r.placeholder
              spacing: 0

              HoverHandler { id: hoverWatch }

              Repeater {
                model: rowDelegate.quickOps
                delegate: Button {
                  required property string modelData
                  iconText: root.opIcon(modelData)
                  tooltipText: root.opLabel(rowDelegate.r, modelData)
                  horizontalPadding: 5; verticalPadding: 2
                  onClicked: root.runOp(rowDelegate.r, modelData)
                }
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
                iconText: I18n.glyph.more
                tooltipText: "…"
                horizontalPadding: 5; verticalPadding: 2
                onClicked: {
                  root.selectedKey = rowDelegate.r.key
                  var p = mapToItem(contextMenu, 0, height)
                  contextMenu.popup(root.rowMenu(rowDelegate.r), p.x, p.y)
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
              readonly property bool dirty: modelData.kind === "table" && root.buildChanges(modelData).length > 0
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
                  text: tabItem.modelData.kind === "table" ? I18n.glyph.table
                    : (tabItem.conn ? I18n.types[tabItem.conn.type].icon : "")
                  color: tabItem.conn ? I18n.types[tabItem.conn.type].color : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, 150)
                  text: (tabItem.dirty ? "● " : "") + tabItem.modelData.title
                  color: tabItem.current ? root.fg : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSize
                  elide: Text.ElideRight
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: tabItem.modelData.running || tabItem.modelData.loading ? "…" : I18n.glyph.close
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

        // Query toolbar
        Row {
          id: queryToolbar
          visible: !root.tabIsTable
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
            iconSpinning: root.tab ? root.tab.running === true : false
            tooltipText: root.tr("runHint")
            bordered: true
            selected: true
            enabled: root.tab ? !root.tab.running : false
            onClicked: root.runQuery()
          }
        }

        // Table toolbar
        Row {
          id: tableToolbar
          visible: root.tabIsTable
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: tabStrip.bottom
          anchors.margins: 8
          height: Style.spacing.controlHeight
          spacing: Style.spacing.sm

          readonly property bool canEdit: root.tabData !== null && root.tabData.editable === true

          TextField {
            id: filterField
            width: Math.max(160, tableToolbar.width - editButtons.width - pager.width - 3 * Style.spacing.sm - 40)
            text: root.tabIsTable ? root.tab.where : ""
            placeholderText: root.filterHint()
            onAccepted: root.reloadTable({ where: text, offset: 0 })
          }

          Button {
            iconText: I18n.glyph.refresh
            iconSpinning: root.tabIsTable && root.tab.loading === true
            tooltipText: root.tr("reload")
            onClicked: root.reloadTable({ where: filterField.text })
          }

          Row {
            id: editButtons
            spacing: 2
            visible: tableToolbar.canEdit

            Rectangle { width: 1; height: parent.height; color: root.line }
            Button { iconText: I18n.glyph.add; tooltipText: root.tr("addRow"); onClicked: root.addRow() }
            Button { iconText: I18n.glyph.remove; tooltipText: root.tr("deleteRows"); onClicked: root.toggleDeleteRows() }
            Button { text: "NULL"; fontSize: Style.font.caption; tooltipText: root.tr("setNull"); onClicked: root.setNull() }
            Rectangle { width: 1; height: parent.height; color: root.line }
            Button {
              text: root.tr("saveChanges") + (root.pendingCount ? " (" + root.pendingCount + ")" : "")
              iconText: I18n.glyph.save
              tooltipText: root.tr("saveHint")
              bordered: true
              selected: root.pendingCount > 0
              enabled: root.pendingCount > 0
              onClicked: root.saveTable()
            }
            Button {
              iconText: I18n.glyph.discard
              tooltipText: root.tr("discard")
              enabled: root.pendingCount > 0
              onClicked: root.discardChanges()
            }
          }

          Row {
            id: pager
            spacing: 2
            Rectangle { width: 1; height: parent.height; color: root.line }
            Button {
              iconText: I18n.glyph.chevronLeft
              tooltipText: root.tr("prevPage")
              enabled: root.tabIsTable && root.tab.offset > 0
              onClicked: root.reloadTable({ offset: Math.max(0, root.tab.offset - root.pageSize()) })
            }
            TextField {
              id: pageField
              width: 64
              text: "200"
              validator: IntValidator { bottom: 1; top: 10000 }
              onAccepted: root.reloadTable({ offset: 0 })
            }
            Button {
              iconText: I18n.glyph.chevronRight
              tooltipText: root.tr("nextPage")
              enabled: root.tabData !== null && root.tabData.hasMore === true
              onClicked: root.reloadTable({ offset: root.tab.offset + root.pageSize() })
            }
          }
        }

        // Editor + results, vertically resizable
        SplitView {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: queryToolbar.bottom
          anchors.bottom: statusBar.top
          anchors.topMargin: 8
          orientation: Qt.Vertical

          handle: Rectangle {
            implicitHeight: 1
            color: SplitHandle.hovered || SplitHandle.pressed ? root.accent : root.line
          }

          ScrollView {
            id: editorScroll
            visible: !root.tabIsTable
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
              visible: !root.tabIsTable && root.tab !== null && root.tab.results.length > 1
              spacing: 2
              Repeater {
                model: root.tab && !root.tabIsTable ? root.tab.results.length : 0
                delegate: Button {
                  required property int index
                  text: root.tr("result", index + 1)
                  fontSize: Style.font.bodySmall
                  selected: root.tab && root.tab.resultIndex === index
                  onClicked: root.updateTab(root.tab.uid, { resultIndex: index })
                }
              }
            }

            // Read-only / error banner for table tabs
            Rectangle {
              id: tableBanner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: visible ? bannerText.implicitHeight + 12 : 0
              visible: root.tabIsTable && (root.tab.error !== "" || (root.tabData !== null && !root.tabData.editable))
              color: Util.alpha(root.tab && root.tab.error ? root.urgent : root.fg, 0.08)
              Text {
                id: bannerText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: root.tab && root.tab.error ? root.urgent : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                text: !root.tabIsTable ? "" : (root.tab.error ? I18n.glyph.warning + "  " + root.tab.error
                  : (root.tabData ? root.tr("readOnly", root.tabData.readonlyReason) : ""))
              }
            }

            ResultGrid {
              id: grid
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: root.tabIsTable ? tableBanner.bottom : resultTabs.bottom
              anchors.bottom: parent.bottom
              anchors.topMargin: resultTabs.visible ? 6 : 0
              visible: root.tabIsTable ? root.tabData !== null
                : (root.tabResult !== null && root.tabResult.columns.length > 0 && !(root.tab && root.tab.error))
              editable: root.tabIsTable && root.tabData !== null && root.tabData.editable === true
              colEditable: root.tabData ? root.tabData.colEditable : []
              baseCount: root.tabData ? root.tabData.rows.length : -1
              edits: root.tabIsTable ? root.tab.edits : ({})
              deleted: root.tabIsTable ? root.tab.deleted : ({})
              foreground: root.fg
              accent: root.accent
              muted: root.muted
              urgent: root.urgent
              fontFamily: root.fontFamily
              fontSize: root.fontSize
              onCellActivated: function(r, c) { root.showCell(r, c) }
              onCellEdited: function(r, c, value) { root.setCell(r, c, value) }
              onDeleteRequested: root.toggleDeleteRows()
              onHeaderClicked: function(c) {
                if (root.tabIsTable) root.sortTable(c)
                else grid.sortLocal(c)
              }
            }

            // Message / error / empty state
            Text {
              anchors.fill: parent
              anchors.margins: 16
              visible: !grid.visible && !(root.tabIsTable && root.tab.error)
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              verticalAlignment: root.tab && root.tab.error ? Text.AlignTop : Text.AlignVCenter
              horizontalAlignment: root.tab && root.tab.error ? Text.AlignLeft : Text.AlignHCenter
              color: root.tab && root.tab.error ? root.urgent : root.muted
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
              text: {
                if (!root.tab) return ""
                if (root.tabIsTable) return root.tab.loading ? root.tr("loading") : ""
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
            id: statusText
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            color: root.pendingCount ? root.accent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: {
              if (!root.tab) return ""
              if (root.tabIsTable) {
                var d = root.tabData
                if (!d) return root.tab.loading ? root.tr("loading") : ""
                var s = root.tr("rowsRange", d.rowCount ? d.offset + 1 : 0, d.offset + d.rowCount)
                if (d.message) s += " · " + d.message
                s += " · " + root.tab.elapsedMs + " ms"
                if (root.pendingCount) s += " · " + root.tr("pending", root.pendingCount)
                return s
              }
              var r = root.tabResult
              if (!r || root.tab.error) return root.tab.running ? root.tr("running") : ""
              var t = r.columns.length ? (r.rowCount === 1 ? root.tr("row") : root.tr("rows", r.rowCount)) : r.message
              if (r.truncated) t += " (" + root.tr("truncated", r.rowCount) + ")"
              return t + " · " + root.tab.elapsedMs + " ms"
            }
          }

          Text {
            anchors.left: statusText.right
            anchors.leftMargin: 24
            anchors.right: exportRow.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            visible: root.toastText !== ""
            text: root.toastText
            horizontalAlignment: Text.AlignHCenter
            color: root.toastError ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            id: exportRow
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: grid.visible
            spacing: 2

            Button {
              text: root.tr("copyCsv")
              iconText: I18n.glyph.copy
              fontSize: Style.font.bodySmall
              onClicked: root.copyText(root.toCsv(root.currentGridResult()))
            }
            Button {
              text: root.tr("copyJson")
              iconText: I18n.glyph.copy
              fontSize: Style.font.bodySmall
              onClicked: root.copyText(root.toJson(root.currentGridResult()))
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
    TreeMenu {
      id: contextMenu
      anchors.fill: parent
    }

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

    // Confirmation with the exact statement that will run
    Rectangle {
      id: askDialog
      property bool opened: false
      property string title: ""
      property string message: ""
      property string sql: ""
      property string confirmText: ""
      property bool danger: false
      property var onYes: null
      anchors.fill: parent
      visible: opened
      color: Util.alpha(root.bg, 0.7)

      MouseArea { anchors.fill: parent; onClicked: askDialog.opened = false }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(parent.width - 60, 620)
        height: askColumn.implicitHeight + 36
        color: Color.popups.background
        borderSpec: Border.flat(askDialog.danger ? root.urgent : Color.popups.border, Style.normalBorderWidth)
        radius: Style.cornerRadius

        MouseArea { anchors.fill: parent }

        Column {
          id: askColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 18
          spacing: Style.spacing.lg

          Text {
            text: (askDialog.danger ? I18n.glyph.warning + "  " : "") + askDialog.title
            color: askDialog.danger ? root.urgent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            visible: askDialog.message !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: askDialog.message
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Rectangle {
            visible: askDialog.sql !== ""
            width: parent.width
            height: Math.min(220, sqlText.implicitHeight + 16)
            radius: Style.cornerRadius
            color: Util.alpha(root.fg, 0.05)
            clip: true
            Text {
              id: sqlText
              anchors.fill: parent
              anchors.margins: 8
              text: askDialog.sql
              wrapMode: Text.WrapAnywhere
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
            }
          }
          Row {
            anchors.right: parent.right
            spacing: Style.spacing.lg
            Button {
              text: root.tr("cancel")
              bordered: true
              onClicked: askDialog.opened = false
            }
            Button {
              text: askDialog.confirmText
              bordered: true
              selected: true
              foreground: askDialog.danger ? root.urgent : root.fg
              onClicked: {
                var f = askDialog.onYes
                askDialog.opened = false
                if (typeof f === "function") f()
              }
            }
          }
        }
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

  Component.onDestruction: backend.stop()
}
