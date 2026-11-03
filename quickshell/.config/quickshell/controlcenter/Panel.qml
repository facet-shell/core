import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.components
import qs.config
import qs.services

// Control center content: session and power, toggles, GoXLR faders, system stats.
// Sections slide in one after another while `progress` goes from 0 to 1.
Item {
    id: root

    property real progress: 1
    property bool mixerOpen: false
    property bool tasksOpen: false
    signal mixerToggled()
    signal tasksToggled()
    signal closeRequested()
    signal lockRequested()
    signal wallpapersRequested()
    signal keyboardRequested()
    signal settingsRequested()

    // Reboot and shutdown wait for a second click
    property string armed: ""

    implicitHeight: column.implicitHeight + 46

    function stage(index) {
        const start = 0.1 * index;
        return Math.max(0, Math.min(1, (progress - start) / (1 - start)));
    }

    function power(action) {
        if (action.key === "lock") {
            lockRequested();
            return;
        }
        if (action.confirm && armed !== action.key) {
            armed = action.key;
            disarm.restart();
            return;
        }
        armed = "";
        closeRequested();
        Quickshell.execDetached(["systemctl", action.key === "suspend" ? "suspend" : action.key === "reboot" ? "reboot" : "poweroff"]);
    }

    // "2h 14m", "3d 4h"
    function formatUptime(seconds) {
        const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
        return d > 0 ? `${d}d ${h}h` : `${h}h ${m}m`;
    }

    Timer {
        id: disarm
        interval: 3000
        onTriggered: root.armed = ""
    }

    FileView { id: hostname; path: "/etc/hostname"; blockLoading: true }
    FileView { id: osRelease; path: "/etc/os-release"; blockLoading: true }
    FileView { id: uptime; path: "/proc/uptime" }

    Timer {
        interval: 60000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: uptime.reload()
    }

    readonly property string distro: (/^NAME="?([^"\n]+)"?/m.exec(osRelease.text()) ?? [0, "linux"])[1]

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 16
    }

    component Icon: Text {
        color: Theme.secondary
        font.family: Theme.iconFont
        font.pixelSize: 20
    }

    component Section: Frame {
        property int index: 0
        Layout.fillWidth: true
        labelColor: Theme.muted
        padding: 16
        opacity: root.stage(index)
        transform: Translate { y: -8 * (1 - root.stage(index)) }
    }

    component ToggleTile: TuiButton {
        id: tile

        property string glyph
        property string title
        property bool checked: false
        property string offText: "off"

        Layout.fillWidth: true
        implicitHeight: 54
        active: checked

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 10
            spacing: 10

            Icon {
                text: tile.glyph
                color: tile.checked ? Theme.secondary : Theme.muted
                Layout.preferredWidth: 24
            }

            ColumnLayout {
                spacing: 0
                Label {
                    text: tile.title
                    color: tile.checked ? Theme.text : Theme.textDim
                    font.pixelSize: 14
                }
                Label {
                    text: !tile.available ? "n/a" : tile.checked ? "on" : tile.offText
                    color: tile.checked ? Theme.secondary : Theme.frame
                    font.pixelSize: 13
                }
            }
        }
    }

    // ── Layout ───────────────────────────────────────────────

    // Keeps clicks on the panel from closing it
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        opacity: 0.96
    }

    Frame {
        anchors.fill: parent
        label: "control"
        borderColor: Theme.primary
        padding: 0
    }

    ColumnLayout {
        id: column

        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 28 }
        spacing: 22

        // Session and power
        Section {
            index: 0
            label: "session"
            implicitHeight: sessionColumn.implicitHeight + 36

            ColumnLayout {
                id: sessionColumn
                anchors { left: parent.left; right: parent.right; top: parent.top }
                spacing: 14

                RowLayout {
                    spacing: 16

                    Rectangle {
                        implicitWidth: 48
                        implicitHeight: 48
                        color: Theme.primary
                        Text {
                            anchors.centerIn: parent
                            text: (Quickshell.env("USER") ?? "?").charAt(0).toUpperCase()
                            color: Theme.bg
                            font.family: Theme.font
                            font.pixelSize: 22
                            font.weight: Font.Medium
                        }
                    }

                    ColumnLayout {
                        spacing: 0
                        Label {
                            text: `${Quickshell.env("USER")}@${hostname.text().trim()}`
                            color: Theme.text
                            font.weight: Font.Medium
                        }
                        Label {
                            text: `up ${root.formatUptime(Number(uptime.text().split(" ")[0]) || 0)} · ${root.distro} · Hyprland`
                            color: Theme.muted
                            font.pixelSize: 14
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 4
                    columnSpacing: 8

                    Repeater {
                        model: [
                            { key: "lock", glyph: "", label: "lock", confirm: false },
                            { key: "suspend", glyph: "", label: "sleep", confirm: false },
                            { key: "reboot", glyph: "", label: "reboot", confirm: true },
                            { key: "shutdown", glyph: "", label: "off", confirm: true }
                        ]

                        TuiButton {
                            required property var modelData
                            readonly property bool isArmed: root.armed === modelData.key

                            Layout.fillWidth: true
                            implicitHeight: 62
                            accent: modelData.confirm ? Theme.danger : Theme.primary
                            active: isArmed
                            onClicked: root.power(modelData)

                            Column {
                                anchors.centerIn: parent
                                spacing: 3
                                Icon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: parent.parent.parent.modelData.glyph
                                    color: parent.parent.parent.isArmed ? Theme.danger : Theme.secondary
                                }
                                Label {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: parent.parent.parent.isArmed ? "again?" : parent.parent.parent.modelData.label
                                    color: parent.parent.parent.isArmed ? Theme.danger : Theme.textDim
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }
                }
            }
        }

        // Quick toggles
        Section {
            index: 1
            label: "toggles"
            implicitHeight: toggleGrid.implicitHeight + 36

            // Open the separate settings (Super+,), keyboard (Super+K) and wallpaper (Super+W) apps
            Row {
                anchors { right: parent.right; top: parent.top; topMargin: -16 - 12 }
                spacing: 8

                TuiButton {
                    implicitWidth: settingsLabel.implicitWidth + 20
                    implicitHeight: 24
                    color: Theme.bg
                    onClicked: root.settingsRequested()

                    Label {
                        id: settingsLabel
                        anchors.centerIn: parent
                        text: "settings ›"
                        color: Theme.secondary
                        font.pixelSize: 14
                    }
                }

                TuiButton {
                    implicitWidth: keyboardLabel.implicitWidth + 20
                    implicitHeight: 24
                    color: Theme.bg
                    onClicked: root.keyboardRequested()

                    Label {
                        id: keyboardLabel
                        anchors.centerIn: parent
                        text: "keyboard ›"
                        color: Theme.secondary
                        font.pixelSize: 14
                    }
                }

                TuiButton {
                    implicitWidth: wallpaperLabel.implicitWidth + 20
                    implicitHeight: 24
                    color: Theme.bg
                    onClicked: root.wallpapersRequested()

                    Label {
                        id: wallpaperLabel
                        anchors.centerIn: parent
                        text: "wallpapers ›"
                        color: Theme.secondary
                        font.pixelSize: 14
                    }
                }
            }

            GridLayout {
                id: toggleGrid
                anchors { left: parent.left; right: parent.right; top: parent.top }
                columns: 3
                columnSpacing: 10
                rowSpacing: 10

                ToggleTile {
                    glyph: ""
                    title: "wi-fi"
                    checked: Toggles.wifi
                    onClicked: Toggles.setWifi(!Toggles.wifi)
                }
                ToggleTile {
                    glyph: ""
                    title: "bluetooth"
                    checked: Toggles.bluetooth
                    available: Toggles.bluetoothAvailable
                    onClicked: Toggles.setBluetooth(!Toggles.bluetooth)
                }
                ToggleTile {
                    glyph: ""
                    title: "silent"
                    checked: Toggles.silent
                    onClicked: Toggles.silent = !Toggles.silent
                }
                ToggleTile {
                    glyph: ""
                    title: "stay awake"
                    checked: Toggles.stayAwake
                    onClicked: Toggles.stayAwake = !Toggles.stayAwake
                }
                ToggleTile {
                    glyph: ""
                    title: "game mode"
                    checked: Toggles.gameMode
                    onClicked: Toggles.setGameMode(!Toggles.gameMode)
                }
                ToggleTile {
                    // Same state as the mute button of the mic fader; without a GoXLR the
                    // default microphone's mute, like the mic row in the app mixer
                    readonly property bool onFader: GoXLR.fader("mic") !== null

                    glyph: ""
                    title: "mic mute"
                    checked: onFader ? GoXLR.fader("mic").muted : Audio.defaultSource?.audio?.muted ?? false
                    available: onFader || Audio.defaultSource !== null
                    onClicked: {
                        if (onFader)
                            GoXLR.setMuted("mic", !checked);
                        else
                            Audio.toggleMute(Audio.defaultSource);
                    }
                }
            }
        }

        // GoXLR faders: levels follow the hardware, mutes work from here. Without a GoXLR
        // the section only leads to the app mixer, which then mixes the plain devices
        Section {
            index: 2
            label: GoXLR.available || Audio.goxlr ? "goxlr faders" : "sound"
            implicitHeight: faderColumn.implicitHeight + 36

            TuiButton {
                anchors { right: parent.right; top: parent.top; topMargin: -16 - height / 2 }
                implicitWidth: mixerLabel.implicitWidth + 20
                implicitHeight: 24
                color: active ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14) : Theme.bg
                active: root.mixerOpen
                onClicked: root.mixerToggled()

                Label {
                    id: mixerLabel
                    anchors.centerIn: parent
                    text: "app mixer ›"
                    color: Theme.secondary
                    font.pixelSize: 14
                }
            }

            ColumnLayout {
                id: faderColumn
                anchors { left: parent.left; right: parent.right; top: parent.top }
                spacing: 6

                Label {
                    visible: !GoXLR.available
                    Layout.fillWidth: true
                    text: Audio.goxlr ? "goxlr-utility is not running" : "no goxlr · volume and device per app in the app mixer"
                    color: Theme.muted
                    elide: Text.ElideRight
                }

                // The list only changes when a fader gets another channel; level and mute
                // come from GoXLR.live, so the rows and their animations survive every poll
                Repeater {
                    model: GoXLR.faders

                    RowLayout {
                        id: faderRow

                        required property var modelData
                        readonly property var live: GoXLR.state(modelData.key)
                        readonly property var glyphs: ({ mic: "", chat: "", music: "", game: "" })

                        Layout.fillWidth: true
                        spacing: 12

                        Icon {
                            Layout.preferredWidth: 22
                            text: faderRow.glyphs[faderRow.modelData.key] ?? ""
                            color: Theme.muted
                            font.pixelSize: 16
                        }
                        Label {
                            Layout.preferredWidth: 104
                            text: faderRow.modelData.label
                            color: Theme.muted
                        }
                        Meter {
                            Layout.fillWidth: true
                            implicitHeight: 6
                            value: faderRow.live.level / 100
                            fill: faderRow.live.muted ? Theme.frame : Theme.secondary
                        }
                        Label {
                            Layout.preferredWidth: 64
                            horizontalAlignment: Text.AlignRight
                            text: faderRow.live.muted ? "muted" : `${faderRow.live.level}%`
                            color: faderRow.live.muted ? Theme.danger : Theme.textDim
                        }
                        TuiButton {
                            implicitWidth: 34
                            implicitHeight: 28
                            accent: Theme.danger
                            active: faderRow.live.muted
                            onClicked: GoXLR.setMuted(faderRow.modelData.key, !faderRow.live.muted)

                            Icon {
                                anchors.centerIn: parent
                                text: ""
                                color: faderRow.live.muted ? Theme.danger : Theme.muted
                                font.pixelSize: 16
                            }
                        }
                    }
                }

                // System has no fader on a Mini: a slider instead
                RowLayout {
                    visible: GoXLR.available && !GoXLR.systemOnFader && GoXLR.volumes.system !== undefined
                    Layout.fillWidth: true
                    spacing: 12

                    Icon {
                        Layout.preferredWidth: 22
                        text: String.fromCodePoint(0xF057E)
                        color: Theme.muted
                        font.pixelSize: 16
                    }
                    Label {
                        Layout.preferredWidth: 104
                        text: "system"
                        color: Theme.muted
                    }
                    TuiSlider {
                        Layout.fillWidth: true
                        value: (GoXLR.volumes.system ?? 0) / 100
                        onMoved: value => GoXLR.setChannelVolume("System", value * 100)
                    }
                    Label {
                        Layout.preferredWidth: 64
                        horizontalAlignment: Text.AlignRight
                        text: `${GoXLR.volumes.system ?? 0}%`
                        color: Theme.textDim
                    }
                    Item { implicitWidth: 34; implicitHeight: 28 }
                }
            }
        }

        // System numbers
        Section {
            index: 3
            label: "system"
            implicitHeight: stats.implicitHeight + 36

            // The task manager opens beside the panel, like the app mixer
            TuiButton {
                anchors { right: parent.right; top: parent.top; topMargin: -16 - height / 2 }
                implicitWidth: tasksLabel.implicitWidth + 20
                implicitHeight: 24
                color: active ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14) : Theme.bg
                active: root.tasksOpen
                onClicked: root.tasksToggled()

                Label {
                    id: tasksLabel
                    anchors.centerIn: parent
                    text: "tasks ›"
                    color: Theme.secondary
                    font.pixelSize: 14
                }
            }

            StatsSection {
                id: stats
                anchors { left: parent.left; right: parent.right; top: parent.top }
            }
        }
    }
}
