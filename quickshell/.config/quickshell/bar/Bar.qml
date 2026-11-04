import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.components
import qs.config
import qs.services

// Top bar on every screen. Segments read like the prompt:
//   [1 2 3 4 5]─[window title]        09:41  mon 19 oct        [♪ track]─[cpu 12% 48°]─[ram 6.2G]─[vol 62%]─[de] ⚙
// The bar flies up while the lockscreen takes over (`hidden`) and drops back in after unlock.
// Over a fullscreen window (a game) a copy comes down while the mouse rests on the top edge.
Scope {
    id: root

    property bool hidden: false
    signal controlCenterRequested(var screen)
    signal historyRequested(var screen)

    // Keyboard layout from Hyprland, shared by all bars
    property string keymap: ""
    // More than one layout in Hyprland's input config; with one the segment stays away
    property bool multiLayout: false

    // Prefer whatever is playing, then Spotify, then any player
    readonly property MprisPlayer player: {
        const list = Mpris.players.values;
        return list.find(p => p.isPlaying) ?? list.find(p => p.identity === "Spotify") ?? null;
    }

    // The GoXLR System channel (what the desktop plays through), else the default sink
    readonly property string volumeText: {
        if (GoXLR.available && GoXLR.volumes.system !== undefined) {
            const fader = GoXLR.faders.find(f => f.channel === "system");
            if (fader && GoXLR.state(fader.key).muted)
                return "muted";
            return `${GoXLR.volumes.system}%`;
        }
        const sink = Pipewire.defaultAudioSink;
        return sink?.audio ? (sink.audio.muted ? "muted" : `${Math.round(sink.audio.volume * 100)}%`) : "–";
    }

    // Scrolling on the volume: 5 % a notch, GoXLR System or the default sink
    function stepVolume(up) {
        if (GoXLR.available && GoXLR.volumes.system !== undefined) {
            GoXLR.stepSystem(up ? 5 : -5);
            return;
        }
        const sink = Pipewire.defaultAudioSink;
        if (sink?.audio)
            sink.audio.volume = Math.max(0, Math.min(1, sink.audio.volume + (up ? 0.05 : -0.05)));
    }

    function shortLayout(name) {
        const known = { german: "de", english: "en", french: "fr", spanish: "es", italian: "it" };
        const first = String(name).toLowerCase().split(/[\s(]/)[0];
        return known[first] ?? first.slice(0, 2);
    }

    Process {
        running: true
        command: ["hyprctl", "devices", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const keyboards = JSON.parse(this.text).keyboards ?? [];
                    const real = keyboards.filter(k => !/virtual|wtype|ydotool/i.test(k.name));
                    const kb = real.find(k => k.main) ?? real[0] ?? keyboards[0];
                    // One layout only: nothing to switch, so nothing to show
                    root.multiLayout = !!kb && String(kb.layout ?? "").includes(",");
                    if (kb && root.multiLayout)
                        root.keymap = root.shortLayout(kb.active_keymap ?? "");
                } catch (e) {}
            }
        }
    }

    Connections {
        target: Hyprland
        // "activelayout>>keyboard-name,German"
        function onRawEvent(event) {
            if (event.name !== "activelayout")
                return;
            // Virtual keyboards (wtype, ydotool, remote desktops) carry their own layout
            const [device, layout] = [event.data.slice(0, event.data.lastIndexOf(",")), event.data.split(",").pop()];
            if (/virtual|wtype|ydotool/i.test(device) || !root.multiLayout)
                return;
            root.keymap = root.shortLayout(layout);
        }
    }

    // Fullscreen or only maximized (which leaves the bar in sight) is only in hyprctl clients
    // (lastIpcObject); read it again when it can change, for the bar over fullscreen windows
    Connections {
        target: Hyprland
        enabled: Config.barOverFullscreen
        function onRawEvent(event) {
            if (["fullscreen", "workspacev2", "focusedmonv2", "openwindow", "closewindow", "movewindowv2"].includes(event.name))
                fullscreenRead.restart();
        }
    }

    Timer {
        id: fullscreenRead
        interval: 50
        onTriggered: {
            Hyprland.refreshWorkspaces();
            Hyprland.refreshToplevels();
        }
    }

    PwObjectTracker {
        objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ── Pieces ───────────────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 16
    }

    component Muted: Label {
        color: Theme.muted
    }

    // "[", "]─[" and "]" in frame color
    component Bracket: Label {
        color: Theme.frame
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: screenScope

            required property ShellScreen modelData
            readonly property HyprlandMonitor monitor: Hyprland.monitorFor(modelData)

            // A window covers this screen fullscreen (a maximized one leaves the bar in sight).
            // The bar sits on the Top layer, under it; resting the mouse on the top edge brings
            // a copy on the Overlay layer down over it (Config.barOverFullscreen)
            readonly property bool fullscreen: {
                const ws = monitor?.activeWorkspace;
                if (!Config.barOverFullscreen || !ws?.hasFullscreen)
                    return false;
                const modes = ws.toplevels.values.map(t => t.lastIpcObject?.fullscreen).filter(f => f !== undefined);
                // Not read from hyprctl yet: the workspace's word is enough
                return modes.length === 0 || modes.some(f => f === true || (Number(f) & 2) !== 0);
            }
            // The copy over the fullscreen window is down
            property bool peek: false
            // The mouse is on the copy (or on one of its cards)
            property bool held: false

            onFullscreenChanged: {
                if (fullscreen)
                    return;
                // Gone at once when fullscreen ends, the normal bar is back in sight
                peek = false;
                held = false;
                peekOpen.stop();
                peekClose.stop();
            }

            // Passing by does not count, the mouse has to rest on the edge
            Timer {
                id: peekOpen
                interval: 280
                onTriggered: {
                    if (!screenScope.fullscreen)
                        return;
                    screenScope.peek = true;
                    // Goes up again if the mouse never reaches the bar
                    if (!screenScope.held) {
                        peekClose.interval = 1200;
                        peekClose.restart();
                    }
                }
            }

            Timer {
                id: peekClose
                interval: 400
                onTriggered: screenScope.peek = false
            }

            // While the mouse is on the copy it stays, it goes up 400 ms after the mouse left
            function hold(on) {
                held = on;
                if (on) {
                    peekClose.stop();
                } else if (peek) {
                    peekClose.interval = 400;
                    peekClose.restart();
                }
            }

            // Hot edge: 1 px at the top of the screen, above the fullscreen window, only while
            // there is one and the copy is not down; it takes no keyboard focus and is too thin
            // to be in the game's way
            PanelWindow {
                screen: screenScope.modelData
                visible: screenScope.fullscreen && !screenScope.peek && !root.hidden
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "qs-bar-edge"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                implicitHeight: 1
                anchors {
                    top: true
                    left: true
                    right: true
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onContainsMouseChanged: containsMouse ? peekOpen.restart() : peekOpen.stop()
                }
            }

            // The bar (false) and, with barOverFullscreen, its copy over fullscreen windows (true)
            Variants {
                model: Config.barOverFullscreen ? [false, true] : [false]

                PanelWindow {
                    id: window

                    required property bool modelData
                    // The copy on the Overlay layer that comes down over a fullscreen window
                    readonly property bool over: modelData
                    readonly property ShellScreen shellScreen: screenScope.modelData
                    readonly property HyprlandMonitor monitor: screenScope.monitor

                    screen: shellScreen
                    // The copy shows while it is down or still sliding up, and goes at once
                    // when fullscreen ends
                    visible: !over || (!root.hidden && screenScope.fullscreen && (screenScope.peek || frame.y > -frame.height - 24))
                    color: "transparent"
                    implicitHeight: 64
                    // The copy reserves no space (-1 is what ExclusionMode.Ignore sends too)
                    exclusiveZone: over ? -1 : 64
                    exclusionMode: over ? ExclusionMode.Ignore : ExclusionMode.Normal
                    WlrLayershell.layer: over ? WlrLayer.Overlay : WlrLayer.Top
                    WlrLayershell.namespace: over ? "qs-bar-over" : "qs-bar"
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                    anchors {
                        top: true
                        left: true
                        right: true
                    }

                    // The whole strip counts for the copy, the margin above the frame too (the
                    // mouse rests at the very top), and so do its media and calendar cards
                    readonly property bool held: over && (stripHover.hovered || mediaHover.hovered || calendarHover.hovered)
                    onHeldChanged: screenScope.hold(held)

                    Item {
                        anchors.fill: parent
                        HoverHandler {
                            id: stripHover
                            enabled: window.over
                        }
                    }

                    // Stay awake: one inhibitor is enough, keep it on the first screen
                    IdleInhibitor {
                        window: window
                        enabled: !window.over && Toggles.stayAwake && window.shellScreen === Quickshell.screens[0]
                    }

                    // Media card under the song while the mouse is on it (or on the card)
                    property bool mediaWanted: mediaHoverHandler.hovered || mediaHover.hovered
                    onMediaWantedChanged: {
                        if (mediaWanted) {
                            mediaHover.anchorX = mediaLabel.mapToItem(null, 0, 0).x;
                            mediaHover.open = true;
                            mediaClose.stop();
                        } else {
                            mediaClose.restart();
                        }
                    }

                    Timer {
                        id: mediaClose
                        interval: 250
                        onTriggered: mediaHover.open = false
                    }

                    MediaHover {
                        id: mediaHover
                        barWindow: window
                        player: root.player
                    }

                    // Calendar under the clock, same open/close rules as the media card
                    property bool calendarWanted: clockHoverHandler.hovered || calendarHover.hovered
                    onCalendarWantedChanged: {
                        if (calendarWanted) {
                            const pos = center.mapToItem(null, 0, 0);
                            calendarHover.anchorX = pos.x + center.width / 2;
                            calendarHover.open = true;
                            calendarClose.stop();
                        } else {
                            calendarClose.restart();
                        }
                    }

                    Timer {
                        id: calendarClose
                        interval: 250
                        onTriggered: calendarHover.open = false
                    }

                    CalendarHover {
                        id: calendarHover
                        barWindow: window
                    }

                    Rectangle {
                        id: frame

                        // Up while locked; the copy over fullscreen also while it is not wanted
                        readonly property bool out: root.hidden || (window.over && !screenScope.peek)

                        x: 14
                        width: parent.width - 28
                        height: 52
                        y: out ? -height - 24 : 12
                        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.88)
                        border.width: 1
                        border.color: Theme.border

                        Behavior on y {
                            NumberAnimation {
                                duration: frame.out ? 380 : 520
                                easing.type: frame.out ? Easing.InCubic : Easing.OutBack
                            }
                        }

                        // Left: workspaces and window title
                        RowLayout {
                            anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, parent.width / 2 - center.width / 2 - 40)
                            spacing: 0

                            Bracket { text: "[" }

                            // Infinite canvas (facet layout canvas): a minimap instead of workspaces
                            CanvasMap {
                                visible: CanvasLayout.enabled
                                monitor: window.shellScreen.name
                                leftPadding: 4
                                rightPadding: 4
                            }

                            Row {
                                visible: !CanvasLayout.enabled
                                leftPadding: 4
                                rightPadding: 4
                                spacing: 4

                                Repeater {
                                    // 1–5 always, higher ones while they exist
                                    model: {
                                        const ids = [1, 2, 3, 4, 5];
                                        for (const ws of Hyprland.workspaces.values)
                                            if (ws.id > 5 && !ids.includes(ws.id))
                                                ids.push(ws.id);
                                        return ids.sort((a, b) => a - b);
                                    }

                                    Rectangle {
                                        required property int modelData
                                        readonly property bool active: window.monitor?.activeWorkspace?.id === modelData

                                        implicitWidth: wsLabel.implicitWidth + 16
                                        implicitHeight: wsLabel.implicitHeight
                                        color: active ? Theme.primary : "transparent"

                                        Label {
                                            id: wsLabel
                                            anchors.centerIn: parent
                                            text: parent.modelData
                                            color: parent.active ? Theme.bg : Theme.muted
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            // Lua dispatcher syntax (Hyprland 0.55+)
                                            onClicked: Hyprland.dispatch(`hl.dsp.focus({ workspace = ${parent.modelData} })`)
                                        }
                                    }
                                }
                            }

                            Bracket { text: "]─[" }

                            Muted {
                                Layout.fillWidth: true
                                Layout.maximumWidth: 640
                                text: ToplevelManager.activeToplevel?.title ?? "desktop"
                                elide: Text.ElideRight
                            }

                            Bracket { text: "]" }
                        }

                        // Center: clock and date
                        Row {
                            id: center
                            anchors.centerIn: parent
                            spacing: 12

                            HoverHandler {
                                id: clockHoverHandler
                            }

                            Label {
                                text: Qt.formatTime(clock.date, "hh:mm")
                                color: Theme.text
                            }

                            Muted {
                                text: clock.date.toLocaleDateString(Qt.locale("en_GB"), "ddd d MMM").toLowerCase()
                            }
                        }

                        // Right: media, stats, volume, layout, control center button
                        RowLayout {
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 0

                            // A screen recording (services/Recorder.qml) runs; click stops it
                            Bracket { text: "["; visible: Recorder.recording }
                            Label {
                                visible: Recorder.recording
                                text: Recorder.stopping ? "● saving …" : `● rec ${Recorder.elapsed}`
                                color: Theme.danger

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Recorder.stop()
                                }
                            }
                            Bracket { text: "]─"; visible: Recorder.recording }

                            Bracket { text: "["; visible: root.player !== null }
                            Label {
                                id: mediaLabel
                                visible: root.player !== null
                                Layout.maximumWidth: 300

                                HoverHandler {
                                    id: mediaHoverHandler
                                }
                                // Scroll on the song: the player's volume, 5 % a notch
                                WheelHandler {
                                    onWheel: event => {
                                        const p = root.player;
                                        if (p && p.volumeSupported)
                                            p.volume = Math.max(0, Math.min(1, p.volume + (event.angleDelta.y > 0 ? 0.05 : -0.05)));
                                    }
                                }
                                text: `  ${root.player?.trackTitle ?? ""} · ${root.player?.trackArtist ?? ""}`
                                color: Theme.secondary
                                elide: Text.ElideRight
                            }
                            Bracket { text: "]─"; visible: root.player !== null }

                            Bracket { text: "[" }
                            Muted { text: "cpu " }
                            Label { text: `${Math.round(SystemStats.cpu)}%` }
                            Label {
                                text: ` ${Math.round(SystemStats.cpuTemp)}°`
                                color: SystemStats.cpuTemp > 75 ? Theme.warn : Theme.muted
                                visible: SystemStats.cpuTemp > 0
                            }
                            Bracket { text: "]─[" }
                            Muted { text: "ram " }
                            Label { text: `${SystemStats.memUsed.toFixed(1)}G` }
                            Bracket { text: "]─[" }
                            Muted { text: " " ; font.family: Theme.iconFont }
                            Label {
                                text: root.volumeText
                                WheelHandler {
                                    onWheel: event => root.stepVolume(event.angleDelta.y > 0)
                                }
                            }
                            Bracket { text: "]" }

                            Bracket { text: "─["; visible: root.keymap !== "" }
                            Muted { text: root.keymap; visible: root.keymap !== "" }
                            Bracket { text: "]"; visible: root.keymap !== "" }

                            // Package and frameshell updates (services/Updates.qml): only there when
                            // there are some; hovering names the frameshell repos that are behind.
                            // Click runs them in Ghostty (only `facet update` when no package waits).
                            Bracket { text: "─["; visible: updatesItem.visible }
                            Item {
                                id: updatesItem
                                visible: Updates.total > 0 || Updates.frameCount > 0 || Updates.updating
                                implicitWidth: updatesRow.implicitWidth
                                implicitHeight: updatesRow.implicitHeight

                                HoverHandler {
                                    id: updatesHover
                                }

                                Row {
                                    id: updatesRow

                                    Label {
                                        visible: Updates.updating
                                        text: "updating …"
                                        color: Theme.muted
                                    }
                                    Label {
                                        visible: !Updates.updating && Updates.total > 0
                                        text: Updates.aurCount > 0 ? `↑ ${Updates.total} (${Updates.aurCount} aur)` : `↑ ${Updates.total}`
                                        color: Theme.warn
                                    }
                                    Muted {
                                        visible: !Updates.updating && Updates.total > 0 && Updates.frameCount > 0
                                        text: " · "
                                    }
                                    Label {
                                        visible: !Updates.updating && Updates.frameCount > 0
                                        text: updatesHover.hovered ? `facet ${Updates.frameList.map(r => r.name).join(" ")}`
                                            : Updates.total > 0 ? `facet ${Updates.frameCount}` : `↑ facet ${Updates.frameCount}`
                                        color: Theme.warn
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Updates.update()
                                }
                            }
                            Bracket { text: "]"; visible: updatesItem.visible }

                            // Bell: notifications missed while "silent" was on; click for the history
                            Bracket { text: "─[" }
                            Item {
                                implicitWidth: bellRow.implicitWidth
                                implicitHeight: bellRow.implicitHeight

                                Row {
                                    id: bellRow
                                    spacing: 6
                                    Text {
                                        text: ""
                                        color: Notifications.missed > 0 ? Theme.warn : Theme.muted
                                        font.family: Theme.iconFont
                                        font.pixelSize: 15
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Label {
                                        text: Notifications.missed
                                        color: Notifications.missed > 0 ? Theme.warn : Theme.muted
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.historyRequested(window.shellScreen)
                                }
                            }
                            Bracket { text: "]" }

                            TuiButton {
                                Layout.leftMargin: 14
                                implicitWidth: 38
                                implicitHeight: 34
                                onClicked: root.controlCenterRequested(window.shellScreen)

                                Text {
                                    anchors.centerIn: parent
                                    text: ""
                                    color: Theme.secondary
                                    font.family: Theme.iconFont
                                    font.pixelSize: 17
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
