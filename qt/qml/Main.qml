import QtQuick
import QtQuick.Controls.Basic
import BetterCnc.Ui 1.0

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    property var backend: null
    width: 1100
    height: 820
    minimumWidth: 760
    minimumHeight: 640
    visible: true
    title: (backend && backend.program && backend.program.fileName ? backend.program.fileName + " — " : "") + "BetterLinuxCNC"
    color: Theme.base
    font.family: Theme.fontFamily
    font.pixelSize: 13
    onActiveChanged: if (!active) workspace.stopJog()
    onClosing: workspace.stopJog()
    onActiveFocusItemChanged: workspace.stopJog()
    Workspace {
        id: workspace
        backend: window.backend
        onQuitRequested: window.close()
        anchors.fill: parent
        focusedItem: window.activeFocusItem
    }
}
