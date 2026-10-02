import QtQuick
import BetterCnc.Catalog 1.0
import BetterCnc.Manual 1.0
import BetterCnc.Toolpath 1.0

// Compose public presentation APIs; controller commands leave through one signal.
QtObject {
    id: root
    required property ManualState manual
    required property ToolpathState preview
    property var machine: ({})
    property var program: null
    property var recentFiles: []
    signal dialogRequested(string actionId, string title, string axis)
    signal commandRequested(string actionId, var payload)

    // Keep menu objects stable while position/status snapshots arrive.
    readonly property string menuAxesKey: (machine.axes || []).join(",")
    readonly property string menuJointsKey: (Array.isArray(machine.joints) ? machine.joints
        : Array.from({length: Number(machine.jointCount || 0)}, (_, index) => index)).join(",")
    readonly property string menuMotionMode: machine.motionMode || ""
    readonly property string recentFilesKey: JSON.stringify(recentFiles)
    readonly property var menus: Catalog.menus.map(menu => {
        if (menu.id === "machine") return Object.assign({}, menu, {children: menu.children.map(entry => {
            if (entry.id !== "machine.homing" && entry.id !== "machine.unhoming") return entry;
            const operation = entry.id === "machine.homing" ? "home" : "unhome";
            const label = operation === "home" ? "回零" : "清除回零状态";
            const children = [{id: "machine." + operation + "-all", label: "全部" + label}];
            if (menuMotionMode === "joint") {
                const joints = menuJointsKey ? menuJointsKey.split(",").map(Number) : [];
                joints.forEach(joint => children.push({id: "machine." + operation + "-joint-" + joint, label: "关节 " + joint + " " + label}));
            } else (menuAxesKey ? menuAxesKey.split(",") : []).forEach(axis => children.push({id: "machine." + operation + "-" + axis, label: axis + " 轴" + label}));
            return Object.assign({}, entry, {children: children});
        })});
        if (menu.id !== "file") return menu;
        return Object.assign({}, menu, {children: menu.children.map(entry => {
            if (entry.id !== "file.recent") return entry;
            const children = JSON.parse(recentFilesKey).map((path, index) => ({
                id: "file.recent." + index, label: String(path).split("/").pop()
            }));
            children.push({id: "file.clear-recents", label: "清空最近打开记录"});
            return Object.assign({}, entry, {children: children});
        })});
    })

    function selectedValue(group) {
        if (group === "mode") return machine.motionMode || "";
        if (group === "touch") return manual.touchTarget;
        return preview.choices[group] || "";
    }
    function isSelected(item) {
        if (item.id === "program.optional") return !!machine.optionalStop;
        if (item.id === "program.block-delete") return !!machine.blockDelete;
        return item.kind === "radio" ? selectedValue(item.group) === item.value : !!preview.flags[item.id];
    }
    function canActivate(id) {
        if (id.indexOf("view.") === 0 || id.indexOf("help.") === 0
                || id.indexOf("units.") === 0 || id.indexOf("grid.") === 0
                || id.indexOf("position.") === 0 || id.indexOf("coordinates.") === 0
                || id.indexOf("touch.") === 0 || (id.indexOf("show.") === 0 && id !== "show.pyvcp")) return true;
        if (id === "file.open" || id.indexOf("file.recent.") === 0) return !machine.busy;
        if (id === "file.quit" || id === "file.clear-recents") return true;
        if (["file.edit", "file.save", "file.properties", "file.reload"].indexOf(id) >= 0)
            return !!program && !!program.filePath && (["file.edit", "file.properties"].indexOf(id) >= 0 || !machine.busy);
        if (id.indexOf("mdi.") === 0 && id !== "mdi.execute" && id !== "mdi.go") return true;
        if (["machine.touch-off", "tool.touch-off"].indexOf(id) >= 0 && machine.motionMode === "joint") return false;
        if (!machine.connected) return false;
        if (machine.capabilities && machine.capabilities[id] === false) return false;
        if (id === "machine.estop" || id === "program.stop" || id === "machine.power") return true;
        if (id === "program.pause" || id === "program.resume") return !!machine.busy;
        if (id.indexOf("program.") === 0 && id !== "program.optional" && id !== "program.block-delete")
            return !!machine.powered && !machine.estop && !machine.busy && !!program && !!program.filePath;
        return true;
    }
    function activate(id, label) {
        if (!canActivate(id)) return;
        if (id === "view.zoom-in") { preview.zoomBy(1.15); return; }
        if (id === "view.zoom-out") { preview.zoomBy(1 / 1.15); return; }
        if (id === "view.rotate") { preview.rotate = !preview.rotate; return; }
        if (id === "view.clear") { preview.clearLive(); return; }
        const jointHoming = /^machine\.(home|unhome)-joint-(\d+)$/.exec(id);
        if (jointHoming) {
            commandRequested("machine." + jointHoming[1], {joint: Number(jointHoming[2])});
            return;
        }
        const item = Catalog.findItem(id);
        if (item && item.kind === "radio") {
            if (item.group === "mode") commandRequested("motion.mode", {mode: item.value});
            else if (item.group === "touch") manual.touchTarget = item.value;
            else preview.setChoice(item.group, item.value);
            return;
        }
        if (item && item.kind === "check" && id in preview.flags) {
            preview.toggleFlag(id);
            return;
        }
        if (id === "program.optional") { commandRequested(id, {enabled: !machine.optionalStop}); return; }
        if (id === "program.block-delete") { commandRequested(id, {enabled: !machine.blockDelete}); return; }
        if (id.indexOf("file.recent.") === 0) {
            const index = Number(id.slice("file.recent.".length));
            if (recentFiles[index]) commandRequested("file.open", {path: recentFiles[index]});
            return;
        }
        if (["help.about", "help.reference", "file.properties", "file.edit", "tool.edit",
             "machine.touch-off", "tool.touch-off", "view.grid-custom", "machine.debug"].indexOf(id) >= 0) {
            const title = item ? item.label.replace("…", "") : (label || "操作");
            dialogRequested(id, title, manual.selectedAxis);
            return;
        }
        commandRequested(id, id === "program.run-line" ? {line: program ? program.selectedLine : 0} : {});
    }
}
