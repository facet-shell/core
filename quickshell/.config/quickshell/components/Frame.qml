import QtQuick
import qs.config

// TUI panel: a 1px border with the label sitting in the top line, like ┌─ label ───┐.
// The top line leaves a gap for the label, so the frame works on any background.
Item {
    id: root

    property string label: ""
    property color borderColor: Theme.border
    property color labelColor: Theme.primary
    property int padding: 24
    default property alias content: body.data
    // Fill behind the content, inside the border; transparent unless a panel needs
    // a backdrop (the lockscreen turns it on where the picture behind is bright)
    property color fill: "transparent"
    property real fillOpacity: 1

    // Animated copy so all five lines change color together
    property color lineColor: borderColor
    Behavior on lineColor { ColorAnimation { duration: Theme.anim.fast } }

    // Where the label sits in the top line: "left", "right" or "center"
    property string labelAlign: "left"

    readonly property real gapWidth: labelText.implicitWidth + 16
    readonly property real gapStart: label === "" ? width
        : labelAlign === "right" ? width - 14 - gapWidth
        : labelAlign === "center" ? (width - gapWidth) / 2
        : 14
    readonly property real gapEnd: label === "" ? width : gapStart + gapWidth

    Rectangle {
        x: 1
        y: 1
        width: Math.max(0, root.width - 2)
        height: Math.max(0, root.height - 2)
        color: root.fill
        opacity: root.fillOpacity
        Behavior on opacity { NumberAnimation { duration: Theme.anim.normal } }
    }

    Rectangle { x: 0; y: 0; width: root.gapStart; height: 1; color: root.lineColor }
    Rectangle { x: root.gapEnd; y: 0; width: Math.max(0, root.width - root.gapEnd); height: 1; color: root.lineColor }
    Rectangle { x: 0; y: 0; width: 1; height: root.height; color: root.lineColor }
    Rectangle { x: root.width - 1; y: 0; width: 1; height: root.height; color: root.lineColor }
    Rectangle { x: 0; y: root.height - 1; width: root.width; height: 1; color: root.lineColor }

    Text {
        id: labelText
        visible: root.label !== ""
        x: root.gapStart + 8
        y: -height / 2
        text: root.label
        color: root.labelColor
        font.family: Theme.font
        font.pixelSize: Theme.size.small
        Behavior on color { ColorAnimation { duration: Theme.anim.fast } }
    }

    Item {
        id: body
        anchors.fill: parent
        anchors.margins: root.padding
    }
}
