pragma Singleton
import QtQuick

QtObject {
    readonly property color base: "#151618"
    readonly property color sidebar: "#111214"
    readonly property color raised: "#1c1d20"
    readonly property color hover: "#26272c"
    readonly property color input: "#17181b"
    readonly property color border: "#27282d"
    readonly property color borderControl: "#373940"
    readonly property color text: "#ececef"
    readonly property color secondary: "#a4a6b0"
    readonly property color muted: "#858894"
    readonly property color accent: "#a29bfe"
    readonly property color accentFill: "#6860d9"
    readonly property color accentSoft: "#28253d"
    readonly property color danger: "#f58b8b"
    readonly property color dangerSoft: "#352024"
    readonly property string fontFamily: {
        const available = Qt.fontFamilies();
        const preferred = ["Inter", "Noto Sans CJK SC", "PingFang SC", "Microsoft YaHei"];
        for (let i = 0; i < preferred.length; ++i) {
            if (available.indexOf(preferred[i]) >= 0) return preferred[i];
        }
        return "sans-serif";
    }
    readonly property string mono: {
        const available = Qt.fontFamilies();
        const preferred = ["SFMono-Regular", "Consolas", "Liberation Mono", "Courier New", "Menlo"];
        for (let i = 0; i < preferred.length; ++i) {
            if (available.indexOf(preferred[i]) >= 0) return preferred[i];
        }
        return "monospace";
    }
}
