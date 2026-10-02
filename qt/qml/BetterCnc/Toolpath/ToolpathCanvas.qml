import QtQuick
import BetterCnc.Ui 1.0
import "Coordinates.js" as Coordinates

// Geometry is received once per interpreted program. Status updates redraw only
// the lightweight overlay; they never copy/rebuild the full segment collection.
Canvas {
    id: root
    required property ToolpathState presentation
    property var machine: null
    property var program: null
    objectName: "toolpathCanvas"
    Accessible.role: Accessible.Graphic
    Accessible.name: "RS274 程序刀路预览；不是材料去除仿真"
    renderTarget: Canvas.Image
    property var geometry: []
    property var geometryBounds: ({min: [-25, -25, -25], max: [25, 25, 25]})
    property var segmentsByLine: ({})
    property var livePoints: []
    property real yaw: 0
    property real pitch: 0
    readonly property var viewport: frame()

    function syncProgram() {
        geometry = program && program.segments ? program.segments : [];
        syncBounds();
        const byLine = {};
        for (let i = 0; i < geometry.length; ++i) {
            const segment = geometry[i];
            if (!byLine[segment.line]) byLine[segment.line] = [];
            byLine[segment.line].push(segment);
        }
        segmentsByLine = byLine;
        requestPaint();
        overlay.requestPaint();
    }
    function syncBounds() {
        const bounds = program ? program.bounds : null;
        geometryBounds = bounds && bounds.min && bounds.min.length === 3 && bounds.max && bounds.max.length === 3
                ? bounds : ({min: [-25, -25, -25], max: [25, 25, 25]});
    }
    function observePosition() {
        const point = Coordinates.tip(machine);
        if (point) {
            const previous = livePoints.length ? livePoints[livePoints.length - 1] : null;
            if (!previous || point.some((value, i) => Math.abs(value - previous[i]) > 0.001)) {
                livePoints.push(point);
                if (livePoints.length > 5000) livePoints.shift();
            }
        } else if (livePoints.length) {
            // A reconnect must not draw a fictitious connecting movement.
            livePoints = [];
        }
        overlay.requestPaint();
    }
    function projected(point) {
        let x = point[0], y = point[1], z = point[2];
        if (yaw || pitch) {
            const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
            const rx = x * cy - y * sy, ry = x * sy + y * cy;
            x = rx; y = ry * cp - z * sp; z = ry * sp + z * cp;
        }
        switch (presentation.choices.view) {
        case "z": return [x, -y];
        case "z2": return [0.86 * x + 0.32 * y, 0.32 * x - 0.86 * y];
        case "x": return [y, -z];
        case "y": return [x, -z];
        default: return [0.94 * x - 0.52 * y, 0.30 * x + 0.78 * y - 0.9 * z];
        }
    }
    function frame() {
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        for (let i = 0; i < 8; ++i) {
            const point = projected([geometryBounds[(i & 1) ? "max" : "min"][0],
                                     geometryBounds[(i & 2) ? "max" : "min"][1],
                                     geometryBounds[(i & 4) ? "max" : "min"][2]]);
            minX = Math.min(minX, point[0]); maxX = Math.max(maxX, point[0]);
            minY = Math.min(minY, point[1]); maxY = Math.max(maxY, point[1]);
        }
        const scale = Math.max(0.01, Math.min(Math.max(1, width - 90) / Math.max(1, maxX - minX),
                                            Math.max(1, height - 90) / Math.max(1, maxY - minY))) * presentation.zoom;
        return {scale: scale, x: width / 2 - (minX + maxX) / 2 * scale,
                y: height / 2 - (minY + maxY) / 2 * scale};
    }
    function screen(point) {
        const p = projected(point);
        return [p[0] * viewport.scale + viewport.x, p[1] * viewport.scale + viewport.y];
    }
    function line(ctx, start, end) {
        const a = screen(start), b = screen(end);
        ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]);
    }
    function box(ctx, low, high) {
        const corners = [];
        for (let i = 0; i < 8; ++i)
            corners.push([(i & 1) ? high[0] : low[0], (i & 2) ? high[1] : low[1], (i & 4) ? high[2] : low[2]]);
        ctx.beginPath();
        for (let vertex = 0; vertex < 8; ++vertex)
            for (let bit = 1; bit <= 4; bit *= 2)
                if (!(vertex & bit)) line(ctx, corners[vertex], corners[vertex | bit]);
        ctx.stroke();
    }
    onProgramChanged: syncProgram()
    onMachineChanged: observePosition()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onViewportChanged: { requestPaint(); overlay.requestPaint(); }
    onVisibleChanged: if (visible) { requestPaint(); overlay.requestPaint(); }
    Component.onCompleted: { syncProgram(); observePosition(); }
    Connections {
        target: root.program
        ignoreUnknownSignals: true
        function onSegmentsChanged() { root.syncProgram(); }
        function onBoundsChanged() { root.syncBounds(); }
        // The Python document shares one notify signal for its geometry fields.
        function onChanged() { root.syncProgram(); }
        function onSelectedLineChanged() { overlay.requestPaint(); }
    }
    Connections {
        target: root.presentation
        function onChoicesChanged() { root.requestPaint(); overlay.requestPaint(); }
        function onFlagsChanged() { root.requestPaint(); overlay.requestPaint(); }
        function onLiveResetRevisionChanged() { root.livePoints = []; overlay.requestPaint(); }
    }
    onPaint: {
        if (width <= 0 || height <= 0) return;
        const ctx = getContext("2d");
        ctx.reset();
        const backdrop = ctx.createRadialGradient(width / 2, height * 0.4, 0,
                                                  width / 2, height * 0.4, Math.max(width, height) * 0.7);
        backdrop.addColorStop(0, "#212229"); backdrop.addColorStop(1, "#17181b");
        ctx.fillStyle = backdrop; ctx.fillRect(0, 0, width, height);
        if (presentation.choices.grid !== "off") {
            let spacing = parseFloat(presentation.choices.grid);
            if (String(presentation.choices.grid).indexOf("in") >= 0) spacing *= 25.4;
            if (spacing > 0) {
                const low = geometryBounds.min, high = geometryBounds.max;
                // A user-defined tiny grid must not freeze the UI.
                const count = Math.max((high[0] - low[0]) / spacing, (high[1] - low[1]) / spacing);
                if (count > 200) spacing *= Math.ceil(count / 200);
                ctx.strokeStyle = "#244242"; ctx.lineWidth = 0.7; ctx.beginPath();
                for (let x = Math.floor(low[0] / spacing) * spacing; x <= high[0] + spacing; x += spacing)
                    line(ctx, [x, low[1], 0], [x, high[1], 0]);
                for (let y = Math.floor(low[1] / spacing) * spacing; y <= high[1] + spacing; y += spacing)
                    line(ctx, [low[0], y, 0], [high[0], y, 0]);
                ctx.stroke();
            }
        }
        if (geometry.length && presentation.flags["show.program"]) {
            ctx.globalAlpha = presentation.flags["show.alpha"] ? 0.55 : 1;
            for (const kind of ["rapid", "feed"]) {
                if (kind === "rapid" && !presentation.flags["show.rapids"]) continue;
                ctx.strokeStyle = kind === "rapid" ? "#7977b7" : "#b2b9e8";
                ctx.lineWidth = kind === "rapid" ? 0.8 : 1.1;
                ctx.setLineDash(kind === "rapid" ? [4, 4] : []);
                ctx.beginPath();
                for (let i = 0; i < geometry.length; ++i)
                    if (geometry[i].type === kind) line(ctx, geometry[i].start, geometry[i].end);
                ctx.stroke();
            }
            ctx.globalAlpha = 1;
        }
        ctx.setLineDash([]);
        if (geometry.length && presentation.flags["show.extents"]) {
            ctx.strokeStyle = "#626579"; ctx.lineWidth = 0.7;
            box(ctx, geometryBounds.min, geometryBounds.max);
            ctx.fillStyle = "#a0a2b5"; ctx.font = "11px '" + Theme.mono + "'";
            const divisor = presentation.choices.units === "inch" ? 25.4 : 1;
            const dimensions = geometryBounds.max.map((v, i) => ((v - geometryBounds.min[i]) / divisor).toFixed(3));
            ctx.fillText(dimensions.join(" × ") + (divisor === 1 ? " mm" : " in"), 20, height - 15);
        }
        // Coordinate axes remain a frame reference when no program is loaded.
        ctx.lineWidth = 1.2;
        const origin = [38, height - 38];
        for (const axis of [{to: [29, 10], color: "#de6b64", label: "X"},
                            {to: [-13, 18], color: "#68b576", label: "Y"},
                            {to: [0, -30], color: "#799dce", label: "Z"}]) {
            ctx.strokeStyle = axis.color; ctx.fillStyle = axis.color;
            ctx.beginPath(); ctx.moveTo(origin[0], origin[1]);
            ctx.lineTo(origin[0] + axis.to[0], origin[1] + axis.to[1]); ctx.stroke();
            ctx.font = "11px '" + Theme.mono + "'";
            ctx.fillText(axis.label, origin[0] + axis.to[0] + 3, origin[1] + axis.to[1] - 3);
        }
    }
    Canvas {
        id: overlay
        objectName: "toolpathLiveOverlay"
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d"); ctx.reset();
            if (!root.machine || !root.machine.connected) return;
            if (root.presentation.flags["show.limits"] && root.machine.axisLimits && root.machine.linearUnits > 0) {
                const limits = root.machine.axisLimits;
                if (["X", "Y", "Z"].every(a => limits[a] && limits[a].min !== null && limits[a].max !== null)) {
                    ctx.strokeStyle = "#6b7278"; ctx.lineWidth = 1; ctx.setLineDash([5, 5]);
                    root.box(ctx, ["X", "Y", "Z"].map(a => limits[a].min / root.machine.linearUnits),
                             ["X", "Y", "Z"].map(a => limits[a].max / root.machine.linearUnits));
                    ctx.setLineDash([]);
                }
            }
            if (root.presentation.flags["show.live"] && root.livePoints.length > 1) {
                ctx.strokeStyle = "#a74949"; ctx.lineWidth = 1.2; ctx.beginPath();
                for (let i = 1; i < root.livePoints.length; ++i) root.line(ctx, root.livePoints[i - 1], root.livePoints[i]);
                ctx.stroke();
            }
            for (const selection of [{line: root.machine.currentLine, color: "#72d39d"},
                                     {line: root.program ? root.program.selectedLine : 0, color: "#d9d4ff"}]) {
                const segments = root.segmentsByLine[selection.line] || [];
                ctx.strokeStyle = selection.color; ctx.lineWidth = 2; ctx.beginPath();
                for (let j = 0; j < segments.length; ++j) root.line(ctx, segments[j].start, segments[j].end);
                ctx.stroke();
            }
            if (root.presentation.flags["show.offsets"]) {
                const work = Coordinates.vector(root.machine, "g5xOffset");
                if (work && root.machine.linearUnits > 0) {
                    const p = root.screen(work.slice(0, 3).map(v => v / root.machine.linearUnits));
                    ctx.strokeStyle = "#7c76dd"; ctx.lineWidth = 1;
                    ctx.beginPath(); ctx.moveTo(p[0] - 9, p[1]); ctx.lineTo(p[0] + 9, p[1]);
                    ctx.moveTo(p[0], p[1] - 9); ctx.lineTo(p[0], p[1] + 9); ctx.stroke();
                    ctx.font = "11px '" + Theme.fontFamily + "'"; ctx.fillStyle = "#aaa6ef";
                    ctx.fillText(Coordinates.workLabel(root.machine), p[0] + 6, p[1] - 12);
                }
            }
            const tip = Coordinates.tip(root.machine);
            if (tip && root.presentation.flags["show.tool"]) {
                const p = root.screen(tip);
                ctx.beginPath(); ctx.moveTo(p[0] - 7, p[1] - 24); ctx.lineTo(p[0] + 7, p[1] - 24);
                ctx.lineTo(p[0], p[1]); ctx.closePath();
                ctx.fillStyle = "rgba(148,160,165,0.6)"; ctx.fill();
                ctx.strokeStyle = "#9aadb5"; ctx.lineWidth = 0.8; ctx.stroke();
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        property real lastX: 0
        property real lastY: 0
        cursorShape: root.presentation.rotate ? Qt.OpenHandCursor : Qt.ArrowCursor
        onPressed: mouse => { lastX = mouse.x; lastY = mouse.y; }
        onPositionChanged: mouse => {
            if (pressed && root.presentation.rotate) {
                root.yaw += (mouse.x - lastX) / 150;
                root.pitch += (mouse.y - lastY) / 150;
                lastX = mouse.x; lastY = mouse.y;
            }
        }
        onWheel: wheel => { root.presentation.zoomBy(wheel.angleDelta.y > 0 ? 1.1 : 1 / 1.1); wheel.accepted = true; }
    }
}
