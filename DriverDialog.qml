import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// Driver manager. Two modes:
//   prompt — a specific driver is missing: warn, ask how to install it
//   list   — status of every driver with per-driver install buttons
// Nothing is installed until the user clicks an install button.
Rectangle {
  id: dlg

  property var panel: null
  property bool opened: false
  property string mode: "list"
  property string type: ""
  property var afterInstall: null
  property bool busy: false
  property string busyType: ""
  property bool failed: false
  property int requestId: -1
  property var log: []

  readonly property var drivers: panel ? panel.drivers : ({})
  readonly property var driver: drivers[type] || null

  function tr(k, a, b) { return panel ? panel.tr(k, a, b) : k }

  function prompt(t, then) {
    mode = "prompt"
    type = t
    afterInstall = then || null
    if (!busy) { log = []; failed = false }
    opened = true
  }

  function showList() {
    mode = "list"
    afterInstall = null
    if (!busy) { log = []; failed = false }
    opened = true
  }

  function close() {
    opened = false
  }

  function appendLog(line) {
    var l = log.slice(-300)
    l.push(line)
    log = l
    Qt.callLater(function() { logView.positionViewAtEnd() })
  }

  function install(t, method) {
    if (busy) return
    busy = true
    busyType = t
    failed = false
    log = []
    type = t
    requestId = panel.backend.request("install_driver", { type: t, method: method }, function(ok, res, msg) {
      busy = false
      busyType = ""
      if (ok) {
        panel.drivers = res.drivers
        appendLog(I18n.glyph.check + " " + tr("installDone"))
        var then = afterInstall
        afterInstall = null
        if (mode === "prompt") {
          close()
          if (typeof then === "function") then()
        }
      } else {
        failed = true
        appendLog(tr("installFailed") + ": " + msg.error)
      }
    })
  }

  function onBackendEvent(msg) {
    if (msg.event === "install_log" && msg.id === requestId) appendLog(msg.line)
  }

  visible: opened
  color: Util.alpha(Color.background, 0.7)

  MouseArea { anchors.fill: parent; onClicked: if (!dlg.busy) dlg.close() }

  BorderSurface {
    anchors.centerIn: parent
    width: Math.min(parent.width - 40, 640)
    height: Math.min(parent.height - 40, body.implicitHeight + 40)
    color: Color.popups.background
    borderSpec: Border.flat(dlg.mode === "prompt" ? Color.urgent : Color.popups.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    MouseArea { anchors.fill: parent }

    Column {
      id: body
      anchors.fill: parent
      anchors.margins: 20
      spacing: Style.spacing.lg

      Text {
        text: dlg.mode === "prompt" ? I18n.glyph.warning + "  " + dlg.tr("driverMissingTitle") : dlg.tr("drivers")
        color: dlg.mode === "prompt" ? Color.urgent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      // ---- prompt mode ----------------------------------------------------
      Column {
        visible: dlg.mode === "prompt" && dlg.driver !== null
        width: parent.width
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          text: dlg.driver ? dlg.tr("driverMissing", dlg.driver.label, dlg.driver.pip) + "\n" + dlg.tr("driverInstallQuestion") : ""
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Row {
            visible: dlg.driver && dlg.driver.pacman
            spacing: Style.spacing.lg
            Button {
              width: 220
              text: dlg.tr("installPacman")
              bordered: true
              selected: true
              enabled: !dlg.busy
              onClicked: dlg.install(dlg.type, "pacman")
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: body.width - 220 - Style.spacing.lg
              wrapMode: Text.WordWrap
              text: (dlg.driver && dlg.driver.pacman ? dlg.driver.pacman + " — " : "") + dlg.tr("installPacmanHint")
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            spacing: Style.spacing.lg
            Button {
              width: 220
              text: dlg.tr("installPip")
              bordered: true
              selected: !(dlg.driver && dlg.driver.pacman)
              enabled: !dlg.busy
              onClicked: dlg.install(dlg.type, "pip")
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: body.width - 220 - Style.spacing.lg
              wrapMode: Text.WordWrap
              text: (dlg.driver ? dlg.driver.pip + " — " : "") + dlg.tr("installPipHint", dlg.panel ? dlg.panel.venvPath : "")
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // ---- list mode ------------------------------------------------------
      Column {
        visible: dlg.mode === "list"
        width: parent.width
        spacing: 2

        Repeater {
          model: I18n.typeOrder

          delegate: Rectangle {
            required property string modelData
            readonly property var d: dlg.drivers[modelData] || null
            width: body.width
            height: Style.spacing.controlHeight + 8
            radius: Style.cornerRadius
            color: Util.alpha(Color.foreground, 0.03)

            Text {
              id: icon
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: I18n.types[modelData].icon
              color: I18n.types[modelData].color
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
            }
            Text {
              anchors.left: icon.right
              anchors.leftMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              text: (parent.d ? parent.d.label : modelData) + "   "
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: 220
              anchors.verticalCenter: parent.verticalCenter
              text: parent.d ? (parent.d.builtin ? "sqlite3 (python)" : parent.d.pip) : ""
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              visible: parent.d && parent.d.installed
              text: I18n.glyph.check + " " + (parent.d && parent.d.builtin ? dlg.tr("builtin") : dlg.tr("installed"))
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Button {
              anchors.right: parent.right
              anchors.rightMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              visible: parent.d && !parent.d.installed
              text: dlg.busyType === modelData ? dlg.tr("installing") : dlg.tr("install")
              iconSpinning: dlg.busyType === modelData
              bordered: true
              enabled: !dlg.busy
              onClicked: dlg.prompt(modelData, null)
            }
          }
        }
      }

      // ---- install log ----------------------------------------------------
      Rectangle {
        visible: dlg.log.length > 0
        width: parent.width
        height: 170
        color: Util.alpha(Color.foreground, 0.04)
        radius: Style.cornerRadius

        ListView {
          id: logView
          anchors.fill: parent
          anchors.margins: 8
          clip: true
          model: dlg.log
          ScrollBar.vertical: ScrollBar {}
          delegate: Text {
            required property string modelData
            width: logView.width
            text: modelData
            wrapMode: Text.WrapAnywhere
            color: modelData.indexOf("✓") === 0 || modelData.indexOf(I18n.glyph.check) === 0 ? Color.accent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.spacing.lg

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: dlg.busy
          text: dlg.tr("installing")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        Button {
          text: dlg.mode === "prompt" && !dlg.busy ? dlg.tr("cancel") : dlg.tr("close")
          bordered: true
          onClicked: dlg.close()
        }
      }
    }
  }
}
