import QtQuick
import QtQuick.Controls.Basic

CheckBox {
    id: control
    property bool interactive: true
    implicitHeight: 27
    implicitWidth: implicitContentWidth + 21
    padding: 0
    spacing: 7
    font.family: Theme.fontFamily
    font.pixelSize: 11
    hoverEnabled: true
    nextCheckState: function() { return interactive ? (checked ? Qt.Unchecked : Qt.Checked) : checkState; }
    indicator: Rectangle {
        x: 0
        y: (control.height - height) / 2
        width: 14
        height: 14
        radius: 3
        color: control.checked ? Theme.accentFill : Theme.input
        border.color: control.visualFocus ? Theme.accent : control.checked ? Theme.accent : "#5b5d68"
        border.width: control.visualFocus ? 2 : 1
        UiText {
            anchors.centerIn: parent
            text: control.checked ? "✓" : ""
            font.pixelSize: 12
        }
    }
    contentItem: UiText {
        text: control.text
        font: control.font
        color: Theme.secondary
        leftPadding: 21
        verticalAlignment: Text.AlignVCenter
    }
}
