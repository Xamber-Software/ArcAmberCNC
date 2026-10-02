pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import BetterCnc.Ui 1.0

Rectangle {
    id: root

    required property ManualState presentation
    property bool compact: false
    property var machine: ({})
    property var history: []
    readonly property bool connected: !!machine.connected
    // Records a held UI gesture, never inferred machine motion.
    property bool jogHeld: false
    readonly property bool jogSafe: connected && !!machine.powered && !machine.estop
        && machine.mode === "manual" && machine.motionMode === presentation.mode
    readonly property bool canOperate: connected && !!machine.powered && !machine.estop && !machine.busy
    readonly property string axesKey: (machine.axes || []).join(",")
    readonly property string jointsKey: (Array.isArray(machine.joints) ? machine.joints
        : Array.from({length: Number(machine.jointCount || 0)}, (_, index) => index)).join(",")
    readonly property var axes: axesKey ? axesKey.split(",") : []
    readonly property var joints: jointsKey ? jointsKey.split(",").map(Number) : []
    readonly property var selectionValues: presentation.mode === "joint" ? joints : axes
    readonly property bool canJog: jogSafe && canOperate && (presentation.mode === "joint"
        ? joints.indexOf(presentation.selectedJoint) >= 0 : axes.indexOf(presentation.selectedAxis) >= 0)
    signal dialogRequested(string actionId, string title, string axis)
    signal commandRequested(string actionId, var payload)
    signal jogStopRequested()

    function permitted(id) {
        return connected && (!machine.capabilities || machine.capabilities[id] !== false);
    }
    function startJog(direction) {
        if (jogHeld || !canJog || !permitted("jog.start") || presentation.jogVelocity <= 0) return;
        jogHeld = true;
        commandRequested("jog.start", {axis: presentation.mode === "joint" ? presentation.selectedJoint : presentation.selectedAxis, direction: direction,
            velocity: presentation.jogVelocity / 60, increment: presentation.jogIncrement,
            mode: presentation.mode});
    }
    function releaseJog() {
        jogHeld = false;
        jogStopRequested();
    }
    function cancelJogGesture() { jogHeld = false; }
    function executeMdi() {
        const command = mdiCommand.text.trim();
        if (canOperate && command) commandRequested("mdi.execute", {text: command});
    }
    onVisibleChanged: if (!visible) releaseJog()
    onJogSafeChanged: if (!jogSafe) releaseJog()
    Connections {
        target: root.presentation
        function onControlTabChanged() { root.releaseJog(); }
        function onSelectedAxisChanged() { root.releaseJog(); }
        function onSelectedJointChanged() { root.releaseJog(); }
        function onModeChanged() { root.releaseJog(); }
    }

    objectName: "manualPanel"
    implicitWidth: compact ? 264 : 296
    color: Theme.sidebar
    clip: true

    Connections {
        target: root.Window.window
        function onActiveChanged() { if (!root.Window.window.active) root.releaseJog(); }
        function onActiveFocusItemChanged() {
            const focused = root.Window.window.activeFocusItem;
            if (!focused) return;
            let ancestor = focused;
            while (ancestor && ancestor !== contentColumn) ancestor = ancestor.parent;
            if (!ancestor) return;
            const top = focused.mapToItem(contentColumn, 0, 0).y;
            const bottom = top + focused.height;
            const requested = top < scroller.contentY ? top
                : bottom > scroller.contentY + scroller.height ? bottom - scroller.height
                : scroller.contentY;
            scroller.contentY = Math.max(0, Math.min(scroller.contentHeight - scroller.height, requested));
        }
    }

    Flickable {
        id: scroller
        objectName: "manualScroller"
        anchors.fill: parent
        anchors.rightMargin: 1
        contentWidth: width
        contentHeight: contentColumn.height
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        clip: true
        ScrollBar.vertical: UiScrollBar {}

        Column {
            id: contentColumn
            width: scroller.width

            Item {
                width: parent.width
                height: 44

                Row {
                    id: tabs
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    function selectTab(tab) {
                        root.presentation.controlTab = tab;
                        (tab === "manual" ? manualTabButton : mdiTabButton).forceActiveFocus(Qt.TabFocusReason);
                    }

                    UiButton {
                        id: manualTabButton
                        objectName: "manualTab"
                        text: "手动操作 [F3]"
                        kind: "tab"
                        selected: root.presentation.controlTab === "manual"
                        Accessible.role: Accessible.PageTab
                        Accessible.name: text
                        onClicked: root.presentation.controlTab = "manual"
                        Keys.onLeftPressed: tabs.selectTab("mdi")
                        Keys.onRightPressed: tabs.selectTab("mdi")
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                                tabs.selectTab(event.key === Qt.Key_Home ? "manual" : "mdi");
                                event.accepted = true;
                            }
                        }
                    }

                    UiButton {
                        id: mdiTabButton
                        objectName: "mdiTab"
                        text: "手动输入 [F5]"
                        kind: "tab"
                        selected: root.presentation.controlTab === "mdi"
                        Accessible.role: Accessible.PageTab
                        Accessible.name: text
                        onClicked: root.presentation.controlTab = "mdi"
                        Keys.onLeftPressed: tabs.selectTab("manual")
                        Keys.onRightPressed: tabs.selectTab("manual")
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                                tabs.selectTab(event.key === Qt.Key_Home ? "manual" : "mdi");
                                event.accepted = true;
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.border
                }
            }

            Item {
                id: manualArea
                readonly property int panelPadding: root.compact ? 12 : 18
                readonly property int verticalPadding: root.compact ? 12 : 16
                width: parent.width
                height: visible ? manualContent.height + verticalPadding * 2 : 0
                visible: root.presentation.controlTab === "manual"

                Column {
                    id: manualContent
                    x: manualArea.panelPadding
                    y: manualArea.verticalPadding
                    width: parent.width - manualArea.panelPadding * 2

                    RowLayout {
                        width: parent.width
                        height: 30
                        spacing: 7

                        UiText {
                            text: root.presentation.mode === "joint" ? "关节：" : "坐标轴："
                            font.pixelSize: 11
                            color: Theme.secondary
                            Layout.preferredWidth: 53
                            Layout.fillHeight: true
                            verticalAlignment: Text.AlignVCenter
                        }

                        RowLayout {
                            id: axisSelector
                            spacing: 5
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            function selectAxis(index) {
                                const next = (index + root.selectionValues.length) % root.selectionValues.length;
                                if (root.presentation.mode === "joint") root.presentation.selectedJoint = Number(root.selectionValues[next]);
                                else root.presentation.selectedAxis = String(root.selectionValues[next]);
                                axisRepeater.itemAt(next).forceActiveFocus(Qt.TabFocusReason);
                            }

                            Repeater {
                                id: axisRepeater
                                model: root.selectionValues

                                RadioButton {
                                    id: axisButton
                                    required property var modelData
                                    required property int index
                                    objectName: (root.presentation.mode === "joint" ? "joint" : "axis") + modelData
                                    text: String(modelData)
                                    checked: root.presentation.mode === "joint" ? root.presentation.selectedJoint === Number(modelData)
                                             : root.presentation.selectedAxis === String(modelData)
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 30
                                    padding: 0
                                    hoverEnabled: true
                                    indicator: null
                                    Accessible.name: text

                                    contentItem: Item {
                                        Row {
                                            anchors.centerIn: parent
                                            spacing: 5

                                            Rectangle {
                                                width: 10
                                                height: 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                radius: 5
                                                color: axisButton.checked ? Theme.accentFill : Theme.input
                                                border.width: 1
                                                border.color: axisButton.checked ? Theme.accent : "#5b5d68"

                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: 4
                                                    height: 4
                                                    radius: 2
                                                    color: "white"
                                                    visible: axisButton.checked
                                                }
                                            }

                                            UiText {
                                                text: axisButton.text
                                                font.family: Theme.mono
                                                font.pixelSize: 12
                                                color: axisButton.checked ? "#d0caff" : Theme.text
                                            }
                                        }
                                    }

                                    background: Rectangle {
                                        radius: 5
                                        color: axisButton.checked ? Theme.accentSoft : Theme.input
                                        border.width: axisButton.visualFocus ? 2 : 1
                                        border.color: axisButton.visualFocus ? Theme.accent : axisButton.checked ? "#5c537e" : Theme.borderControl
                                    }

                                    onClicked: {
                                        if (root.presentation.mode === "joint") root.presentation.selectedJoint = Number(modelData);
                                        else root.presentation.selectedAxis = String(modelData);
                                    }
                                    Keys.onLeftPressed: axisSelector.selectAxis(index - 1)
                                    Keys.onRightPressed: axisSelector.selectAxis(index + 1)
                                    Keys.onUpPressed: axisSelector.selectAxis(index - 1)
                                    Keys.onDownPressed: axisSelector.selectAxis(index + 1)
                                }
                            }
                        }
                    }

                    Item {
                        width: 1
                        height: 12
                    }

                    RowLayout {
                        width: parent.width
                        height: 30
                        spacing: 6

                        UiButton {
                            objectName: "jogMinus"
                            text: "−"
                            font.pixelSize: 18
                            Layout.preferredWidth: 40
                            Layout.preferredHeight: 30
                            Accessible.name: "负向点动"
                            enabled: root.jogHeld ? root.jogSafe : root.canJog && root.permitted("jog.start")
                            onPressed: root.startJog(-1)
                            onReleased: root.releaseJog()
                            onCanceled: root.releaseJog()
                            onActiveFocusChanged: if (!activeFocus && down) root.releaseJog()
                        }

                        UiButton {
                            objectName: "jogPlus"
                            text: "+"
                            font.pixelSize: 18
                            Layout.preferredWidth: 40
                            Layout.preferredHeight: 30
                            Accessible.name: "正向点动"
                            enabled: root.jogHeld ? root.jogSafe : root.canJog && root.permitted("jog.start")
                            onPressed: root.startJog(1)
                            onReleased: root.releaseJog()
                            onCanceled: root.releaseJog()
                            onActiveFocusChanged: if (!activeFocus && down) root.releaseJog()
                        }

                        UiComboBox {
                            objectName: "jogIncrement"
                            model: ["连续点动", "0.1000", "0.0100", "0.0010", "0.0001"]
                            Layout.fillWidth: true
                            Layout.preferredHeight: 30
                            Accessible.name: "点动方式与步距"
                            onActivated: {
                                root.releaseJog();
                                root.presentation.jogIncrement = currentIndex === 0 ? 0 : Number(currentText);
                            }
                        }
                    }

                    Item {
                        width: 1
                        height: 8
                    }

                    RowLayout {
                        width: parent.width
                        height: 30
                        spacing: 5

                        UiButton {
                            objectName: "homeAll"
                            text: "全部回零"
                            font.pixelSize: 11
                            leftPadding: 3
                            rightPadding: 3
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.preferredHeight: 30
                            enabled: root.canOperate && root.permitted("machine.home-all")
                            onClicked: root.commandRequested("machine.home-all", {})
                        }

                        UiButton {
                            objectName: "workTouchOff"
                            text: "工件对刀"
                            font.pixelSize: 11
                            leftPadding: 3
                            rightPadding: 3
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.preferredHeight: 30
                            enabled: root.canOperate && root.presentation.mode === "world" && root.permitted("machine.touch-off")
                            onClicked: root.dialogRequested("machine.touch-off", "工件对刀", root.presentation.selectedAxis)
                        }

                        UiButton {
                            objectName: "toolTouchOff"
                            text: "刀具对刀"
                            font.pixelSize: 11
                            leftPadding: 3
                            rightPadding: 3
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.preferredHeight: 30
                            enabled: root.canOperate && root.presentation.mode === "world" && root.permitted("tool.touch-off")
                            onClicked: root.dialogRequested("tool.touch-off", "刀具对刀", root.presentation.selectedAxis)
                        }
                    }

                    Item {
                        width: 1
                        height: 7
                    }

                    UiCheckBox {
                        objectName: "overrideLimits"
                        width: parent.width
                        height: 27
                        text: "临时解除硬限位"
                        checked: !!root.machine.limitOverride
                        interactive: false
                        enabled: root.canOperate && root.permitted("machine.override-limits")
                        onClicked: root.commandRequested("machine.override-limits", {enabled: !checked})
                    }

                    Item {
                        width: parent.width
                        height: 120

                        Rectangle {
                            y: 13
                            width: parent.width
                            height: 1
                            color: Theme.border
                        }

                        UiText {
                            y: 34
                            width: 53
                            text: "主轴："
                            color: Theme.secondary
                            font.pixelSize: 11
                        }

                        Column {
                            x: 60
                            y: 27
                            width: parent.width - 60
                            spacing: 5

                            RowLayout {
                                width: parent.width
                                height: 28
                                spacing: 5

                                UiButton {
                                    objectName: "spindleCounterclockwise"
                                    iconName: "left"
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 30
                                    Layout.preferredWidth: 60
                                    Layout.preferredHeight: 28
                                    leftPadding: 6
                                    rightPadding: 6
                                    Accessible.name: "主轴反转"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "主轴反转"
                                    enabled: root.canOperate && root.permitted("spindle.ccw")
                                    onClicked: root.commandRequested("spindle.ccw", {})
                                }

                                UiButton {
                                    objectName: "spindleStop"
                                    text: "停止"
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 60
                                    Layout.preferredWidth: 60
                                    Layout.preferredHeight: 28
                                    leftPadding: 6
                                    rightPadding: 6
                                    enabled: root.canOperate && root.permitted("spindle.stop")
                                    onClicked: root.commandRequested("spindle.stop", {})
                                }

                                UiButton {
                                    objectName: "spindleClockwise"
                                    iconName: "right"
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 30
                                    Layout.preferredWidth: 60
                                    Layout.preferredHeight: 28
                                    leftPadding: 6
                                    rightPadding: 6
                                    Accessible.name: "主轴正转"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "主轴正转"
                                    enabled: root.canOperate && root.permitted("spindle.cw")
                                    onClicked: root.commandRequested("spindle.cw", {})
                                }
                            }

                            RowLayout {
                                width: parent.width
                                height: 28
                                spacing: 5

                                UiButton {
                                    objectName: "spindleDecrease"
                                    text: "−"
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 28
                                    leftPadding: 6
                                    rightPadding: 6
                                    Accessible.name: "降低主轴转速"
                                    enabled: root.canOperate && root.permitted("spindle.decrease")
                                    onClicked: root.commandRequested("spindle.decrease", {})
                                }

                                UiButton {
                                    objectName: "spindleIncrease"
                                    text: "+"
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 28
                                    leftPadding: 6
                                    rightPadding: 6
                                    Accessible.name: "提高主轴转速"
                                    enabled: root.canOperate && root.permitted("spindle.increase")
                                    onClicked: root.commandRequested("spindle.increase", {})
                                }
                            }

                            UiCheckBox {
                                objectName: "spindleBrake"
                                width: parent.width
                                height: 27
                                text: "主轴制动"
                                checked: !!root.machine.spindleBrake
                                interactive: false
                                enabled: root.canOperate && root.permitted("spindle.brake")
                                onClicked: root.commandRequested("spindle.brake", {enabled: !checked})
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: 62

                        UiText {
                            y: 13
                            width: 53
                            text: "冷却："
                            color: Theme.secondary
                            font.pixelSize: 11
                        }

                        Column {
                            x: 60
                            y: 8
                            width: parent.width - 60

                            UiCheckBox {
                                objectName: "mistCoolant"
                                width: parent.width
                                height: 27
                                text: "喷雾冷却"
                                checked: !!root.machine.mist
                                interactive: false
                                enabled: root.canOperate && root.permitted("coolant.mist")
                                onClicked: root.commandRequested("coolant.mist", {enabled: !checked})
                            }

                            UiCheckBox {
                                objectName: "floodCoolant"
                                width: parent.width
                                height: 27
                                text: "切削液冷却"
                                checked: !!root.machine.flood
                                interactive: false
                                enabled: root.canOperate && root.permitted("coolant.flood")
                                onClicked: root.commandRequested("coolant.flood", {enabled: !checked})
                            }
                        }
                    }
                }
            }

            Item {
                id: mdiArea
                readonly property int panelPadding: root.compact ? 12 : 18
                readonly property int verticalPadding: root.compact ? 12 : 16
                width: parent.width
                height: visible ? 270 + verticalPadding * 2 : 0
                visible: root.presentation.controlTab === "mdi"

                Item {
                    x: mdiArea.panelPadding
                    y: mdiArea.verticalPadding
                    width: parent.width - mdiArea.panelPadding * 2
                    height: 270

                    UiText {
                        height: 18
                        text: "历史指令："
                        font.pixelSize: 12
                        color: Theme.secondary
                    }

                    Rectangle {
                        y: 26
                        width: parent.width
                        height: 160
                        radius: 6
                        color: Theme.input
                        border.width: 1
                        border.color: Theme.border

                        ListView {
                            id: historyList
                            objectName: "mdiHistory"
                            anchors.fill: parent
                            anchors.margins: 6
                            clip: true
                            model: root.history
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: UiScrollBar {}
                            Accessible.name: "手动输入历史"

                            delegate: ItemDelegate {
                                id: historyButton
                                required property string modelData
                                required property int index
                                objectName: "mdiHistory" + index
                                width: historyList.width
                                height: 28
                                padding: 0
                                text: modelData
                                hoverEnabled: true

                                contentItem: UiText {
                                    leftPadding: 6
                                    rightPadding: 6
                                    text: historyButton.text
                                    font.family: Theme.mono
                                    font.pixelSize: 12
                                    color: historyButton.hovered || historyButton.visualFocus ? Theme.text : Theme.secondary
                                    verticalAlignment: Text.AlignVCenter
                                }

                                background: Rectangle {
                                    radius: 4
                                    color: historyButton.hovered || historyButton.visualFocus ? Theme.accentSoft : "transparent"
                                }

                                onClicked: mdiCommand.text = modelData
                            }
                        }
                    }

                    UiText {
                        y: 202
                        height: 18
                        text: "手动输入指令："
                        font.pixelSize: 12
                        color: Theme.secondary
                    }

                    RowLayout {
                        y: 228
                        width: parent.width
                        height: 32
                        spacing: 4

                        UiTextField {
                            id: mdiCommand
                            objectName: "mdiCommand"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32
                            font.family: Theme.mono
                            Accessible.name: "手动输入指令："
                            selectByMouse: true
                            onAccepted: root.executeMdi()
                        }

                        UiButton {
                            objectName: "mdiExecute"
                            text: "执行"
                            Layout.preferredWidth: 48
                            Layout.preferredHeight: 30
                            enabled: root.canOperate && root.permitted("mdi.execute") && mdiCommand.text.trim().length > 0
                            onClicked: root.executeMdi()
                        }
                    }
                }
            }

            Item {
                id: overrides
                readonly property int panelPadding: root.compact ? 12 : 18
                readonly property int topPadding: root.compact ? 14 : 16
                width: parent.width
                height: topPadding + 1 + 34 + ranges.height

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.border
                }

                UiText {
                    x: overrides.panelPadding
                    y: overrides.topPadding + 1
                    height: 18
                    text: "速度与倍率"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    verticalAlignment: Text.AlignVCenter
                }

                Column {
                    id: ranges
                    x: overrides.panelPadding
                    y: overrides.topPadding + 35
                    width: parent.width - overrides.panelPadding * 2

                    UiRange {
                        objectName: "feedOverride"
                        width: parent.width
                        height: 49
                        label: "进给倍率"
                        to: 120
                        value: Number(root.machine.feedOverride || 0) * 100
                        valueKnown: root.connected && typeof root.machine.feedOverride === "number" && isFinite(root.machine.feedOverride)
                        enabled: valueKnown && root.permitted("override.feed")
                        onMoved: value => root.commandRequested("override.feed", {value: value / 100})
                    }

                    UiRange {
                        objectName: "rapidOverride"
                        width: parent.width
                        height: 49
                        label: "快移倍率"
                        to: 100
                        value: Number(root.machine.rapidOverride || 0) * 100
                        valueKnown: root.connected && typeof root.machine.rapidOverride === "number" && isFinite(root.machine.rapidOverride)
                        enabled: valueKnown && root.permitted("override.rapid")
                        onMoved: value => root.commandRequested("override.rapid", {value: value / 100})
                    }

                    UiRange {
                        objectName: "spindleOverride"
                        width: parent.width
                        height: 49
                        label: "主轴倍率"
                        to: 120
                        value: Number(root.machine.spindleOverride || 0) * 100
                        valueKnown: root.connected && typeof root.machine.spindleOverride === "number" && isFinite(root.machine.spindleOverride)
                        enabled: valueKnown && root.permitted("override.spindle")
                        onMoved: value => root.commandRequested("override.spindle", {value: value / 100})
                    }

                    UiRange {
                        objectName: "jogVelocity"
                        width: parent.width
                        height: 49
                        label: "点动速度"
                        to: Number(root.machine.jogMaxVelocity || root.machine.maxVelocity || 0) * 60
                        value: root.presentation.jogVelocity
                        enabled: root.connected
                        unit: root.machine.linearUnits === 1 ? "毫米/分钟" : "机床单位/分钟"
                        onMoved: value => { root.releaseJog(); root.presentation.jogVelocity = value; }
                    }

                    UiRange {
                        objectName: "maxVelocity"
                        width: parent.width
                        height: 49
                        label: "最大速度"
                        to: Number(root.machine.maxVelocityLimit || root.machine.maxVelocity || 0) * 60
                        value: Number(root.machine.maxVelocity || 0) * 60
                        valueKnown: root.connected && typeof root.machine.maxVelocity === "number" && isFinite(root.machine.maxVelocity)
                        enabled: valueKnown && root.permitted("velocity.max")
                        unit: root.machine.linearUnits === 1 ? "毫米/分钟" : "机床单位/分钟"
                        onMoved: value => root.commandRequested("velocity.max", {value: value / 60})
                    }
                }
            }

            Item {
                id: activeCodes
                width: parent.width
                height: visible ? 6 + 17 + 8 + codes.height + 12 : 0
                visible: root.presentation.controlTab === "mdi"

                UiText {
                    x: 18
                    y: 6
                    height: 17
                    text: "当前模态指令："
                    color: Theme.secondary
                    font.pixelSize: 11
                }

                Rectangle {
                    id: codes
                    objectName: "activeCodes"
                    x: 18
                    y: 31
                    width: parent.width - 36
                    height: codeText.implicitHeight + 20
                    color: Theme.input
                    radius: 6
                    border.color: Theme.border
                    border.width: 1

                    UiText {
                        id: codeText
                        x: 10
                        y: 10
                        width: parent.width - 20
                        text: root.machine.activeCodes || "—"
                        color: Theme.secondary
                        font.family: Theme.mono
                        font.pixelSize: 11
                        lineHeightMode: Text.FixedHeight
                        lineHeight: 21
                        wrapMode: Text.Wrap
                    }
                }
            }

            Item {
                width: 1
                height: 10
            }
        }
    }

    Rectangle {
        anchors.right: parent.right
        height: parent.height
        width: 1
        color: Theme.border
    }
}
