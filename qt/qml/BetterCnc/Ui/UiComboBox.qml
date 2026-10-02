pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic

ComboBox {
    id: control
    implicitWidth: 150
    implicitHeight: 32
    leftPadding: 8
    rightPadding: 23
    font.family: Theme.fontFamily
    font.pixelSize: 12
    hoverEnabled: true
    contentItem: UiText {
        text: control.displayText
        font: control.font
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    indicator: UiIcon {
        name: "chevron"
        rotation: 90
        width: 12
        height: 12
        x: control.width - width - 7
        y: (control.height - height) / 2
    }
    background: Rectangle {
        radius: 6
        color: Theme.input
        border.color: control.visualFocus ? Theme.accent : Theme.borderControl
        border.width: control.visualFocus ? 2 : 1
    }
    delegate: ItemDelegate {
        id: itemDelegate
        required property int index
        required property var modelData
        width: control.width
        height: 30
        highlighted: control.highlightedIndex === index
        contentItem: UiText {
            text: control.textRole ? itemDelegate.modelData[control.textRole] : itemDelegate.modelData
            font: control.font
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle { color: itemDelegate.highlighted ? Theme.accentSoft : "transparent"; radius: 4 }
    }
    popup: Popup {
        enter: Transition { }
        exit: Transition { }
        y: control.height + 3
        width: control.width
        padding: 5
        implicitHeight: Math.min(contentItem.implicitHeight + 10, 300)
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollBar.vertical: UiScrollBar { }
        }
        background: Rectangle { color: "#202125"; radius: 6; border.color: Theme.borderControl }
    }
}
