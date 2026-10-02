import QtQuick
import QtQuick.Controls.Basic

TextField {
    id: control
    implicitWidth: 130
    implicitHeight: 32
    padding: 8
    topPadding: 4
    bottomPadding: 4
    color: Theme.text
    selectionColor: Theme.accentSoft
    selectedTextColor: Theme.text
    placeholderTextColor: Theme.muted
    font.family: Theme.fontFamily
    font.pixelSize: 13
    renderType: Text.NativeRendering
    background: Rectangle {
        radius: 6
        color: Theme.input
        border.color: control.activeFocus ? Theme.accent : Theme.borderControl
        border.width: control.activeFocus ? 2 : 1
    }
}
