import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar icon for the DB client. The window itself is the plugin's panel entry
// (Panel.qml), owned by the shell's panel loader, so every monitor's bar
// toggles the same single window.
BarWidget {
  id: root
  moduleName: "momoledev.dbclient"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""  // nf-fa-database
    slotSize: Style.bar.statusSlot
    tooltipText: "DB Client"

    onPressed: function(b) {
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "momoledev.dbclient", "{}"])
    }
  }
}
