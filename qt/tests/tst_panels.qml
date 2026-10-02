pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import BetterCnc.Toolpath 1.0
import BetterCnc.Program 1.0

TestCase {
    id: testCase
    name: "PreviewAndProgramIntegration"
    when: windowShown
    visible: true
    width: 1100
    height: 820
    property var fixture

    Component {
        id: fixtureComponent
        Item {
            id: panelFixture
            width: testCase.width
            height: testCase.height
            property alias presentation: presentation
            property alias preview: preview
            property alias program: program
            property alias backend: backend
            property QtObject sharedNotifyProgram: QtObject {
                signal changed()
                property var lines: ["G1 X10 F100"]
                property var segments: [{type: "feed", start: [0, 0, 0], end: [10, 0, 0], line: 1}]
                property var bounds: ({min: [0, 0, 0], max: [10, 20, 5]})
                property int selectedLine: 0
                property bool previewBusy: false
                property string previewError: ""
                property var previewWarnings: []
            }
            FakeBackend { id: backend }
            ToolpathState { id: presentation }
            ToolpathPanel {
                id: preview
                x: panelFixture.width <= 900 ? 264 : 296
                y: 146
                width: panelFixture.width - x
                height: panelFixture.height - 337
                compact: panelFixture.width <= 1100
                presentation: panelFixture.presentation
                machine: backend.snapshot
                program: backend.program
            }
            ProgramPanel {
                id: program
                x: preview.x
                y: panelFixture.height - 184
                width: preview.width
                height: 184
                machine: backend.snapshot
                program: backend.program
            }
        }
    }
    SignalSpy { id: canvasPainted; signalName: "painted" }
    SignalSpy { id: overlayPainted; signalName: "painted" }
    SignalSpy { id: commandRequested; signalName: "commandRequested" }

    function control(name) {
        const item = findChild(fixture, name);
        verify(item !== null, "Missing public UI: " + name);
        return item;
    }
    function init() {
        width = 1100;
        height = 820;
        fixture = createTemporaryObject(fixtureComponent, testCase);
        verify(fixture !== null);
        canvasPainted.target = control("toolpathCanvas");
        overlayPainted.target = control("toolpathLiveOverlay");
        commandRequested.target = fixture.program;
        commandRequested.clear();
        fixture.backend.program.segments = [
            {type: "rapid", start: [0, 0, 0], end: [10, 0, 5], line: 2},
            {type: "feed", start: [10, 0, 5], end: [10, 20, 0], line: 3},
            {type: "feed", start: [10, 20, 0], end: [0, 0, 0], line: 4}
        ];
        fixture.backend.program.bounds = {min: [0, 0, 0], max: [10, 20, 5]};
        fixture.backend.update({
            actualPosition: [5, 5, 2, 0, 0, 0, 0, 0, 0],
            commandedPosition: [5, 5, 2, 0, 0, 0, 0, 0, 0], g5xIndex: 1,
            axisLimits: {X: {min: 0, max: 12}, Y: {min: 0, max: 22}, Z: {min: 0, max: 7}},
            capabilities: {"program.run-line": true}
        });
        renderedCanvas();
        fixture.backend.update({actualPosition: [6, 7, 2, 0, 0, 0, 0, 0, 0]});
        renderedCanvas();
    }
    function cleanup() {
        canvasPainted.target = null;
        overlayPainted.target = null;
        commandRequested.target = null;
    }
    function renderedCanvas() {
        canvasPainted.clear();
        overlayPainted.clear();
        control("toolpathCanvas").requestPaint();
        control("toolpathLiveOverlay").requestPaint();
        tryVerify(() => canvasPainted.count > 0 && overlayPainted.count > 0,
                  3000, "Both geometry and live overlay must finish painting");
        // Capture the root scene to include nested clipping and both canvases.
        return grabImage(fixture);
    }
    function test_projectionAndZoomChangeRendering() {
        let previous = renderedCanvas();
        for (const view of ["z", "z2", "x", "y", "p"]) {
            fixture.presentation.setChoice("view", view);
            const current = renderedCanvas();
            verify(!previous.equals(current), "Projection " + view + " must change the drawn geometry");
            previous = current;
        }
        fixture.presentation.zoomBy(1.25);
        verify(!previous.equals(renderedCanvas()), "Zoom must change the drawn geometry");
        compare(control("previewCaption").text, "透视图 · 125%");
        fixture.presentation.zoomBy(100);
        compare(control("previewCaption").text, "透视图 · 200%");
        fixture.presentation.zoomBy(0.001);
        compare(control("previewCaption").text, "透视图 · 50%");
    }
    function test_displayLayersChangeRendering_data() {
        return ["show.program", "show.rapids", "show.alpha", "show.live", "show.tool",
                "show.extents", "show.offsets", "show.limits"].map(flag => ({tag: flag, flag: flag}));
    }
    function test_displayLayersChangeRendering(data) {
        const previous = renderedCanvas();
        fixture.presentation.toggleFlag(data.flag);
        verify(!previous.equals(renderedCanvas()), data.flag + " must change the preview");
    }
    function test_gridChangesRendering() {
        const previous = renderedCanvas();
        fixture.presentation.setChoice("grid", "5");
        verify(!previous.equals(renderedCanvas()), "Enabling the grid must draw grid lines");
    }
    function test_geometryAndPreviewStatusComeFromProgram() {
        failOnWarning(/Context2D: The font families specified are invalid:.*/);
        const previous = renderedCanvas();
        fixture.backend.program.segments = [
            {type: "feed", start: [0, 0, 0], end: [10, 20, 5], line: 3}
        ];
        verify(!previous.equals(renderedCanvas()), "Replacing real segments must replace the drawing");
        fixture.backend.program.previewBusy = true;
        compare(control("previewStatus").text, "正在解释程序…");
        fixture.backend.program.previewBusy = false;
        fixture.backend.program.previewError = "第 4 行：无效的 G 代码";
        compare(control("previewStatus").text, "预览失败：第 4 行：无效的 G 代码");
    }
    function test_sharedDocumentNotificationUpdatesGeometryAndWarnings() {
        fixture.preview.program = fixture.sharedNotifyProgram;
        const previous = renderedCanvas();
        fixture.sharedNotifyProgram.segments.push({type: "feed", start: [10, 0, 0], end: [10, 20, 5], line: 1});
        fixture.sharedNotifyProgram.changed();
        verify(!previous.equals(renderedCanvas()), "A document's shared notify signal must update geometry");
        fixture.sharedNotifyProgram.previewWarnings = ["首段起点未知，未绘制首段。"];
        compare(control("previewWarning").visible, true);
        compare(control("previewWarning").text, "首段起点未知，未绘制首段。");
    }
    function test_rotaryReadoutUsesDegreesWithoutLengthConversion() {
        fixture.backend.update({axes: ["X", "A"], angularUnits: Math.PI / 180,
            actualPosition: [6, 7, 2, Math.PI, 0, 0, 0, 0, 0]});
        compare(control("coordinateA").text, "180.000");
        fixture.presentation.setChoice("units", "inch");
        compare(control("coordinateA").text, "180.000");
        compare(control("coordinateX").text, "0.2362");
    }
    function test_offlineDefaultsDoNotInventCoordinatesOrProgram() {
        fixture.preview.machine = null;
        fixture.preview.program = null;
        fixture.program.machine = null;
        fixture.program.program = null;
        compare(control("coordinateUnavailable").visible, true);
        compare(control("previewStatus").text, "尚未加载加工程序");
        compare(control("emptyProgramMessage").visible, true);
        compare(control("programLines").count, 0);
        compare(control("runFromLineAction").enabled, false);
    }
    function test_coordinatesApplyOffsetsRotationUnitsAndPositionSource() {
        fixture.backend.update({
            actualPosition: [100, 200, 30, 0, 0, 0, 0, 0, 0],
            commandedPosition: [110, 220, 35, 0, 0, 0, 0, 0, 0],
            toolOffset: [1, 2, 3, 0, 0, 0, 0, 0, 0],
            g5xOffset: [10, 20, 2, 0, 0, 0, 0, 0, 0],
            g92Offset: [4, 5, 6, 0, 0, 0, 0, 0, 0], rotationXY: 90
        });
        compare(control("coordinateX").text, "174.000");
        compare(control("coordinateY").text, "-94.000");
        compare(control("coordinateZ").text, "19.000");
        fixture.presentation.setChoice("position", "commanded");
        compare(control("coordinateX").text, "194.000");
        fixture.presentation.setChoice("coordinates", "machine");
        compare(control("coordinateX").text, "110.000");
        fixture.presentation.setChoice("units", "inch");
        compare(control("coordinateX").text, "4.3307");
        fixture.backend.update({connected: false});
        compare(control("coordinateX").text, "—");
    }
    function test_liveUpdatesAndClearDoNotRedrawProgramGeometry() {
        const previous = renderedCanvas();
        canvasPainted.clear();
        overlayPainted.clear();
        fixture.backend.update({actualPosition: [7, 8, 2, 0, 0, 0, 0, 0, 0], currentLine: 3});
        tryVerify(() => overlayPainted.count > 0);
        compare(canvasPainted.count, 0, "Status updates must only redraw the lightweight overlay");
        verify(!previous.equals(grabImage(fixture)), "Observed tool movement and execution line must update");
        fixture.presentation.setFlag("show.tool", false);
        const withLive = renderedCanvas();
        fixture.presentation.clearLive();
        verify(!withLive.equals(renderedCanvas()), "Clear live removes observed movement");
        compare(fixture.presentation.flags["show.live"], true);
    }
    function test_tabsReadoutsAndUnits() {
        fixture.presentation.setChoice("units", "inch");
        compare(control("coordinateX").text, "0.2362");
        fixture.presentation.setFlag("show.velocity", false);
        compare(control("velocityReadout").visible, false);
        fixture.presentation.setFlag("show.offsets", true);
        compare(control("offsetReadout").visible, true);
        mouseClick(control("droTab"));
        compare(control("droPanel").visible, true);
        compare(control("toolpathCanvas").visible, false);
        compare(control("droCoordinateX").text, "0.2362");
        fixture.presentation.setFlag("show.large", true);
        compare(control("droCoordinateX").font.pixelSize, 46);
        fixture.presentation.setChoice("units", "mm");
        compare(control("droCoordinateX").text, "6.000");
        keyClick(Qt.Key_Left);
        compare(control("toolpathCanvas").visible, true);
        compare(control("droPanel").visible, false);
    }
    function test_programSelectionAndContextAction() {
        mouseClick(fixture.program, 200, 80);
        compare(control("programLine1").Accessible.selected, true);
        keyClick(Qt.Key_Down);
        compare(control("programLine2").Accessible.selected, true);
        compare(control("programLine1").Accessible.selected, false);
        keyClick(Qt.Key_Up);
        compare(control("programLine1").Accessible.selected, true);
        mouseClick(fixture.program, 200, 80, Qt.RightButton);
        tryCompare(control("programContextMenu"), "visible", true);
        mouseClick(control("runFromLineAction"));
        tryCompare(commandRequested, "count", 1);
        compare(commandRequested.signalArguments[0][0], "program.run-line");
        compare(commandRequested.signalArguments[0][1].line, 2);
        fixture.backend.update({currentLine: 3});
        compare(fixture.program.executingLine, 3);
        compare(fixture.backend.program.selectedLine, 2);
        fixture.backend.update({capabilities: {}});
        compare(control("runFromLineAction").enabled, false);
    }
    function test_smallWindowKeepsPreviewVisible() {
        width = 760;
        height = 640;
        tryCompare(fixture.preview, "width", 496);
        const image = renderedCanvas();
        compare(image.width, 760);
        compare(image.height, 640);
        verify(control("toolpathCanvas").height > 100);
        compare(control("coordinateZ").visible, true);
        image.save("preview-minimum.png");
    }
    function test_smallWindowReadoutsWrapWithoutClipping() {
        width = 760;
        height = 640;
        fixture.presentation.setFlag("show.large", true);
        fixture.presentation.setFlag("show.dtg", true);
        fixture.presentation.setFlag("show.offsets", true);
        fixture.presentation.setChoice("units", "inch");
        renderedCanvas();
        for (const axis of ["X", "Y", "Z"]) {
            for (const prefix of ["coordinate", "distanceToGo"]) {
                const reading = control(prefix + axis);
                verify(reading.visible);
                const position = reading.mapToItem(fixture.preview, 0, 0);
                verify(position.x >= 0 && position.x + reading.width <= fixture.preview.width,
                       prefix + axis + " must fit without horizontal clipping");
                verify(position.y >= 44 && position.y + reading.height <= fixture.preview.height,
                       prefix + axis + " must fit below the tabs");
            }
        }
    }
}
