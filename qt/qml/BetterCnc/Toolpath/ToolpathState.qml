import QtQuick

QtObject {
    id: root
    objectName: "toolpathState"

    property string previewTab: "preview"
    property real zoom: 1
    property bool rotate: false
    property int liveResetRevision: 0

    function clearLive(): void {
        liveResetRevision++;
    }
    property var choices: ({
        "view": "p", "units": "mm", "grid": "off",
        "position": "actual", "coordinates": "relative"
    })
    property var flags: ({
        "show.program": true, "show.rapids": true, "show.alpha": false,
        "show.live": true, "show.tool": true, "show.extents": true,
        "show.offsets": false, "show.limits": false, "show.velocity": true,
        "show.dtg": false, "show.large": false
    })

    function zoomBy(factor: real): void {
        zoom = Math.max(0.5, Math.min(2, zoom * factor));
    }

    function setChoice(group: string, value: string): void {
        const updated = Object.assign({}, choices);
        updated[group] = value;
        choices = updated;
    }

    function toggleFlag(flagId: string): void {
        setFlag(flagId, !flags[flagId]);
    }

    function setFlag(flagId: string, enabled: bool): void {
        const updated = Object.assign({}, flags);
        updated[flagId] = enabled;
        flags = updated;
    }
}
