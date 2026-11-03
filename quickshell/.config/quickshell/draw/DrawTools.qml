import QtQuick

// What the toolbar picked, shared by the toolbar and every DrawCanvas of one place: the
// overlay's screens (DrawOverlay.qml) or the picture editor.
QtObject {
    // pen | mark | line | arrow | rect | ellipse | text | erase; "" in the picture editor:
    // nothing is drawn, blur boxes and the crop take the mouse
    property string tool: "pen"
    // A Theme role (DrawEngine.COLORS)
    property string color: "accent"
    // Screen pixels (DrawEngine.WIDTHS); a new shape stores it in document units
    property real width: 4
    property bool ruler: false
    // { x, y, a, len, h } in document units; placed by the canvas that shows it first
    property var rulerAt: null
    // Overlay only: the drawing stays, mouse and keys go to the windows
    property bool through: false
    // Overlay only: the toolbar on the left instead of bottom centre
    property bool docked: false
}
