import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// Add / edit a saved connection. Fields adapt to the engine; when the engine's
// driver is missing a warning banner offers to install it before testing.
Rectangle {
  id: dlg

  property var panel: null
  property bool opened: false
  property var form: ({})
  property string testState: ""   // "" | "testing" | "ok" | "error"
  property string testMessage: ""

  readonly property string type: form.type || "postgresql"
  readonly property var driver: panel && panel.drivers ? panel.drivers[type] : null
  readonly property bool driverMissing: driver ? driver.installed !== true : false

  signal saved(var connection)

  function tr(k, a, b) { return panel ? panel.tr(k, a, b) : k }

  function openNew() {
    form = { type: "postgresql", name: "", host: "127.0.0.1", port: "5432", user: "", password: "",
             database: "", ssl: false }
    testState = ""
    opened = true
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function openEdit(conn) {
    var f = JSON.parse(JSON.stringify(conn))
    delete f.connected
    f.port = f.port !== undefined ? String(f.port) : ""
    form = f
    testState = ""
    opened = true
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function close() { opened = false }

  function set(key, value) {
    var f = Object.assign({}, form)
    f[key] = value
    form = f
  }

  function setType(t) {
    var f = Object.assign({}, form)
    var oldDefault = panel.drivers[f.type] ? String(panel.drivers[f.type].port) : ""
    f.type = t
    if (!f.port || f.port === oldDefault) f.port = panel.drivers[t] ? String(panel.drivers[t].port) : ""
    form = f
    testState = ""
  }

  function payload() {
    var f = Object.assign({}, form)
    f.name = (f.name || "").trim() || defaultName()
    f.port = f.port ? parseInt(f.port, 10) : undefined
    return f
  }

  function defaultName() {
    if (type === "sqlite") return String(form.file || "SQLite").split("/").pop()
    var label = driver ? driver.label.split(" ")[0] : type
    return label + " " + (form.host || "localhost")
  }

  function test() {
    testState = "testing"
    testMessage = ""
    panel.backend.request("test_connection", { connection: payload() }, function(ok, res, msg) {
      if (ok) {
        testState = "ok"
        testMessage = tr("testOk", res.elapsedMs, res.objects)
      } else {
        testState = "error"
        testMessage = msg.error
        if (msg.code === "driver_missing") panel.promptDriver(msg.type, null)
      }
    })
  }

  function save() {
    panel.backend.request("save_connection", { connection: payload() }, function(ok, res, msg) {
      if (!ok) {
        testState = "error"
        testMessage = msg.error
        return
      }
      opened = false
      dlg.saved(res)
    })
  }

  visible: opened
  color: Util.alpha(Color.background, 0.7)

  MouseArea { anchors.fill: parent; onClicked: dlg.close() }

  Keys.onEscapePressed: dlg.close()

  Process {
    id: browseProc
    command: ["omarchy", "file", "select", "--title", "SQLite database", "--extensions", "db sqlite sqlite3 db3 s3db"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim().split("\n")[0]
        if (path) dlg.set("file", path)
      }
    }
  }

  component FieldLabel: Text {
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    width: 130
    height: Style.spacing.controlHeight
    verticalAlignment: Text.AlignVCenter
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - 40, 620)
    height: Math.min(parent.height - 40, content.implicitHeight + 40)
    color: Color.popups.background
    borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    MouseArea { anchors.fill: parent }

    Flickable {
      anchors.fill: parent
      anchors.margins: 20
      contentHeight: content.implicitHeight
      clip: true

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.lg

        Text {
          text: dlg.form.id ? dlg.tr("editConnection") : dlg.tr("newConnection")
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        // Engine picker
        Flow {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: I18n.typeOrder

            delegate: Button {
              required property string modelData
              text: dlg.panel && dlg.panel.drivers[modelData] ? dlg.panel.drivers[modelData].label : modelData
              iconText: I18n.types[modelData].icon
              selected: dlg.type === modelData
              bordered: true
              fontSize: Style.font.bodySmall
              onClicked: dlg.setType(modelData)
            }
          }
        }

        // Missing driver banner
        Rectangle {
          visible: dlg.driverMissing
          width: parent.width
          height: bannerCol.implicitHeight + 20
          radius: Style.cornerRadius
          color: Util.alpha(Color.urgent, 0.12)
          border.color: Util.alpha(Color.urgent, 0.5)
          border.width: 1

          Column {
            id: bannerCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 10
            spacing: Style.spacing.md

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: I18n.glyph.warning + "  " + (dlg.driver ? dlg.tr("driverMissing", dlg.driver.label, dlg.driver.pip) : "")
            }

            Button {
              text: dlg.tr("install") + "…"
              bordered: true
              onClicked: dlg.panel.promptDriver(dlg.type, null)
            }
          }
        }

        // Fields
        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Row {
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("name") }
            TextField {
              id: nameField
              width: content.width - 140
              text: dlg.form.name || ""
              placeholderText: dlg.defaultName()
              onTextEdited: dlg.set("name", text)
              onAccepted: dlg.save()
            }
          }

          Row {
            visible: dlg.type === "sqlite"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("file") }
            TextField {
              width: content.width - 140 - browseBtn.width - Style.spacing.lg
              text: dlg.form.file || ""
              placeholderText: "~/data/app.db"
              onTextEdited: dlg.set("file", text)
            }
            Button {
              id: browseBtn
              text: dlg.tr("browse")
              bordered: true
              onClicked: browseProc.running = true
            }
          }

          Row {
            visible: dlg.type !== "sqlite"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("host") }
            TextField {
              width: content.width - 140 - 110 - Style.spacing.lg
              text: dlg.form.host || ""
              placeholderText: "127.0.0.1"
              onTextEdited: dlg.set("host", text)
            }
            TextField {
              width: 110
              text: dlg.form.port || ""
              placeholderText: dlg.tr("port")
              validator: IntValidator { bottom: 1; top: 65535 }
              onTextEdited: dlg.set("port", text)
            }
          }

          Row {
            visible: dlg.type !== "sqlite"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("user") }
            TextField {
              width: content.width - 140
              text: dlg.form.user || ""
              placeholderText: ({ postgresql: "postgres", mysql: "root", clickhouse: "default", oracle: "system" })[dlg.type] || ""
              onTextEdited: dlg.set("user", text)
            }
          }

          Row {
            visible: dlg.type !== "sqlite"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("password") }
            TextField {
              width: content.width - 140
              password: true
              text: dlg.form.password || ""
              onTextEdited: dlg.set("password", text)
              onAccepted: dlg.save()
            }
          }

          Row {
            visible: dlg.type !== "sqlite"
            spacing: Style.spacing.lg
            FieldLabel {
              text: dlg.type === "oracle" ? dlg.tr("serviceName")
                : (dlg.type === "redis" ? dlg.tr("dbIndex") : dlg.tr("database"))
            }
            TextField {
              width: content.width - 140
              text: dlg.form.database || ""
              placeholderText: ({ oracle: "FREEPDB1", redis: "0", postgresql: "postgres", mongodb: "test" })[dlg.type] || ""
              onTextEdited: dlg.set("database", text)
            }
          }

          Row {
            visible: dlg.type === "mongodb"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("authSource") }
            TextField {
              width: content.width - 140
              text: dlg.form.authSource || ""
              placeholderText: "admin"
              onTextEdited: dlg.set("authSource", text)
            }
          }

          Row {
            visible: dlg.type === "mongodb" || dlg.type === "redis"
            spacing: Style.spacing.lg
            FieldLabel { text: "URI" }
            TextField {
              width: content.width - 140
              text: dlg.form.uri || ""
              placeholderText: dlg.type === "redis" ? "redis://user:pass@host:6379/0" : "mongodb+srv://user:pass@cluster/db"
              onTextEdited: dlg.set("uri", text)
            }
          }

          Row {
            visible: dlg.type !== "sqlite"
            spacing: Style.spacing.lg
            FieldLabel { text: dlg.tr("ssl") }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: dlg.form.ssl === true
              onToggled: dlg.set("ssl", !(dlg.form.ssl === true))
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: dlg.type !== "sqlite"
          text: dlg.tr("passwordNote")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: dlg.testState !== ""
          wrapMode: Text.WordWrap
          text: dlg.testState === "testing" ? dlg.tr("testing")
            : (dlg.testState === "ok" ? I18n.glyph.check + "  " + dlg.testMessage : I18n.glyph.warning + "  " + dlg.testMessage)
          color: dlg.testState === "error" ? Color.urgent : (dlg.testState === "ok" ? Color.accent : Color.muted)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Row {
          anchors.right: parent.right
          spacing: Style.spacing.lg

          Button {
            text: dlg.tr("test")
            iconText: I18n.glyph.plug
            bordered: true
            onClicked: dlg.test()
          }
          Button {
            text: dlg.tr("cancel")
            bordered: true
            onClicked: dlg.close()
          }
          Button {
            text: dlg.tr("save")
            iconText: I18n.glyph.check
            bordered: true
            selected: true
            onClicked: dlg.save()
          }
        }
      }
    }
  }
}
