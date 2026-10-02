pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import BetterCnc.Ui 1.0
import BetterCnc.Catalog 1.0

Popup {
    id: root
    objectName: "axis-dialog"
    property string actionId: ""
    property string title: ""
    property string axis: "X"
    property string value: "0.0"
    property string coordinateSystem: "G54"
    property var machine: ({})
    property var program: null
    property string toolTableText: ""
    property string touchTarget: "workpiece"
    property string editorText: ""
    property string message: ""
    property string validationError: ""
    signal submitted(string actionId, var payload)
    readonly property bool editable: ["machine.touch-off", "tool.touch-off", "view.grid-custom",
                                      "file.edit", "tool.edit", "machine.debug"].indexOf(actionId) >= 0
    readonly property bool submissionEnabled: actionId === "view.grid-custom"
        || (actionId === "file.edit" && !machine.busy) || (!!machine.connected && !machine.busy)
    readonly property string description: {
        if (actionId === "help.about") return "基于 AXIS 的 LinuxCNC 中文操作界面";
        if (actionId === "help.reference") return "机床快捷键在文本输入、菜单和对话框中隔离；点动在松键、失焦时停止。";
        if (actionId === "file.properties") return "当前加工程序的信息。";
        if (actionId === "file.edit") return "修改当前加工程序，保存后重新加载。";
        if (actionId === "tool.edit") return "编辑 LinuxCNC 刀具表，保存后重新加载刀具数据。";
        if (actionId === "tool.touch-off" || (actionId === "machine.touch-off" && touchTarget === "tool"))
            return "保存当前刀具对刀值；已有刀长补偿将从当前刀号重新加载，替换动态补偿";
        if (actionId === "machine.touch-off") return "输入当前刀具位置对应的工件坐标。";
        if (actionId === "view.grid-custom") return "设置刀路视图的网格间距（毫米）。";
        if (actionId === "machine.debug") return "设置控制器调试标志（非负整数）。";
        return message;
    }
    parent: Overlay.overlay
    popupType: Popup.Item
    width: Math.min(["file.edit", "tool.edit"].indexOf(actionId) >= 0 ? 760
                    : actionId === "help.reference" ? 516 : 370, parent ? parent.width * 0.92 : 760)
    height: Math.min(58 + body.implicitHeight + 44, parent ? parent.height * 0.85 : 680)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? parent.height * 0.46 - height / 2 : 0
    padding: 1
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    enter: Transition { }
    exit: Transition { }
    Overlay.modal: Rectangle { color: "#99000000" }
    background: Rectangle { color: Theme.raised; border.color: "#3b3d45"; radius: 12 }

    function openDialog(id, label, selectedAxis) {
        const item = Catalog.findItem(id);
        actionId = id;
        title = item ? item.label.replace("…", "") : (label || "操作说明");
        axis = selectedAxis || "X";
        value = id === "machine.debug" && machine.debug !== null && machine.debug !== undefined ? String(machine.debug) : "0.0";
        validationError = "";
        message = "";
        editorText = id === "tool.edit" ? toolTableText : program ? program.text : "";
        open();
    }
    function openMessage(heading, detailMessage) {
        actionId = "controller.message";
        title = heading;
        message = detailMessage;
        validationError = "";
        open();
    }
    function submit() {
        if (!submissionEnabled) return;
        if (actionId === "file.edit" || actionId === "tool.edit") {
            validationError = "";
            submitted(actionId === "file.edit" ? "file.save-edits" : "tool.save", {text: editorText});
            return;
        }
        const number = Number(value);
        if (!value.trim() || !isFinite(number) || (actionId === "view.grid-custom" && number <= 0)
                || (actionId === "machine.debug" && (number < 0 || Math.floor(number) !== number))) {
            validationError = "请输入有效的数值。";
            return;
        }
        submitted(actionId, {axis: axis, value: number, system: coordinateSystem, target: touchTarget});
        close();
    }
    onOpened: closeButton.forceActiveFocus()

    contentItem: Item {
        Item {
            id: titlebar
            width: parent.width
            height: 56
            UiText {
                x: 22
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
            }
            UiButton {
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                objectName: "dialog-dismiss"
                text: "×"
                kind: "toolbar"
                width: 28
                height: 28
                font.pixelSize: 22
                Accessible.name: "关闭对话框"
                onClicked: root.close()
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        }
        Flickable {
            id: bodyScroll
            anchors.top: titlebar.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            contentWidth: width
            contentHeight: body.implicitHeight + 44
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: UiScrollBar { }
            Column {
                id: body
                x: 22
                y: 22
                width: bodyScroll.width - 44
                spacing: 0
                UiText {
                    objectName: "dialog-description"
                    width: parent.width
                    text: root.description
                    color: Theme.secondary
                    lineHeightMode: Text.FixedHeight
                    lineHeight: 23.4
                    height: lineCount * 23.4
                    wrapMode: Text.WordWrap
                }
                Item { width: 1; height: 18 }
                Loader {
                    id: detail
                    width: parent.width
                    sourceComponent: {
                        if (root.actionId === "help.about") return aboutContent;
                        if (root.actionId === "help.reference") return referenceContent;
                        if (root.actionId === "file.properties") return propertiesContent;
                        if (root.actionId === "file.edit" || root.actionId === "tool.edit") return editorContent;
                        if (["machine.touch-off", "tool.touch-off"].indexOf(root.actionId) >= 0) return touchContent;
                        if (root.actionId === "view.grid-custom" || root.actionId === "machine.debug") return gridContent;
                        return null;
                    }
                }
                Item { width: 1; height: 24 }
                UiText {
                    objectName: "dialog-validation-error"
                    width: parent.width
                    text: root.validationError
                    color: Theme.danger
                    visible: text.length > 0
                    wrapMode: Text.WordWrap
                }
                Row {
                    anchors.right: parent.right
                    spacing: 8
                    UiButton {
                        id: closeButton
                        objectName: "dialog-close"
                        width: 75
                        text: root.editable ? "取消" : "关闭"
                        onClicked: root.close()
                    }
                    UiButton {
                        objectName: "dialog-submit"
                        visible: root.editable
                        enabled: root.submissionEnabled
                        kind: "primary"
                        width: 75
                        text: root.actionId === "file.edit" || root.actionId === "tool.edit" ? "保存" : "应用"
                        onClicked: root.submit()
                    }
                }
            }
        }
    }

    Component {
        id: aboutContent
        RowLayout {
            spacing: 17
            Image { source: Catalog.axisLogo; Layout.preferredWidth: 48; Layout.preferredHeight: 48; Layout.alignment: Qt.AlignTop }
            Column {
                Layout.fillWidth: true
                spacing: 7
                UiText { text: "BetterLinuxCNC"; font.pixelSize: 18; font.bold: true }
                UiText { text: root.machine.machineName || "LinuxCNC"; font.pixelSize: 13 }
                UiText { text: "Qt Quick 中文操作界面" }
                UiText { text: "功能与布局参考 AXIS 2.9.10。" }
            }
        }
    }
    Component {
        id: referenceContent
        GridLayout {
            columns: 2
            columnSpacing: 22
            rowSpacing: 7
            Repeater {
                model: Catalog.quickReference.length * 2
                delegate: UiText {
                    required property int index
                    text: Catalog.quickReference[Math.floor(index / 2)][index % 2]
                    font.family: index % 2 === 0 ? Theme.mono : Theme.fontFamily
                    Layout.fillWidth: index % 2 === 1
                }
            }
        }
    }
    Component {
        id: propertiesContent
        GridLayout {
            columns: 2
            columnSpacing: 22
            rowSpacing: 7
            UiText { text: "文件名"; font.bold: true }
            UiText { text: root.program ? root.program.fileName : "未打开程序"; Layout.fillWidth: true }
            UiText { text: "程序行数"; font.bold: true }
            UiText { text: root.program ? root.program.lines.length : 0 }
            UiText { text: "程序来源"; font.bold: true }
            UiText { text: root.program ? root.program.filePath : "—"; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere }
            UiText { text: "刀路预览"; font.bold: true }
            UiText { text: root.program ? (root.program.previewBusy ? "正在解释程序" : root.program.previewError || "RS274 刀路") : "—"; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        }
    }
    Component {
        id: editorContent
        ScrollView {
            height: 340
            clip: true
            TextArea {
                objectName: "dialog-editor"
                text: root.editorText
                font.family: Theme.mono
                font.pixelSize: 12
                color: Theme.text
                selectionColor: Theme.accentSoft
                selectedTextColor: Theme.text
                wrapMode: TextEdit.NoWrap
                selectByMouse: true
                padding: 10
                background: Rectangle { color: Theme.input; border.color: Theme.borderControl; radius: 6 }
                onTextChanged: root.editorText = text
            }
        }
    }
    Component {
        id: touchContent
        ColumnLayout {
            spacing: 11
            UiText { text: "设置 " + root.axis + " 轴" + (root.actionId.indexOf("tool") === 0 ? "刀具偏置" : "工件坐标") + "：" }
            RowLayout {
                spacing: 10
                UiText { text: "设定值" }
                UiTextField {
                    objectName: "touch-value"
                    Layout.preferredWidth: 130
                    text: root.value
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    Accessible.name: "设定值"
                    onTextEdited: root.value = text
                }
            }
            RowLayout {
                spacing: 10
                UiText { text: "工件坐标系" }
                UiComboBox {
                    objectName: "touch-coordinate-system"
                    model: Catalog.coordinateSystems
                    currentIndex: Catalog.coordinateSystems.indexOf(root.coordinateSystem)
                    Accessible.name: "工件坐标系"
                    onActivated: root.coordinateSystem = currentText
                }
            }
        }
    }
    Component {
        id: gridContent
        RowLayout {
            spacing: 10
            UiText { text: root.actionId === "machine.debug" ? "调试标志" : "网格间距" }
            UiTextField {
                objectName: "grid-spacing"
                Layout.preferredWidth: 130
                text: root.value
                Accessible.name: "网格间距"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onTextEdited: root.value = text
            }
            UiText { text: root.actionId === "machine.debug" ? "" : "毫米"; Layout.fillWidth: true }
        }
    }
}
