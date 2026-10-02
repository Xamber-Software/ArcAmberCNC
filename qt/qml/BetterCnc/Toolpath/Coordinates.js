.pragma library

// LinuxCNC snapshots use machine units; only linear axes convert via units/mm.
var axisNames = "XYZABCUVW";

function linear(axis) { return "XYZUVW".indexOf(axis) >= 0; }

function vector(machine, field) {
    if (!machine || !machine.connected || !machine[field] || machine[field].length < 3)
        return null;
    return Array.from(machine[field]);
}

function position(machine, commanded, relative) {
    var result = vector(machine, commanded ? "commandedPosition" : "actualPosition");
    if (!result) return null;
    if (relative) {
        var tool = vector(machine, "toolOffset");
        var work = vector(machine, "g5xOffset");
        var temporary = vector(machine, "g92Offset");
        if (!tool || !work || !temporary || machine.rotationXY === null || machine.rotationXY === undefined)
            return null;
        for (var i = 0; i < result.length; ++i) result[i] -= (tool[i] || 0) + (work[i] || 0);
        var angle = -machine.rotationXY * Math.PI / 180;
        var x = result[0], y = result[1];
        result[0] = x * Math.cos(angle) - y * Math.sin(angle);
        result[1] = x * Math.sin(angle) + y * Math.cos(angle);
        for (var j = 0; j < result.length; ++j) result[j] -= temporary[j] || 0;
    }
    return result;
}

function converted(machine, axis, value, units) {
    if (value === null || value === undefined || !isFinite(value)) return null;
    if (!linear(axis)) return machine && machine.angularUnits > 0 ? Number(value) / machine.angularUnits : null;
    if (!machine || !(machine.linearUnits > 0)) return null;
    return Number(value) / machine.linearUnits / (units === "inch" ? 25.4 : 1);
}

function format(machine, axis, value, units) {
    var number = converted(machine, axis, value, units);
    if (number === null) return "—";
    var digits = linear(axis) && units === "inch" ? 4 : 3;
    if (Math.abs(number) < Math.pow(10, -digits) / 2) number = 0;
    return number.toFixed(digits);
}

function tip(machine) {
    var actual = vector(machine, "actualPosition"), tool = vector(machine, "toolOffset");
    if (!actual || !tool || !(machine.linearUnits > 0)) return null;
    return [0, 1, 2].map(function (i) { return (actual[i] - tool[i]) / machine.linearUnits; });
}

function workLabel(machine) {
    var index = machine ? machine.g5xIndex : 0;
    if (!(index >= 1 && index <= 9)) return "工件坐标系";
    return index <= 6 ? "G" + (53 + index) : "G59." + (index - 6);
}
