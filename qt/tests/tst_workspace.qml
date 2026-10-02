import QtQuick
import QtTest
import "../qml" as App

TestCase {
    id: testCase
    name: "WorkspaceController"
    when: windowShown
    width: 1100
    height: 820
    property var window
    property var backend
    Component { id: appComponent; App.Main { } }
    Component { id: backendComponent; FakeBackend { } }

    function visualChild(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = visualChild(child, name);
            if (found) return found;
        }
        return null;
    }
    function control(name) {
        const result = findChild(window, name) || visualChild(window.contentItem, name);
        verify(result !== null, "Missing public UI: " + name);
        return result;
    }
    function init() {
        backend = createTemporaryObject(backendComponent, null);
        window = createTemporaryObject(appComponent, null, {backend: backend});
        verify(window !== null);
        window.requestActivate();
        waitForRendering(window.contentItem);
    }
    function cleanup() { if (window) window.close(); }
    function click(name) {
        const item = control(name);
        mouseClick(item, item.width / 2, item.height / 2);
    }
    function lastRequest() { return backend.requests[backend.requests.length - 1]; }
    function test_initialLayoutAndRealProgram() {
        compare(control("workspace").width, 1100);
        compare(control("manualPanel").width, 296);
        compare(control("programSeparator").height, 7);
        compare(control("mdiTab").text, "手动输入 [F5]");
        compare(window.title, "test.ngc — BetterLinuxCNC");
        verify(!control("dialogHost").visible);
        compare(control("feedOverride").value, 100);
    }
    function test_disconnectedDisablesMachineActions() {
        backend.update({connected: false, axes: [], powered: false, message: "控制器不可用"});
        tryCompare(control("jogPlus"), "enabled", false);
        compare(control("toolbar-machine.estop").enabled, false);
        compare(control("homeAll").enabled, false);
        compare(control("mistCoolant").enabled, false);
        tryCompare(control("dialogHost"), "visible", true);
        compare(control("dialogHost").description, "控制器不可用");
        keyClick(Qt.Key_Escape);
        const before = backend.requests.length;
        keyClick(Qt.Key_R);
        compare(backend.requests.length, before);
    }
    function test_unknownOverrideValuesAreNotPresentedAsZero_data() {
        return [
            {tag: "feed", name: "feedOverride", value: 1, displayed: "100"},
            {tag: "rapid", name: "rapidOverride", value: 0.25, displayed: "25"},
            {tag: "spindle", name: "spindleOverride", value: 1.1, displayed: "110"},
            {tag: "maximum-velocity", name: "maxVelocity", value: 2, displayed: "120"}
        ];
    }
    function test_unknownOverrideValuesAreNotPresentedAsZero(data) {
        const field = control(data.name + ".value");
        const slider = control(data.name + ".slider");
        let values = {};
        values[data.name] = 0;
        backend.update(values);
        compare(field.text, "0");
        values[data.name] = null;
        backend.update(values);
        compare(field.text, "—");
        verify(!slider.enabled);
        values[data.name] = undefined;
        backend.update(values);
        compare(field.text, "—");
        verify(!slider.enabled);
        values[data.name] = data.value;
        values.connected = false;
        backend.update(values);
        compare(field.text, "—");
        verify(!slider.enabled);
        values.connected = true;
        backend.update(values);
        compare(field.text, data.displayed);
        verify(slider.enabled);
    }
    function test_connectingDoesNotReportFailure() {
        backend.update({connected: false, connecting: true, message: "正在连接"});
        verify(!control("dialogHost").visible);
        compare(control("jogPlus").enabled, false);
        backend.update({connecting: false, message: "socket 不可用"});
        tryCompare(control("dialogHost"), "visible", true);
        compare(control("dialogHost").description, "socket 不可用");
    }
    function test_mdiAndHistory() {
        keyClick(Qt.Key_F5);
        compare(lastRequest().id, "machine.mode");
        compare(lastRequest().payload.mode, "mdi");
        waitForRendering(control("mdiHistory"));
        click("mdiHistory1");
        compare(control("mdiCommand").text, "G0 Z10");
        click("mdiExecute");
        compare(lastRequest().id, "mdi.execute");
        compare(lastRequest().payload.text, "G0 Z10");
        verify(!control("dialogHost").visible);
    }
    function test_machineChecksWaitForSnapshot() {
        const item = control("mistCoolant");
        compare(item.checked, false);
        click("mistCoolant");
        compare(lastRequest().id, "coolant.mist");
        compare(lastRequest().payload.enabled, true);
        compare(item.checked, false);
        backend.update({mist: true});
        tryCompare(item, "checked", true);
    }
    function test_jogPressReleaseAndStateLoss() {
        click("axisY");
        const plus = control("jogPlus");
        mousePress(plus, plus.width / 2, plus.height / 2);
        compare(lastRequest().id, "jog.start");
        compare(lastRequest().payload.axis, "Y");
        compare(lastRequest().payload.direction, 1);
        compare(lastRequest().payload.velocity, control("manualState").jogVelocity / 60);
        compare(lastRequest().payload.increment, 0);
        const stops = backend.stopCount;
        mouseRelease(plus, plus.width / 2, plus.height / 2);
        verify(backend.stopCount > stops);
        mousePress(plus, plus.width / 2, plus.height / 2);
        const interrupted = backend.stopCount;
        backend.update({estop: true, powered: false});
        tryVerify(() => backend.stopCount > interrupted);
        mouseRelease(plus, plus.width / 2, plus.height / 2);
    }
    function test_acceptedJogKeepsReleaseAvailable() {
        const plus = control("jogPlus");
        mousePress(plus, plus.width / 2, plus.height / 2);
        compare(lastRequest().id, "jog.start");
        const stops = backend.stopCount;
        backend.update({busy: true, capabilities: {"jog.start": false}});
        waitForRendering(plus);
        compare(backend.stopCount, stops);
        verify(plus.down);
        verify(plus.enabled);
        mouseRelease(plus, plus.width / 2, plus.height / 2);
        verify(backend.stopCount > stops);
        verify(!plus.enabled);
    }
    function test_ownedJogStopsOnControllerModeChange() {
        const plus = control("jogPlus");
        mousePress(plus, plus.width / 2, plus.height / 2);
        backend.update({capabilities: {"jog.start": false}});
        const stops = backend.stopCount;
        backend.update({mode: "auto"});
        tryVerify(() => backend.stopCount > stops);
        verify(!plus.enabled);
        mouseRelease(plus, plus.width / 2, plus.height / 2);
    }
    function test_jogKeyboardReleaseAndFocusLoss() {
        const workspace = control("workspace");
        workspace.forceActiveFocus();
        keyPress(Qt.Key_Right);
        compare(lastRequest().id, "jog.start");
        compare(lastRequest().payload.axis, "X");
        const stops = backend.stopCount;
        keyRelease(Qt.Key_Right);
        verify(backend.stopCount > stops);
        workspace.forceActiveFocus();
        keyPress(Qt.Key_Left);
        const focusStops = backend.stopCount;
        control("manualTab").forceActiveFocus();
        tryVerify(() => backend.stopCount > focusStops);
        keyRelease(Qt.Key_Left);
    }
    function test_jogIncrementAndInterruption() {
        const increment = control("jogIncrement");
        increment.forceActiveFocus();
        keyClick(Qt.Key_Down);
        compare(control("manualState").jogIncrement, 0.1);
        const plus = control("jogPlus");
        mousePress(plus, plus.width / 2, plus.height / 2);
        compare(lastRequest().payload.increment, 0.1);
        const beforeTab = backend.stopCount;
        keyClick(Qt.Key_F5);
        tryVerify(() => backend.stopCount > beforeTab);
        mouseRelease(plus, plus.width / 2, plus.height / 2);
        keyClick(Qt.Key_F3);
        waitForRendering(window.contentItem);
        mousePress(plus, plus.width / 2, plus.height / 2);
        const beforeDialog = backend.stopCount;
        backend.noticeOccurred("操作提示");
        tryVerify(() => backend.stopCount > beforeDialog);
        verify(control("dialogHost").visible);
        mouseRelease(plus, plus.width / 2, plus.height / 2);
    }
    function test_jointJogDoesNotInferAxisMapping() {
        backend.update({motionMode: "joint", jointCount: 4, joints: [0, 1, 2, 3]});
        waitForRendering(window.contentItem);
        click("joint3");
        compare(control("manualState").selectedJoint, 3);
        const plus = control("jogPlus");
        mousePress(plus, plus.width / 2, plus.height / 2);
        compare(lastRequest().id, "jog.start");
        compare(lastRequest().payload.axis, 3);
        compare(lastRequest().payload.mode, "joint");
        mouseRelease(plus, plus.width / 2, plus.height / 2);
        verify(!control("workTouchOff").enabled);
        control("workspace").forceActiveFocus();
        keyClick(Qt.Key_Home);
        compare(lastRequest().id, "machine.home");
        compare(lastRequest().payload.joint, 3);
        keyPress(Qt.Key_Left);
        compare(lastRequest().id, "jog.start");
        compare(lastRequest().payload.axis, 3);
        keyRelease(Qt.Key_Left);
    }
    function test_offsetSubmission() {
        click("axisY");
        click("workTouchOff");
        const dialog = control("dialogHost");
        tryCompare(dialog, "opened", true);
        // The Loader and ColumnLayout publish final button positions on the next frame.
        verify(waitForRendering(dialog.contentItem));
        compare(dialog.axis, "Y");
        const field = control("touch-value");
        field.forceActiveFocus(); field.selectAll();
        keyClick(Qt.Key_1); keyClick(Qt.Key_2); keyClick(Qt.Key_Period); keyClick(Qt.Key_5);
        compare(dialog.value, "12.5");
        const before = backend.requests.length;
        click("dialog-submit");
        compare(backend.requests.length, before + 1);
        compare(lastRequest().id, "machine.touch-off");
        compare(lastRequest().payload.value, 12.5);
        compare(lastRequest().payload.axis, "Y");
        compare(lastRequest().payload.system, "G54");
        verify(!dialog.visible);
    }
    function test_overridesOnlySendUserMoves() {
        const before = backend.requests.length;
        backend.update({feedOverride: 0.8});
        tryCompare(control("feedOverride"), "value", 80);
        compare(backend.requests.length, before);
        const slider = control("feedOverride.slider");
        slider.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(lastRequest().id, "override.feed");
        fuzzyCompare(lastRequest().payload.value, 0.81, 0.001);
        compare(backend.snapshot.feedOverride, 0.8);
        backend.update({feedOverride: 0.75});
        tryCompare(control("feedOverride"), "value", 75);
    }
    function test_splitterAndSmallWindowReachability() {
        const sash = control("programSeparator");
        const workspace = control("workspace");
        sash.forceActiveFocus(); keyClick(Qt.Key_Up);
        compare(workspace.programHeight, 194);
        window.width = 760; window.height = 640;
        tryCompare(control("manualPanel"), "width", 264);
        waitForRendering(window.contentItem);
        const slider = control("maxVelocity.slider");
        const scroller = control("manualScroller");
        slider.forceActiveFocus(Qt.TabFocusReason);
        tryVerify(() => slider.mapToItem(scroller, 0, 0).y >= 0);
        tryVerify(() => slider.mapToItem(scroller, 0, slider.height).y <= scroller.height);
        keyClick(Qt.Key_Left);
        compare(lastRequest().id, "velocity.max");
    }
    function test_shortcutsAreIsolatedFromEditing() {
        keyClick(Qt.Key_F5);
        const input = control("mdiCommand");
        input.forceActiveFocus();
        const before = backend.requests.length;
        keyClick(Qt.Key_R); keyClick(Qt.Key_T); keyClick(Qt.Key_P); keyClick(Qt.Key_S);
        compare(input.text.toLowerCase(), "rtps");
        compare(backend.requests.length, before);
        keyClick(Qt.Key_F1);
        compare(lastRequest().id, "machine.estop");
    }
    function test_backendErrorIsPresented() {
        backend.errorOccurred("当前状态不允许执行此指令");
        const dialog = control("dialogHost");
        tryCompare(dialog, "visible", true);
        compare(dialog.description, "当前状态不允许执行此指令");
    }
}
