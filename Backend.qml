import QtQuick
import Quickshell
import Quickshell.Io

// JSON-lines bridge to backend/dbclient.py. One long-lived Python process
// keeps database sessions open while the shell runs; it is started lazily on
// the first request so an idle shell never spawns it.
Item {
  id: root

  property string script: ""
  readonly property bool running: proc.running
  property int nextId: 1
  property var pending: ({})
  property var queue: []

  signal event(var message)
  signal crashed(string reason)

  function start() {
    if (!proc.running) proc.running = true
  }

  function stop() {
    proc.running = false
  }

  // request("query", {connId, text}, function(ok, result, error) { … })
  function request(cmd, args, callback) {
    var id = nextId++
    var msg = args ? JSON.parse(JSON.stringify(args)) : {}
    msg.id = id
    msg.cmd = cmd
    var p = pending
    p[id] = callback || null
    pending = p
    var line = JSON.stringify(msg) + "\n"
    if (proc.running) proc.write(line)
    else {
      queue.push(line)
      start()
    }
    return id
  }

  function handleLine(line) {
    if (!line) return
    var msg
    try { msg = JSON.parse(line) } catch (e) {
      console.warn("dbclient: bad backend line", line)
      return
    }
    if (msg.event) {
      root.event(msg)
      return
    }
    var cb = pending[msg.id]
    if (msg.id in pending) {
      var p = pending
      delete p[msg.id]
      pending = p
    }
    if (typeof cb === "function") {
      try { cb(msg.ok === true, msg.result, msg) } catch (e) {
        console.warn("dbclient: callback threw", e)
      }
    }
  }

  Process {
    id: proc
    command: ["python3", "-u", root.script]
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleLine(data) }
    }

    stderr: StdioCollector {
      id: stderrCollector
    }

    onStarted: {
      var q = root.queue
      root.queue = []
      for (var i = 0; i < q.length; i++) write(q[i])
    }

    onExited: function(code, status) {
      // Fail every in-flight request so the UI never spins forever.
      var p = root.pending
      root.pending = ({})
      for (var id in p) {
        if (typeof p[id] === "function")
          p[id](false, null, { ok: false, error: "Backend exited (" + code + ")" })
      }
      if (code !== 0) {
        var reason = String(stderrCollector.text || "").trim().split("\n").slice(-3).join("\n")
        root.crashed(reason || ("exit code " + code))
      }
    }
  }
}
