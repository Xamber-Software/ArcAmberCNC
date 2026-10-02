pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs as NativeDialogs
import BetterCnc.Ui 1.0
import BetterCnc.Manual 1.0
import BetterCnc.Toolpath 1.0
import BetterCnc.Program 1.0
import BetterCnc.Chrome 1.0

Rectangle {
    id: workspace
    objectName: "workspace"
    color: Theme.base
    property Item focusedItem: null
    property var backend: null
    readonly property var machine: backend && backend.snapshot ? backend.snapshot : ({})
    readonly property var program: backend ? backend.program : null
    readonly property string axesKey: (machine.axes || []).join(",")
    readonly property var configuredAxes: axesKey ? axesKey.split(",") : []
    property string lastConnectionMessage: ""
    property var activeJogKeys: ({})
    readonly property bool popupActive: dialogs.visible || openFile.visible || saveFile.visible
    signal quitRequested()
    focus: true

    function stopJog() {
        activeJogKeys = ({});
        manualPanel.cancelJogGesture();
        if (backend) backend.stopJog();
    }
    function showBackendFailure(title, message) {
        if (dialogs.visible && (dialogs.actionId === "file.edit" || dialogs.actionId === "tool.edit"))
            dialogs.validationError = message;
        else dialogs.openMessage(title, message);
    }
    function syncMachine() {
        const axes = machine.axes || [];
        if (axes.length && axes.indexOf(manualPresentation.selectedAxis) < 0)
            manualPresentation.selectedAxis = axes[0];
        if (machine.motionMode) manualPresentation.mode = machine.motionMode;
        const jointCount = Number(machine.jointCount || (machine.joints ? machine.joints.length : 0));
        if (manualPresentation.selectedJoint >= jointCount) manualPresentation.selectedJoint = 0;
        const maximum = Number(machine.jogMaxVelocity || machine.maxVelocity || 0) * 60;
        if (maximum > 0 && manualPresentation.jogVelocity <= 0)
            manualPresentation.jogVelocity = Math.min(maximum, machine.linearUnits === 1 ? 600 : 24);
        else if (maximum > 0 && manualPresentation.jogVelocity > maximum)
            manualPresentation.jogVelocity = maximum;
        if (!machine.connected) {
            stopJog();
            const reason = machine.message || "";
            if (!machine.connecting && reason && reason !== lastConnectionMessage) showBackendFailure("连接失败", reason);
            lastConnectionMessage = machine.connecting ? "" : reason;
        } else lastConnectionMessage = "";
    }
    function requestCommand(id, payload) {
        if (!backend) return;
        if (id !== "jog.start") stopJog();
        if (id === "file.open" || id === "file.open-sample") {
            if (payload.path) backend.openProgram(payload.path);
            else openFile.open();
        } else if (id === "file.reload") backend.reloadProgram();
        else if (id === "file.save") saveFile.open();
        else if (id === "file.quit") quitRequested();
        else if (id === "file.save-edits") {
            if (program) backend.saveProgram(program.filePath, payload.text);
        } else if (id === "tool.save") {
            backend.saveToolTableText(payload.text);
        } else if (id === "view.grid-custom") toolpathPresentation.setChoice("grid", payload.value + "mm");
        else backend.dispatch(id, payload);
    }
    onPopupActiveChanged: if (popupActive) stopJog()
    onBackendChanged: Qt.callLater(syncMachine)
    Connections {
        target: workspace.backend
        function onSnapshotChanged() { workspace.syncMachine(); }
        function onErrorOccurred(message) { workspace.stopJog(); workspace.showBackendFailure("操作失败", message); }
        function onNoticeOccurred(message) { dialogs.openMessage("操作提示", message); }
    }
    Connections {
        target: manualPresentation
        function onControlTabChanged() {
            workspace.stopJog();
            if (workspace.machine.connected)
                workspace.requestCommand("machine.mode", {mode: manualPresentation.controlTab});
        }
    }
    property int programHeight: 184
    property bool initialized: false
    readonly property int maximumProgramHeight: Math.max(90, Math.min(340, panes.height - 247))
    readonly property bool compact: width <= 900
    readonly property int sidebarWidth: compact ? 264 : 296
    readonly property bool viewShortcutsEnabled: !popupActive && !chrome.menuOpen && !editing()

    function editing() {
        let item = focusedItem;
        while (item) {
            if (item instanceof TextInput || item instanceof TextEdit || item instanceof ComboBox)
                return true;
            item = item.parent;
        }
        return false;
    }
    function setProgramHeight(value) {
        programHeight = Math.round(Math.max(90, Math.min(maximumProgramHeight, value)));
    }
    onMaximumProgramHeightChanged: if (initialized) setProgramHeight(programHeight)
    Component.onCompleted: {
        initialized = true;
        setProgramHeight(programHeight);
    }

    ManualState { id: manualPresentation; objectName: "manualState" }
    ToolpathState { id: toolpathPresentation; objectName: "toolpathState" }
    ChromeActions {
        id: chromeActions
        manual: manualPresentation
        preview: toolpathPresentation
        machine: workspace.machine
        program: workspace.program
        recentFiles: workspace.backend ? workspace.backend.recentFiles : []
        onCommandRequested: (actionId, payload) => workspace.requestCommand(actionId, payload)
        onDialogRequested: (actionId, title, axis) => dialogs.openDialog(actionId, title, axis)
    }
    ChromeBar {
        id: chrome
        width: parent.width
        height: 146
        compact: workspace.compact
        actions: chromeActions
        preview: toolpathPresentation
    }
    Item {
        id: panes
        y: 146
        width: parent.width
        height: parent.height - y
        ManualPanel {
            id: manualPanel
            width: workspace.sidebarWidth
            height: parent.height
            presentation: manualPresentation
            machine: workspace.machine
            history: workspace.backend ? workspace.backend.history : []
            onCommandRequested: (actionId, payload) => workspace.requestCommand(actionId, payload)
            onJogStopRequested: workspace.stopJog()
            compact: workspace.compact
            onDialogRequested: (actionId, title, axis) => dialogs.openDialog(actionId, title, axis)
        }
        ToolpathPanel {
            x: workspace.sidebarWidth
            width: parent.width - x
            height: parent.height - workspace.programHeight - 7
            presentation: toolpathPresentation
            machine: workspace.machine
            program: workspace.program
            compact: workspace.width <= 1100
        }
        Rectangle {
            id: sash
            objectName: "programSeparator"
            x: workspace.sidebarWidth
            y: parent.height - workspace.programHeight - height
            width: parent.width - x
            height: 7
            color: Theme.base
            activeFocusOnTab: true
            Accessible.role: Accessible.Grip
            Accessible.name: "调整程序区高度"
            Rectangle { width: parent.width; height: 1; color: Theme.border }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 2
                width: 26
                height: 2
                radius: 2
                color: sashMouse.containsMouse ? Theme.accent : "#41434c"
            }
            Rectangle { anchors.fill: parent; color: "transparent"; border.width: 2; border.color: Theme.accent; visible: sash.activeFocus }
            MouseArea {
                id: sashMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeVerCursor
                preventStealing: true
                onPressed: sash.forceActiveFocus(Qt.MouseFocusReason)
                onPositionChanged: mouse => {
                    if (pressed) {
                        const point = mapToItem(panes, mouse.x, mouse.y);
                        workspace.setProgramHeight(panes.height - point.y);
                    }
                }
            }
            Keys.onUpPressed: workspace.setProgramHeight(workspace.programHeight + 10)
            Keys.onDownPressed: workspace.setProgramHeight(workspace.programHeight - 10)
        }
        ProgramPanel {
            machine: workspace.machine
            program: workspace.program
            onCommandRequested: (actionId, payload) => workspace.requestCommand(actionId, payload)
            x: workspace.sidebarWidth
            y: parent.height - workspace.programHeight
            width: parent.width - x
            height: workspace.programHeight
            onDialogRequested: (actionId, title, axis) => dialogs.openDialog(actionId, title, axis)
        }
    }
    DialogHost {
        id: dialogs
        objectName: "dialogHost"
        machine: workspace.machine
        program: workspace.program
        touchTarget: manualPresentation.touchTarget
        toolTableText: workspace.backend ? workspace.backend.toolTableText : ""
        onSubmitted: (actionId, payload) => workspace.requestCommand(actionId, payload)
    }
    NativeDialogs.FileDialog {
        id: openFile
        objectName: "openProgramDialog"
        title: "打开加工程序"
        nameFilters: ["加工程序 (*.ngc *.nc *.tap)", "所有文件 (*)"]
        fileMode: NativeDialogs.FileDialog.OpenFile
        onAccepted: if (workspace.backend) workspace.backend.openProgram(selectedFile.toString())
    }
    NativeDialogs.FileDialog {
        id: saveFile
        objectName: "saveProgramDialog"
        title: "程序另存为"
        nameFilters: ["加工程序 (*.ngc)", "所有文件 (*)"]
        fileMode: NativeDialogs.FileDialog.SaveFile
        defaultSuffix: "ngc"
        onAccepted: if (workspace.backend && workspace.program)
            workspace.backend.saveProgram(selectedFile.toString(), workspace.program.text)
    }
    Shortcut { sequence: "F3"; enabled: !workspace.popupActive; onActivated: manualPresentation.controlTab = "manual" }
    Shortcut { sequence: "F5"; enabled: !workspace.popupActive; onActivated: manualPresentation.controlTab = "mdi" }
    Repeater {
        model: workspace.configuredAxes
        delegate: Item {
            id: axisShortcut
            required property string modelData
            Shortcut {
                sequence: axisShortcut.modelData
                enabled: workspace.viewShortcutsEnabled
                onActivated: manualPresentation.selectedAxis = axisShortcut.modelData
            }
        }
    }
    Shortcut {
        sequence: "V"
        enabled: workspace.viewShortcutsEnabled
        onActivated: {
            const views = ["p", "z", "z2", "x", "y"];
            toolpathPresentation.setChoice("view", views[(views.indexOf(toolpathPresentation.choices.view) + 1) % views.length]);
        }
    }
    Shortcut { sequence: "D"; enabled: workspace.viewShortcutsEnabled; onActivated: toolpathPresentation.rotate = !toolpathPresentation.rotate }
    Shortcut { sequence: "!"; enabled: workspace.viewShortcutsEnabled; onActivated: toolpathPresentation.setChoice("units", toolpathPresentation.choices.units === "mm" ? "inch" : "mm") }
    Shortcut { sequence: "@"; enabled: workspace.viewShortcutsEnabled; onActivated: toolpathPresentation.setChoice("position", toolpathPresentation.choices.position === "actual" ? "commanded" : "actual") }
    Shortcut { sequence: "#"; enabled: workspace.viewShortcutsEnabled; onActivated: toolpathPresentation.setChoice("coordinates", toolpathPresentation.choices.coordinates === "relative" ? "machine" : "relative") }
    Shortcut { sequence: "F1"; autoRepeat: false; enabled: !!workspace.machine.connected; onActivated: chromeActions.activate("machine.estop") }
    Shortcut { sequence: "F2"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("machine.power") }
    Shortcut { sequence: "O"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("file.open") }
    Shortcut { sequence: "Ctrl+R"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("file.reload") }
    Shortcut { sequence: "Ctrl+S"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("file.save") }
    Shortcut { sequence: "Ctrl+K"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("view.clear") }
    Shortcut { sequence: "R"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("program.run") }
    Shortcut { sequence: "T"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("program.step") }
    Shortcut { sequence: "P"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("program.pause") }
    Shortcut { sequence: "S"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("program.resume") }
    Shortcut { sequence: "Escape"; autoRepeat: false; enabled: !workspace.popupActive && !chrome.menuOpen; onActivated: workspace.requestCommand("program.stop", {}) }
    Shortcut { sequence: "Home"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled && !!workspace.machine.connected; onActivated: manualPresentation.mode === "joint" ? workspace.requestCommand("machine.home", {joint: manualPresentation.selectedJoint}) : chromeActions.activate("machine.home-" + manualPresentation.selectedAxis) }
    Shortcut { sequence: "End"; autoRepeat: false; enabled: workspace.viewShortcutsEnabled; onActivated: chromeActions.activate("machine.touch-off", "工件对刀") }
    Keys.onPressed: event => {
        if (!workspace.viewShortcutsEnabled || manualPresentation.controlTab !== "manual" || event.isAutoRepeat) return;
        const keys = {};
        keys[Qt.Key_Left] = ["X", -1]; keys[Qt.Key_Right] = ["X", 1];
        keys[Qt.Key_Down] = ["Y", -1]; keys[Qt.Key_Up] = ["Y", 1];
        keys[Qt.Key_PageDown] = ["Z", -1]; keys[Qt.Key_PageUp] = ["Z", 1];
        const jointMode = manualPresentation.mode === "joint";
        const jog = jointMode ? (event.key === Qt.Key_Left ? [null, -1] : event.key === Qt.Key_Right ? [null, 1] : null) : keys[event.key];
        if (!jog || (!jointMode && (workspace.machine.axes || []).indexOf(jog[0]) < 0)) return;
        if (jointMode && !Number(workspace.machine.jointCount || (workspace.machine.joints ? workspace.machine.joints.length : 0))) return;
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        workspace.stopJog();
        if (!jointMode) manualPresentation.selectedAxis = jog[0];
        const pressed = {}; pressed[event.key] = true; workspace.activeJogKeys = pressed;
        manualPanel.startJog(jog[1]);
        event.accepted = true;
    }
    Keys.onReleased: event => {
        if (!event.isAutoRepeat && workspace.activeJogKeys[event.key]) {
            workspace.stopJog();
            event.accepted = true;
        }
    }

}
