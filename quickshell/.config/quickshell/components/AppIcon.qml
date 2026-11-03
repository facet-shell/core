import QtQuick
import Quickshell
import qs.config

// App icon from the icon theme, or a letter tile when the theme has none.
Item {
    id: root

    // Icon theme name ("spotify") or a path/URL to an image; both work
    property string icon
    property string glyph
    // The letter tile's font; icon glyphs (Nerd Font) take Theme.iconFont
    property string glyphFont: Theme.font
    property color tint: Theme.primary
    property int size: 40

    implicitWidth: size
    implicitHeight: size

    Image {
        id: image
        anchors.fill: parent
        source: root.icon === "" ? ""
            : /^(\/|file:|https?:|image:)/.test(root.icon) ? (root.icon.startsWith("/") ? "file://" + root.icon.split("/").map(encodeURIComponent).join("/") : root.icon)
            : Quickshell.iconPath(root.icon, true)
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        visible: status === Image.Ready
    }

    Rectangle {
        anchors.fill: parent
        visible: image.status !== Image.Ready
        color: root.tint

        Text {
            anchors.centerIn: parent
            text: root.glyph
            color: Theme.bg
            font.family: root.glyphFont
            font.pixelSize: root.size * 0.45
            font.weight: Font.Medium
        }
    }
}
