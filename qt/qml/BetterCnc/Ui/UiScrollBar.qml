import QtQuick
import QtQuick.Controls.Basic

ScrollBar {
    id: control
    padding: 0
    minimumSize: 0.03
    implicitWidth: 7
    implicitHeight: 7
    hoverEnabled: true
    contentItem: Rectangle {
        implicitWidth: 7
        implicitHeight: 7
        radius: 4
        color: control.pressed ? "#555762" : "#3b3d45"
        opacity: control.size < 1 && (control.active || control.hovered || control.pressed) ? 1 : 0
    }
    background: Item { }
}
