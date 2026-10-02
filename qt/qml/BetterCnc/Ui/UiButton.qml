import QtQuick
import QtQuick.Controls.Basic

Button {
    id: control
    property string iconName: ""
    property bool selected: false
    property string kind: "normal"
    property string tooltip: ""
    readonly property color foreground: !enabled ? Theme.muted
        : kind === "danger" ? Theme.danger
        : selected ? (kind === "tab" ? Theme.text : "#c5bfff")
        : kind === "tab" && !selected || kind === "toolbar" && !hovered ? Theme.secondary : Theme.text
    implicitWidth: Math.max(30, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: 30
    padding: 4
    leftPadding: kind === "toolbar" ? 5 : 10
    rightPadding: leftPadding
    spacing: 7
    font.family: Theme.fontFamily
    font.pixelSize: 12
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : 0.55
    contentItem: Item {
        implicitWidth: contentRow.implicitWidth
        implicitHeight: contentRow.implicitHeight
        Row {
            id: contentRow
            spacing: control.iconName && control.text ? control.spacing : 0
            anchors.centerIn: parent
            UiIcon {
                visible: control.iconName !== ""
                name: control.iconName
                color: control.foreground
                anchors.verticalCenter: parent.verticalCenter
            }
            UiText {
                visible: control.text !== ""
                text: control.text
                color: control.foreground
                font: control.font
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
    background: Rectangle {
        radius: 6
        color: control.kind === "danger" ? Theme.dangerSoft
            : control.kind === "primary" ? (control.hovered ? "#7b73e6" : Theme.accentFill)
            : control.selected || control.down ? (control.kind === "tab" ? Theme.hover : Theme.accentSoft)
            : control.hovered ? Theme.hover
            : control.kind === "toolbar" || control.kind === "tab" ? "transparent" : Theme.raised
        border.width: 1
        border.color: control.kind === "danger" ? "#583137"
            : control.kind === "primary" ? "#7971e9"
            : control.selected || control.down ? (control.kind === "tab" ? Theme.border : "#514a75")
            : control.kind === "toolbar" || control.kind === "tab" ? "transparent"
            : control.hovered ? "#52545f" : Theme.borderControl
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            visible: control.visualFocus
            color: "transparent"
            border.color: Theme.accent
            border.width: 2
            radius: 8
        }
    }
    ToolTip.visible: hovered && tooltip.length > 0
    ToolTip.text: tooltip
    ToolTip.delay: 600
    Accessible.name: tooltip || text
}
