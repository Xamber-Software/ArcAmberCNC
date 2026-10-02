pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import BetterCnc.Ui 1.0
import BetterCnc.Catalog 1.0
import BetterCnc.Toolpath 1.0

Item {
    id: root
    required property ChromeActions actions
    required property ToolpathState preview
    property bool compact: width <= 900
    readonly property bool menuOpen: {
        for (let index = 0; index < menubar.count; index++) {
            if (menubar.menuAt(index).visible) return true;
        }
        return false;
    }
    implicitHeight: 146
    objectName: "workspace-chrome"
    readonly property var icons: ({
        "machine.estop": "octagon", "machine.power": "power", "file.open": "folder",
        "file.reload": "refresh", "program.run": "play", "program.step": "step",
        "program.pause": "pause", "program.stop": "stop", "program.block-delete": "skip",
        "program.optional": "circle", "view.zoom-in": "zoom-in", "view.zoom-out": "zoom-out",
        "view.z": "top", "view.z2": "diamond", "view.x": "side", "view.y": "front",
        "view.p": "cube", "view.rotate": "orbit", "view.clear": "eraser"
    })

    Rectangle {
        id: header
        width: parent.width
        height: 52
        color: Theme.sidebar
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        Item {
            id: brand
            width: root.compact ? 264 : 296
            height: parent.height
            UiText {
                x: 18
                anchors.verticalCenter: parent.verticalCenter
                text: "BetterLinuxCNC"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.letterSpacing: -0.3
            }
            UiText {
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: "工作空间"
                font.pixelSize: 10
                color: Theme.muted
                visible: !root.compact
            }
        }
        Row {
            x: brand.width + (root.compact ? 14 : 20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9
            UiText { text: "机床"; font.pixelSize: 12; color: Theme.muted }
            UiIcon { name: "chevron"; width: 12; height: 12; anchors.verticalCenter: parent.verticalCenter; color: Theme.muted }
            UiText { text: "操作台"; font.pixelSize: 12; font.weight: Font.Medium }
        }
        MenuBar {
            id: menubar
            objectName: "main-menubar"
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            padding: 0
            background: Item { }
            delegate: MenuBarItem {
                id: trigger
                objectName: "menubar-" + text
                implicitHeight: 28
                implicitWidth: contentItem.implicitWidth + 20
                padding: 0
                contentItem: UiText {
                    text: trigger.text
                    font.pixelSize: 12
                    color: trigger.highlighted || trigger.hovered ? Theme.text : Theme.secondary
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 5
                    color: trigger.highlighted || trigger.hovered ? Theme.hover : "transparent"
                }
            }
            Instantiator {
                model: root.actions.menus
                delegate: MenuEntries {
                    required property var modelData
                    title: modelData.label
                    entries: modelData.children
                    actions: root.actions
                    objectName: "menu-" + modelData.id
                }
                onObjectAdded: function(index, object) { menubar.insertMenu(index, object); }
                onObjectRemoved: function(index, object) { menubar.removeMenu(object); }
            }
        }
    }
    Item {
        id: context
        y: 52
        width: parent.width
        height: 44
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        Row {
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            UiText { text: root.actions.machine.axes && root.actions.machine.axes.length ? (root.actions.machine.axes.length === 3 ? "三轴加工" : root.actions.machine.axes.length + " 轴加工") : "机床操作"; font.pixelSize: 12; font.weight: Font.Medium }
            Item {
                width: 14
                height: 18
                UiText { anchors.centerIn: parent; text: "/"; font.pixelSize: 12; color: "#555761" }
            }
            Row {
                spacing: 10
                UiIcon { name: "file"; width: 14; height: 18; color: Theme.secondary }
                UiText {
                    text: root.actions.program && root.actions.program.fileName ? root.actions.program.fileName : "未打开程序"
                    font.family: Theme.mono
                    font.pixelSize: 11
                    color: Theme.secondary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
    Item {
        y: 96
        width: parent.width
        height: 50
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        Flickable {
            id: toolbarViewport
            objectName: "toolbar-viewport"
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            contentWidth: toolbarRow.width
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            function ensureVisible(item: Item): void {
                const left = item.mapToItem(toolbarRow, 0, 0).x;
                const right = left + item.width;
                const target = left < contentX ? left
                             : right > contentX + width ? right - width : contentX;
                contentX = Math.max(0, Math.min(contentWidth - width, target));
            }
            Row {
                id: toolbarRow
                y: 9.5
                height: 30
                spacing: 4
                Repeater {
                    model: Catalog.toolbar
                    delegate: Row {
                        id: toolbarEntry
                        required property var modelData
                        spacing: 4
                        height: 30
                        Item {
                            visible: !!toolbarEntry.modelData.separator
                            width: visible ? 11 : 0
                            height: 30
                            Rectangle { anchors.centerIn: parent; width: 1; height: 18; color: Theme.borderControl }
                        }
                        UiButton {
                            id: toolbarButton
                            objectName: "toolbar-" + toolbarEntry.modelData.id
                            width: toolbarEntry.modelData.id === "machine.estop" ? 69.5 : toolbarEntry.modelData.id === "program.run" ? 71.5 : 30
                            height: 30
                            kind: toolbarEntry.modelData.id === "machine.estop" ? "danger" : toolbarEntry.modelData.id === "program.run" ? "primary" : "toolbar"
                            iconName: root.icons[toolbarEntry.modelData.id] || "cube"
                            text: toolbarEntry.modelData.id === "machine.estop" ? "急停" : toolbarEntry.modelData.id === "program.run" ? "运行" : ""
                            font.pixelSize: 11
                            selected: toolbarEntry.modelData.id === "view." + root.preview.choices.view
                                      || (toolbarEntry.modelData.id === "view.rotate" && root.preview.rotate)
                                      || (toolbarEntry.modelData.id === "machine.power" && !!root.actions.machine.powered)
                                      || (toolbarEntry.modelData.id === "program.optional" && !!root.actions.machine.optionalStop)
                                      || (toolbarEntry.modelData.id === "program.block-delete" && !!root.actions.machine.blockDelete)
                            enabled: root.actions.canActivate(toolbarEntry.modelData.id)
                            tooltip: toolbarEntry.modelData.label
                            onActiveFocusChanged: {
                                if (activeFocus) toolbarViewport.ensureVisible(toolbarButton);
                            }
                            onClicked: root.actions.activate(toolbarEntry.modelData.id, toolbarEntry.modelData.label)
                        }
                    }
                }
            }
        }
    }
}
