pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import BetterCnc.Ui 1.0

Menu {
    id: root
    required property ChromeActions actions
    property var entries: []
    property var generatedEntries: []
    property bool ready: false
    popupType: Popup.Item
    padding: 5
    overlap: 3
    margins: 4
    modal: false
    cascade: true
    enter: Transition { }
    exit: Transition { }
    font.family: Theme.fontFamily
    font.pixelSize: 12
    implicitWidth: {
        let result = 220;
        for (const entry of entries) {
            const suffix = entry.children ? "▸" : (entry.shortcut || "");
            result = Math.max(result, metrics.advanceWidth(entry.label) + metrics.advanceWidth(suffix) + 78);
        }
        return result;
    }
    implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding,
                             Overlay.overlay ? Overlay.overlay.height - 64 : 720)

    FontMetrics { id: metrics; font: root.font }

    background: Rectangle {
        color: "#202125"
        border.color: Theme.borderControl
        radius: 9
    }
    contentItem: ListView {
        implicitHeight: contentHeight
        model: root.contentModel
        currentIndex: root.currentIndex
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: UiScrollBar { }
    }

    function populate() {
        if (!ready) return;
        for (const old of generatedEntries) {
            if (old.isSubmenu) removeMenu(old.object);
            else removeItem(old.object);
            old.object.destroy();
        }
        let created = [];
        for (const entry of entries) {
            if (entry.children) {
                // Resolve lazily: Qt forbids statically recursive QML types.
                const submenuFactory = Qt.createComponent("MenuEntries.qml");
                const submenu = submenuFactory.createObject(root, {
                    title: entry.label, entries: entry.children, actions: root.actions,
                    objectName: "menu-" + entry.id
                });
                root.addMenu(submenu);
                created.push({ object: submenu, isSubmenu: true });
            } else {
                const factory = entry.kind === "separator" ? separatorFactory : itemFactory;
                const item = factory.createObject(root.contentItem, { entry: entry });
                root.addItem(item);
                created.push({ object: item, isSubmenu: false });
            }
        }
        generatedEntries = created;
    }
    onEntriesChanged: populate()
    Component.onCompleted: { ready = true; populate(); }

    delegate: MenuItem {
        id: submenuItem
        hoverEnabled: true
        implicitHeight: 30
        leftPadding: 5
        rightPadding: 9
        font: root.font
        arrow: UiText {
            x: submenuItem.width - width - 9
            y: (submenuItem.height - height) / 2
            text: "▸"
            font.pixelSize: 11
            color: Theme.muted
            visible: submenuItem.subMenu !== null
        }
        contentItem: UiText {
            text: submenuItem.text
            font: root.font
            leftPadding: 22
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 5
            color: submenuItem.highlighted ? "#34353c" : "transparent"
        }
    }

    Component {
        id: separatorFactory
        MenuSeparator {
            required property var entry
            objectName: "menu-" + entry.id
            padding: 5
            implicitWidth: root.width - root.leftPadding - root.rightPadding
            implicitHeight: 11
            contentItem: Rectangle { implicitHeight: 1; color: Theme.borderControl }
        }
    }
    Component {
        id: itemFactory
        MenuItem {
            id: actionItem
            hoverEnabled: true
            required property var entry
            objectName: "menu-" + entry.id
            text: entry.label
            enabled: root.actions.canActivate(entry.id)
            implicitHeight: 30
            font: root.font
            padding: 0
            onTriggered: root.actions.activate(entry.id, entry.label)
            contentItem: Item {
                Rectangle {
                    x: 5
                    width: actionItem.entry.kind === "check" ? 13 : 17
                    height: actionItem.entry.kind === "check" ? 13 : 17
                    anchors.verticalCenter: parent.verticalCenter
                    color: "transparent"
                    radius: 3
                    border.width: actionItem.entry.kind === "check" ? 1 : 0
                    border.color: "#666873"
                    UiText {
                        anchors.centerIn: parent
                        font.pixelSize: 11
                        color: Theme.accent
                        text: actionItem.entry.kind === "check"
                            ? (root.actions.isSelected(actionItem.entry) ? "✓" : "")
                            : actionItem.entry.kind === "radio"
                              ? (root.actions.isSelected(actionItem.entry) ? "●" : "○") : ""
                    }
                }
                UiText {
                    x: 27
                    anchors.verticalCenter: parent.verticalCenter
                    text: actionItem.text
                    font: root.font
                    color: actionItem.enabled ? Theme.text : Theme.muted
                }
                UiText {
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: actionItem.entry.shortcut || ""
                    color: Theme.muted
                    font.pixelSize: 11
                }
            }
            background: Rectangle {
                radius: 5
                color: actionItem.highlighted ? "#34353c" : "transparent"
            }
        }
    }
}
