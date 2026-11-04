import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.config
import qs.services

// Discord voice overlay: while you are in a voice channel, who is in it, who is talking
// (a green ring), who is muted, deafened or live, and a short feed of joins, leaves and your
// own mute. No title, frame or background, only faces and names with a thin dark outline,
// so it reads over any game. Every click goes through it. Super+Shift+V moves it: then it
// takes the mouse, drag it anywhere, Esc or the key again keeps the spot (per screen).
// When it shows, the look and the feed are in the settings (Config.voiceOverlay*); the data
// comes from the Vencord plugin through DiscordBridge.
Scope {
    id: root

    property bool hidden: false
    property bool moving: false

    readonly property var members: {
        const list = DiscordBridge.voice.members;
        return Config.voiceOverlayLook === "talking" ? list.filter(m => m.you || DiscordBridge.speaking[m.userId]) : list;
    }
    readonly property bool compact: Config.voiceOverlayLook === "compact"
    readonly property real size: Math.max(0.6, Math.min(1.6, Config.voiceOverlaySize))

    // The feed: newest first, each line fades out after a few seconds
    property var lines: []
    property int nextLine: 0

    Connections {
        target: DiscordBridge
        function onVoiceLine(text, kind) {
            root.lines = [{ id: root.nextLine++, text, kind, until: Date.now() + 4500 }].concat(root.lines).slice(0, 3);
        }
    }

    Timer {
        running: root.lines.length > 0
        interval: 250
        repeat: true
        onTriggered: root.lines = root.lines.filter(l => l.until > Date.now())
    }

    function glyph(code) {
        return String.fromCodePoint(code);
    }

    // Kept per screen: two screens of different sizes each have their own spot
    function savePos(screenName, x, y) {
        const next = Object.assign({}, Config.voiceOverlayPos);
        next[screenName] = [Math.round(x), Math.round(y)];
        Config.set("voiceOverlayPos", next);
    }

    onHiddenChanged: if (hidden) moving = false

    IpcHandler {
        target: "voice"

        // Super+Shift+V
        function move(): void {
            root.moving = !root.moving;
        }

        // Super+Shift+M and Super+Shift+D, from inside a game too
        function mute(): void {
            DiscordBridge.send({ cmd: "toggle_mute" });
        }

        function deafen(): void {
            DiscordBridge.send({ cmd: "toggle_deafen" });
        }

        function leave(): void {
            DiscordBridge.send({ cmd: "leave_voice" });
        }
    }

    // Name, icon and feed text: the theme's colors with a dark outline for bright games
    component Outlined: Text {
        font.family: Theme.font
        font.pixelSize: 15
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.7)
        elide: Text.ElideRight
    }

    component Face: Item {
        id: face

        required property var person
        readonly property bool talking: DiscordBridge.speaking[person.userId] === true

        implicitWidth: 28
        implicitHeight: 28

        // Talking: a green ring around the picture
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            color: "transparent"
            border.width: 2
            border.color: face.talking ? Theme.ok : "transparent"
        }

        // Initials until (or instead of) the picture
        Rectangle {
            anchors.fill: parent
            color: Theme.surface2

            Text {
                anchors.centerIn: parent
                text: (face.person.name ?? "?").slice(0, 2).toUpperCase()
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 11
                font.weight: Font.Bold
            }
        }

        Image {
            anchors.fill: parent
            source: face.person.avatar ?? ""
            sourceSize: Qt.size(56, 56)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }

    // Muted or deafened, red
    component StateIcon: Outlined {
        required property var person
        visible: text !== ""
        text: person.deafened ? String.fromCodePoint(0xF07CE) : person.muted ? String.fromCodePoint(0xF036D) : ""
        color: Theme.danger
        font.family: Theme.iconFont
    }

    PanelWindow {
        id: window

        screen: {
            const name = Hyprland.focusedMonitor?.name;
            return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
        }
        readonly property string screenName: screen?.name ?? ""
        // Without a saved spot: on the left, under the bar
        readonly property var pos: Config.voiceOverlayPos[screenName] ?? [24, 70]

        visible: !root.hidden && (DiscordBridge.overlayShown || root.moving)
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-voice-overlay"
        // Moving takes Esc; otherwise the game keeps the keyboard
        WlrLayershell.keyboardFocus: root.moving ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Clicks go through everywhere, except while moving
        mask: root.moving ? null : passThrough
        Region {
            id: passThrough
        }

        function place() {
            card.x = Math.max(0, Math.min(width - card.width * root.size, pos[0]));
            card.y = Math.max(0, Math.min(height - card.height * root.size, pos[1]));
        }
        onPosChanged: place()
        onWidthChanged: place()
        onHeightChanged: place()

        Item {
            anchors.fill: parent
            focus: root.moving
            Keys.onEscapePressed: root.moving = false
        }

        Item {
            id: card

            width: content.width + 12
            height: content.height + 12
            scale: root.size
            transformOrigin: Item.TopLeft
            Component.onCompleted: window.place()

            // Only while moving: a thin line so you see what you drag
            Rectangle {
                anchors.fill: parent
                visible: root.moving
                color: Qt.rgba(0, 0, 0, 0.25)
                border.width: 1
                border.color: Theme.primary
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.moving
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: card
                drag.minimumX: 0
                drag.minimumY: 0
                drag.maximumX: window.width - card.width * root.size
                drag.maximumY: window.height - card.height * root.size
                onReleased: root.savePos(window.screenName, card.x, card.y)
            }

            Column {
                id: content

                x: 6
                y: 6
                spacing: 8

                // Moving without a call: something to grab
                Outlined {
                    visible: root.moving && root.members.length === 0
                    text: "voice overlay"
                    color: Theme.textDim
                }

                // ── list and "only who talks": one row each ──
                Column {
                    visible: !root.compact
                    spacing: 6

                    Repeater {
                        model: root.compact ? [] : root.members

                        delegate: Row {
                            id: row

                            required property var modelData
                            readonly property bool talking: DiscordBridge.speaking[modelData.userId] === true

                            spacing: 9
                            opacity: Config.voiceOverlayDim && !talking && Config.voiceOverlayLook === "list" ? 0.6 : 1
                            Behavior on opacity {
                                NumberAnimation { duration: 120 }
                            }

                            Face {
                                person: row.modelData
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Outlined {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, 200)
                                text: row.modelData.name
                                color: row.talking ? Theme.text : Theme.textDim
                            }
                            Rectangle {
                                visible: row.modelData.streaming === true
                                anchors.verticalCenter: parent.verticalCenter
                                width: live.implicitWidth + 8
                                height: live.implicitHeight + 2
                                color: Theme.danger

                                Text {
                                    id: live
                                    anchors.centerIn: parent
                                    text: "LIVE"
                                    color: Theme.bg
                                    font.family: Theme.font
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                }
                            }
                            StateIcon {
                                person: row.modelData
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                // ── compact: faces in a row, the name under it only while talking ──
                Row {
                    visible: root.compact
                    spacing: 10

                    Repeater {
                        model: root.compact ? root.members : []

                        delegate: Column {
                            id: cell

                            required property var modelData
                            readonly property bool talking: DiscordBridge.speaking[modelData.userId] === true

                            width: 46
                            spacing: 4

                            Item {
                                width: 46
                                height: 28

                                Face {
                                    person: cell.modelData
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                                StateIcon {
                                    person: cell.modelData
                                    x: 31
                                    y: 14
                                    font.pixelSize: 12
                                }
                            }
                            Outlined {
                                width: 46
                                horizontalAlignment: Text.AlignHCenter
                                text: cell.modelData.name
                                font.pixelSize: 11
                                color: Theme.text
                                opacity: cell.talking ? 1 : 0
                            }
                        }
                    }
                }

                // ── the feed: joins, leaves, going live, your mute ──
                Column {
                    visible: root.lines.length > 0
                    spacing: 2

                    Repeater {
                        model: root.lines

                        delegate: Outlined {
                            required property var modelData

                            width: Math.min(implicitWidth, 260)
                            text: modelData.text
                            font.pixelSize: 13
                            color: modelData.kind === "in" ? Theme.ok : modelData.kind === "self" ? Theme.danger : Theme.textDim
                            // The last second fades (the list is rebuilt every 250 ms while it has lines)
                            opacity: Math.min(1, (modelData.until - Date.now()) / 1000 + 0.2)
                        }
                    }
                }

                Outlined {
                    visible: root.moving
                    text: "drag · Esc or Super+Shift+V to finish"
                    color: Theme.primary
                    font.pixelSize: 12
                }
            }
        }
    }
}
