import QtQuick
import QtQuick.Shapes
import "IconPaths.js" as Icons

Item {
    id: root
    property string name: "cube"
    property color color: Theme.secondary
    implicitWidth: 18
    implicitHeight: 18
    Shape {
        width: 24
        height: 24
        scale: Math.min(root.width, root.height) / 24
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root.color
            strokeWidth: 1.6
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: Icons.paths[root.name] || Icons.paths.cube }
        }
    }
}
