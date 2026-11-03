import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.components
import qs.config
import qs.services

// Popup whenever Spotify starts another song: cover, title, artist, album, progress and
// controls. Where and how it looks is in the settings (Config.spotifyPosition, spotifyFormat:
// wide, tall or strip, spotifySize, spotifySeconds); like the notifications the cover sits on
// the side it is on, and in the middle there is none and the text is centered. It stays while
// the mouse is on it, waits for the notification rule "sp.song" (not while playing by
// default), and does not show for songs skipped from the media card under the bar.
// No like button: Spotify does not offer liking over MPRIS.
Scope {
    id: root

    readonly property MprisPlayer spotify: Mpris.players.values.find(p => p.identity === "Spotify") ?? null
    property string lastTrack: ""
    property bool open: false
    property real remaining: 1

    readonly property string side: Config.side(Config.spotifyPosition)
    readonly property bool top: Config.atTop(Config.spotifyPosition)
    readonly property bool mirrored: side === "right"
    readonly property string format: ["wide", "tall", "strip"].includes(Config.spotifyFormat) ? Config.spotifyFormat : "wide"
    readonly property real size: Math.max(0.6, Math.min(1.6, Config.spotifySize))
    readonly property bool showCover: side !== "center"
    readonly property int textAlign: side === "right" ? Text.AlignRight : side === "center" ? Text.AlignHCenter : Text.AlignLeft

    property real shown: open ? 1 : 0
    Behavior on shown {
        NumberAnimation { duration: root.open ? Theme.anim.normal : Theme.anim.fast; easing.type: Easing.OutCubic }
    }

    function trackKey(player) {
        return player ? `${player.trackTitle}|${player.trackArtist}` : "";
    }

    function formatTime(seconds) {
        const s = Math.max(0, Math.floor(seconds || 0));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    function trackChanged() {
        const key = trackKey(spotify);
        if (!spotify || spotify.trackTitle === "" || key === lastTrack)
            return;
        lastTrack = key;
        // Skipped from the card under the bar: you are already looking at it
        if (Spotify.cardOpen)
            return;
        // Game mode and the bell, as the rules say
        if (!Notifications.allows("sp.song"))
            return;
        open = true;
        hideAnimation.restart();
    }

    // No popup for the song that was already playing when the shell started
    onSpotifyChanged: lastTrack = trackKey(spotify)

    Connections {
        target: root.spotify
        function onTrackTitleChanged() {
            root.trackChanged();
        }
        function onTrackArtistChanged() {
            root.trackChanged();
        }
    }

    NumberAnimation {
        id: hideAnimation
        target: root
        property: "remaining"
        from: 1
        to: 0
        duration: Math.max(2, Config.spotifySeconds) * 1000
        paused: cardHover.hovered
        onFinished: root.open = false
    }

    // MPRIS does not push the position, so ask for it while the popup is visible
    Timer {
        running: root.open && (root.spotify?.isPlaying ?? false)
        interval: 1000
        repeat: true
        onTriggered: root.spotify.positionChanged()
    }

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 14
        elide: Text.ElideRight
    }

    component Control: TuiButton {
        id: control

        property string glyph
        implicitWidth: 34
        implicitHeight: 28

        Text {
            anchors.centerIn: parent
            text: control.glyph
            color: control.hovered ? Theme.text : Theme.secondary
            font.family: Theme.iconFont
            font.pixelSize: 16
        }
    }

    PanelWindow {
        id: window

        screen: {
            const name = Hyprland.focusedMonitor?.name;
            return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
        }
        visible: (root.open || root.shown > 0.01) && root.spotify !== null
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-media-popup"
        // Neither left nor right: the layer shell centers it
        anchors {
            top: root.top
            bottom: !root.top
            left: root.side === "left"
            right: root.side === "right"
        }
        margins {
            top: 66
            bottom: 14
            left: 14
            right: 14
        }
        // The card is scaled from its top left corner, the window takes the scaled size
        implicitWidth: Math.ceil(card.width * root.size)
        implicitHeight: Math.ceil(card.height * root.size) + 16

        Item {
            id: card

            y: 12
            width: root.format === "tall" ? 260 : root.format === "strip" ? 380 : 420
            height: root.format === "strip" ? strip.implicitHeight + 16 : layout.implicitHeight + 36
            scale: root.size
            transformOrigin: Item.TopLeft
            opacity: root.shown
            transform: Translate {
                x: root.side === "right" ? 24 * (1 - root.shown) : root.side === "left" ? -24 * (1 - root.shown) : 0
                y: root.side === "center" ? (root.top ? -16 : 16) * (1 - root.shown) : 0
            }

            HoverHandler {
                id: cardHover
            }

            Rectangle {
                anchors.fill: parent
                color: Theme.bg
                opacity: 0.96
            }

            Frame {
                anchors.fill: parent
                label: root.format === "strip" ? "" : "now playing · spotify"
                labelAlign: root.side
                borderColor: root.format === "strip" ? Theme.border : Theme.primary
                padding: 0
            }

            // ── wide and tall ──
            GridLayout {
                id: layout

                visible: root.format !== "strip"
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 24 }
                // wide: cover beside the song; tall: cover on top
                columns: root.format === "tall" || !root.showCover ? 1 : 2
                layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
                columnSpacing: 14
                rowSpacing: 10

                Rectangle {
                    visible: root.showCover
                    Layout.preferredWidth: root.format === "tall" ? card.width - 32 : 72
                    Layout.preferredHeight: Layout.preferredWidth
                    color: Theme.surface2

                    Image {
                        anchors.fill: parent
                        source: root.spotify?.trackArtUrl ?? ""
                        sourceSize: Qt.size(root.format === "tall" ? 480 : 144, root.format === "tall" ? 480 : 144)
                        fillMode: Image.PreserveAspectCrop
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: root.textAlign
                        text: root.spotify?.trackTitle ?? ""
                        color: Theme.text
                        font.pixelSize: 17
                        font.weight: Font.Medium
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: root.textAlign
                        text: root.spotify?.trackArtist ?? ""
                        color: Theme.secondary
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: root.textAlign
                        text: root.spotify?.trackAlbum ?? ""
                        color: Theme.frame
                        font.pixelSize: 13
                    }

                    Row {
                        Layout.topMargin: 6
                        Layout.alignment: root.side === "right" ? Qt.AlignRight
                            : root.side === "center" || root.format === "tall" ? Qt.AlignHCenter
                            : Qt.AlignLeft
                        spacing: 6

                        Control {
                            glyph: "\uf04a"
                            available: root.spotify?.canGoPrevious ?? false
                            onClicked: root.spotify.previous()
                        }
                        Control {
                            glyph: root.spotify?.isPlaying ? "\uf04c" : "\uf04b"
                            onClicked: root.spotify.togglePlaying()
                        }
                        Control {
                            glyph: "\uf04e"
                            available: root.spotify?.canGoNext ?? false
                            onClicked: root.spotify.next()
                        }
                    }
                }

                // Time runs left to right on every side
                RowLayout {
                    Layout.columnSpan: layout.columns
                    Layout.fillWidth: true
                    layoutDirection: Qt.LeftToRight
                    spacing: 12

                    Label {
                        Layout.preferredWidth: 40
                        text: root.formatTime(root.spotify?.position)
                        color: Theme.muted
                        font.pixelSize: 12
                    }
                    Meter {
                        Layout.fillWidth: true
                        implicitHeight: 3
                        value: (root.spotify?.length ?? 0) > 0 ? root.spotify.position / root.spotify.length : 0
                        fill: Theme.primary
                    }
                    Label {
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                        text: root.formatTime(root.spotify?.length)
                        color: Theme.muted
                        font.pixelSize: 12
                    }
                }
            }

            // ── strip: one thin line ──
            RowLayout {
                id: strip

                visible: root.format === "strip"
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 10 }
                layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
                spacing: 10

                Rectangle {
                    visible: root.showCover
                    implicitWidth: 30
                    implicitHeight: 30
                    color: Theme.surface2

                    Image {
                        anchors.fill: parent
                        source: root.spotify?.trackArtUrl ?? ""
                        sourceSize: Qt.size(60, 60)
                        fillMode: Image.PreserveAspectCrop
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 5

                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: root.textAlign
                        text: `${root.spotify?.trackTitle ?? ""}  ·  ${root.spotify?.trackArtist ?? ""}`
                        color: Theme.text
                        font.pixelSize: 13
                    }
                    Meter {
                        Layout.fillWidth: true
                        implicitHeight: 2
                        value: (root.spotify?.length ?? 0) > 0 ? root.spotify.position / root.spotify.length : 0
                        fill: Theme.primary
                    }
                }
            }

            // Time until the popup hides, shrinking toward the side it sits on
            Rectangle {
                y: parent.height - height
                width: parent.width * root.remaining
                x: root.side === "right" ? parent.width - width : root.side === "center" ? (parent.width - width) / 2 : 0
                height: 2
                color: Theme.frame
            }
        }
    }
}
