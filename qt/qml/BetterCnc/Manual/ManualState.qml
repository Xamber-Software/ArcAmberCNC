import QtQml

QtObject {
    property string controlTab: "manual"
    property string selectedAxis: "X"
    property int selectedJoint: 0
    property string mode: "world"
    property string touchTarget: "workpiece"
    property real jogVelocity: 0
    property real jogIncrement: 0
}
