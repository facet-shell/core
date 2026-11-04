import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.config
import qs.services

// Wallpaper app UI: search and filters on top, tiles on the left, backend and playback
// settings on the right. Arrows move, Enter sets the wallpaper, Esc closes.
Item {
    id: root

    signal closeRequested()

    property string query: ""
    property string type: "all"
    // Screen the wallpaper goes on, "*" = all screens
    property string target: "*"
    property int current: 0

    readonly property int columns: 4
    readonly property var kinds: ({ both: ["scene", "video", "image"], mpv: ["video", "image"], image: ["image"] })[Wallpapers.settings.backend] ?? []
    readonly property var shown: filter(Wallpapers.items, query, type)
    readonly property string active: Wallpapers.current(target)

    readonly property var backendHints: ({
        both: "workshop scenes and videos through linux-wallpaperengine, files through mpvpaper and swaybg",
        mpv: "only files from ~/Pictures/wallpapers and assets/wallpapers, videos through mpvpaper",
        image: "still images only, through swaybg · lowest power use"
    })

    function reset() {
        input.text = "";
        current = 0;
        target = "*";
        input.forceActiveFocus();
        Wallpapers.refresh();
    }

    function filter(items, query, type) {
        const q = query.trim().toLowerCase();
        return items.filter(w => {
            // frame-wallpaper list leaves out what the engine cannot show (web, presets, gif scenes)
            const kind = w.kind;
            if (type !== "all" && kind !== type)
                return false;
            return q === "" || `${w.title} ${(w.tags ?? []).join(" ")}`.toLowerCase().includes(q);
        });
    }

    function move(step) {
        if (shown.length === 0)
            return;
        current = Math.max(0, Math.min(shown.length - 1, current + step));
        grid.positionViewAtIndex(current, GridView.Contain);
    }

    function applyCurrent() {
        const w = shown[current];
        if (w)
            Wallpapers.apply(w.path, target);
    }

    onTypeChanged: current = 0
    onKindsChanged: if (type !== "all" && !kinds.includes(type)) type = "all"

    // Sliders save once they stop moving; every save restarts the backend
    Timer {
        id: fpsSave
        interval: 600
        onTriggered: Wallpapers.option("fps", fpsSlider.pending)
    }

    Timer {
        id: volumeSave
        interval: 600
        onTriggered: Wallpapers.option("volume", volumeSlider.pending)
    }

    // The sliders follow the saved state unless a change is still waiting to be saved
    Connections {
        target: Wallpapers

        function onSettingsChanged() {
            if (!fpsSave.running)
                fpsSlider.pending = Wallpapers.settings.fps ?? 30;
            if (!volumeSave.running)
                volumeSlider.pending = Wallpapers.settings.volume ?? 0;
        }
    }

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 16
    }

    component Chip: TuiButton {
        id: chip

        property string text: ""

        implicitWidth: chipLabel.implicitWidth + 20
        implicitHeight: 26

        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.text
            color: chip.active ? Theme.text : chip.hovered ? Theme.textDim : Theme.muted
            font.family: Theme.font
            font.pixelSize: 13
        }
    }

    component Section: Frame {
        default property alias items: column.data

        Layout.fillWidth: true
        implicitHeight: column.implicitHeight + 34
        padding: 0
        labelColor: Theme.muted

        ColumnLayout {
            id: column
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16; topMargin: 20 }
            spacing: 10
        }
    }

    component Divider: Rectangle {
        color: Theme.border
        implicitWidth: 1
        implicitHeight: 1
    }

    // ── Layout ───────────────────────────────────────────────

    // Swallows clicks so they do not reach the dimmed background behind
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        opacity: 0.97
    }

    Frame {
        anchors.fill: parent
        label: "wallpapers"
        borderColor: Theme.primary
        padding: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 1
            spacing: 0

            // Search and filters
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 70
                Layout.leftMargin: 22
                Layout.rightMargin: 22
                spacing: 14

                Text {
                    text: "❯"
                    color: Theme.primary
                    font.family: Theme.font
                    font.pixelSize: 22
                    font.weight: Font.Medium
                }

                TextInput {
                    id: input

                    Layout.fillWidth: true
                    focus: true
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 18
                    cursorDelegate: Rectangle { width: 2; color: Theme.secondary }

                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: input.text === ""
                        text: "search title or tags"
                        color: Theme.frame
                        font.pixelSize: 18
                    }

                    onTextChanged: {
                        root.query = text;
                        root.current = 0;
                    }

                    Keys.onPressed: event => {
                        switch (event.key) {
                        case Qt.Key_Right:
                            root.move(1);
                            break;
                        case Qt.Key_Left:
                            root.move(-1);
                            break;
                        case Qt.Key_Down:
                            root.move(root.columns);
                            break;
                        case Qt.Key_Up:
                            root.move(-root.columns);
                            break;
                        case Qt.Key_Escape:
                            root.closeRequested();
                            break;
                        case Qt.Key_Return:
                        case Qt.Key_Enter:
                            root.applyCurrent();
                            break;
                        default:
                            return;
                        }
                        event.accepted = true;
                    }
                }

                Row {
                    spacing: 6
                    Repeater {
                        model: ["all"].concat(root.kinds)
                        Chip {
                            required property string modelData
                            text: modelData
                            active: root.type === modelData
                            onClicked: root.type = modelData
                        }
                    }
                }

                Row {
                    spacing: 6
                    visible: Quickshell.screens.length > 1
                    Repeater {
                        model: ["*"].concat(Quickshell.screens.map(s => s.name))
                        Chip {
                            required property string modelData
                            text: modelData === "*" ? "all screens" : modelData
                            active: root.target === modelData
                            onClicked: root.target = modelData
                        }
                    }
                }
            }

            Divider { Layout.fillWidth: true }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Tiles
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // The settings column must not push the tiles out; both sides get firm widths
                    Layout.minimumWidth: 480

                    Label {
                        anchors { left: parent.left; top: parent.top; margins: 24 }
                        visible: root.shown.length === 0
                        text: !Wallpapers.available ? "the wallpaper package is not installed · run: facet install wallpaper"
                            : Wallpapers.loading ? "looking for wallpapers…"
                            : Wallpapers.items.length === 0 ? "no wallpapers yet · put files in ~/Pictures/wallpapers or subscribe in the workshop"
                            : "no wallpapers match"
                        color: Theme.muted
                    }

                    GridView {
                        id: grid

                        anchors.fill: parent
                        anchors.margins: 14
                        clip: true
                        cellWidth: width / root.columns
                        cellHeight: cellWidth * 0.56 + 62
                        model: root.shown
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            id: tile

                            required property var modelData
                            required property int index
                            readonly property bool selected: index === root.current
                            readonly property bool isActive: modelData.path === root.active

                            width: grid.cellWidth
                            height: grid.cellHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 8
                                color: "transparent"
                                border.width: 1
                                border.color: tile.isActive ? Theme.primary : tile.selected ? Theme.secondary
                                    : tileHover.containsMouse ? Theme.frame : Theme.border

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    spacing: 6

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        color: Theme.surface
                                        clip: true

                                        Image {
                                            anchors.fill: parent
                                            source: tile.modelData.preview ? "file://" + tile.modelData.preview.split("/").map(encodeURIComponent).join("/") : ""
                                            sourceSize: Qt.size(480, 270)
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: !tile.modelData.preview
                                            text: tile.modelData.kind
                                            color: Theme.frame
                                            font.family: Theme.font
                                            font.pixelSize: 14
                                        }
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 10
                                        Layout.rightMargin: 10
                                        text: `${tile.isActive ? "❯ " : ""}${tile.modelData.title}`
                                        color: tile.isActive ? Theme.text : Theme.textDim
                                        font.pixelSize: 15
                                        elide: Text.ElideRight
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 10
                                        Layout.rightMargin: 10
                                        Layout.bottomMargin: 8
                                        text: [tile.modelData.kind, tile.modelData.source].concat(tile.modelData.tags ?? []).join(" · ")
                                        color: Theme.frame
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            MouseArea {
                                id: tileHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.current = tile.index;
                                    root.applyCurrent();
                                }
                            }
                        }
                    }
                }

                Divider { Layout.fillHeight: true }

                // Settings
                ColumnLayout {
                    Layout.preferredWidth: 360
                    Layout.minimumWidth: 360
                    Layout.maximumWidth: 360
                    Layout.fillHeight: true
                    Layout.margins: 22
                    Layout.topMargin: 26
                    spacing: 22

                    Section {
                        label: "backend"

                        Row {
                            spacing: 6
                            Repeater {
                                model: [["both", "engine + mpv"], ["mpv", "mpvpaper"], ["image", "image"]]
                                Chip {
                                    required property var modelData
                                    text: modelData[1]
                                    active: Wallpapers.settings.backend === modelData[0]
                                    onClicked: Wallpapers.setBackend(modelData[0])
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            text: root.backendHints[Wallpapers.settings.backend] ?? ""
                            color: Theme.frame
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                    }

                    Section {
                        label: "playback"
                        // Images do not move, so fps and sound mean nothing there
                        opacity: Wallpapers.settings.backend === "image" ? 0.4 : 1
                        enabled: Wallpapers.settings.backend !== "image"

                        RowLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: "fps limit"; color: Theme.muted; font.pixelSize: 14 }
                            Label { text: fpsSlider.pending; font.pixelSize: 14 }
                        }

                        TuiSlider {
                            id: fpsSlider

                            // 15 to 144 fps
                            property int pending: 30

                            Layout.fillWidth: true
                            value: (pending - 15) / (144 - 15)
                            onMoved: v => {
                                pending = Math.round(15 + v * (144 - 15));
                                fpsSave.restart();
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: "sound"; color: Theme.muted; font.pixelSize: 14 }
                            Label { text: volumeSlider.pending === 0 ? "muted" : `${volumeSlider.pending}%`; font.pixelSize: 14 }
                        }

                        TuiSlider {
                            id: volumeSlider

                            property int pending: 0

                            Layout.fillWidth: true
                            value: pending / 100
                            onMoved: v => {
                                pending = Math.round(v * 100);
                                volumeSave.restart();
                            }
                        }
                    }

                    Section {
                        label: "display"

                        RowLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: "scaling"; color: Theme.muted; font.pixelSize: 14 }
                            Repeater {
                                model: ["fill", "fit"]
                                Chip {
                                    required property string modelData
                                    text: modelData
                                    active: Wallpapers.settings.scaling === modelData
                                    onClicked: Wallpapers.option("scaling", modelData)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: "pause in fullscreen"; color: Theme.muted; font.pixelSize: 14 }
                            Chip {
                                text: Wallpapers.settings.pause ? "on" : "off"
                                active: Wallpapers.settings.pause === true
                                onClicked: Wallpapers.option("pause", !Wallpapers.settings.pause)
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }

                    Label {
                        Layout.fillWidth: true
                        text: "←→↑↓ select · enter set · esc close\nframe wallpaper backend changes the backend from a terminal\nthe lockscreen blurs a still snapshot"
                        color: Theme.frame
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
