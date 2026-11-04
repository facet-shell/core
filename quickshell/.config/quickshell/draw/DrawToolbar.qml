import QtQuick
import qs.components
import qs.config
import "DrawEngine.js" as Engine

// The drawing tools in the TUI facet look: a row (floating at the bottom of a screen) or a
// column (docked on the left). Tools, the theme's colors, four widths, then ruler, undo,
// redo and clear. Hovering a button names it in the frame's label (row) or under the
// buttons (column); `hint` has the whole text. Icons are the Nerd Font symbols
// (Theme.iconFont), see DrawEngine.js.
Item {
    id: root

    required property DrawTools tools
    required property var store
    property bool vertical: false
    property string title: "draw"
    // Picture editor: a pointer that leaves the mouse to blur boxes and the crop
    property bool selectTool: false
    // Overlay: click through and dock / float
    property bool overlayButtons: false
    property string hint: ""

    readonly property int cell: 30

    implicitWidth: frame.padding * 2 + grid.width
    implicitHeight: frame.padding * 2 + grid.height + (vertical ? hintText.height + 8 : 0)

    // Keys every place shares: the tool letters (DrawEngine.TOOLS), Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y.
    // true when the key was used.
    function handleKey(event) {
        const ctrl = event.modifiers & Qt.ControlModifier;
        if (ctrl && event.key === Qt.Key_Z) {
            if (event.modifiers & Qt.ShiftModifier)
                store.redo();
            else
                store.undo();
            return true;
        }
        if (ctrl && event.key === Qt.Key_Y) {
            store.redo();
            return true;
        }
        if (ctrl || (event.modifiers & Qt.AltModifier))
            return false;
        const tool = Engine.toolOfKey(event.text.toLowerCase());
        if (tool === "")
            return false;
        tools.tool = tool;
        return true;
    }

    function setHint(text, on) {
        if (on)
            hint = text;
        else if (hint === text)
            hint = "";
    }

    component IconButton: TuiButton {
        id: btn

        property int glyph: 0
        property string name: ""
        property color tint: Theme.textDim

        width: root.cell
        height: root.cell
        accent: Theme.accent
        onHoveredChanged: root.setHint(name, hovered)

        Text {
            anchors.centerIn: parent
            text: String.fromCodePoint(btn.glyph)
            color: btn.active || btn.hovered ? Theme.text : btn.tint
            font.family: Theme.iconFont
            font.pixelSize: 17
        }
    }

    component Separator: Rectangle {
        width: root.vertical ? root.cell * 2 + 4 : 1
        height: root.vertical ? 1 : root.cell
        color: Theme.surface2
    }

    component Group: Grid {
        // Two buttons a row when docked
        columns: root.vertical ? 2 : 100
        spacing: 4
    }

    // Clicks between the buttons must not draw underneath
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    Frame {
        id: frame

        anchors.fill: parent
        label: !root.vertical && root.hint !== "" ? `${root.title} · ${root.hint}` : root.title
        borderColor: Theme.primary
        fill: Theme.bg
        padding: 10

        Grid {
            id: grid

            columns: root.vertical ? 1 : 100
            spacing: 8
            verticalItemAlignment: Grid.AlignVCenter
            horizontalItemAlignment: Grid.AlignHCenter

            Group {
                IconButton {
                    visible: root.selectTool
                    glyph: Engine.GLYPHS.select
                    name: "select · blur boxes and crop (v)"
                    active: root.tools.tool === ""
                    onClicked: root.tools.tool = ""
                }

                Repeater {
                    model: Engine.TOOLS

                    IconButton {
                        required property var modelData

                        glyph: modelData.glyph
                        name: `${modelData.name} (${modelData.key})`
                        active: root.tools.tool === modelData.id
                        onClicked: root.tools.tool = modelData.id
                    }
                }
            }

            Separator {}

            Group {
                Repeater {
                    model: Engine.COLORS

                    TuiButton {
                        id: swatch

                        required property string modelData

                        width: root.cell
                        height: root.cell
                        accent: Theme.text
                        active: root.tools.color === modelData
                        onHoveredChanged: root.setHint(modelData, hovered)
                        onClicked: root.tools.color = modelData

                        Rectangle {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            color: Theme[swatch.modelData] ?? Theme.accent
                            border.width: 1
                            border.color: Theme.frame
                        }
                    }
                }
            }

            Separator {}

            Group {
                Repeater {
                    model: Engine.WIDTHS

                    TuiButton {
                        id: widthButton

                        required property int modelData

                        width: root.cell
                        height: root.cell
                        accent: Theme.accent
                        active: root.tools.width === modelData
                        onHoveredChanged: root.setHint(`${modelData} px`, hovered)
                        onClicked: root.tools.width = modelData

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(16, widthButton.modelData + 2)
                            height: width
                            radius: width / 2
                            color: widthButton.active ? Theme.text : Theme.textDim
                        }
                    }
                }
            }

            Separator {}

            Group {
                IconButton {
                    glyph: Engine.GLYPHS.ruler
                    name: "ruler · drag it, turn it by its ends or the wheel, the pen follows its edge"
                    active: root.tools.ruler
                    onClicked: root.tools.ruler = !root.tools.ruler
                }

                IconButton {
                    visible: root.overlayButtons
                    glyph: Engine.GLYPHS.through
                    name: "click through · the drawing stays, the windows get the mouse"
                    active: root.tools.through
                    onClicked: root.tools.through = !root.tools.through
                }

                IconButton {
                    visible: root.overlayButtons
                    glyph: root.tools.docked ? Engine.GLYPHS.dockBottom : Engine.GLYPHS.dockLeft
                    name: root.tools.docked ? "toolbar to the bottom" : "toolbar to the left"
                    onClicked: root.tools.docked = !root.tools.docked
                }

                IconButton {
                    glyph: Engine.GLYPHS.undo
                    name: "undo (ctrl+z)"
                    onClicked: root.store.undo()
                }

                IconButton {
                    glyph: Engine.GLYPHS.redo
                    name: "redo (ctrl+shift+z)"
                    onClicked: root.store.redo()
                }

                IconButton {
                    glyph: Engine.GLYPHS.clear
                    name: "clear the drawing (undo brings it back)"
                    tint: Theme.danger
                    accent: Theme.danger
                    onClicked: root.store.clearShapes()
                }
            }
        }

        Text {
            id: hintText

            visible: root.vertical
            anchors.top: grid.bottom
            anchors.topMargin: 8
            width: grid.width
            // The column is narrow: only the name, the host can show the rest (the editor does)
            text: root.hint.split(" · ")[0]
            color: Theme.muted
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: Theme.font
            font.pixelSize: 11
            // Room for two lines, so the toolbar does not jump while hovering
            height: font.pixelSize * 2.6
        }
    }
}
