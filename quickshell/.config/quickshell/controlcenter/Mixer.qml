import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.config
import qs.services

// App mixer beside the control center: per-app volume, mute and routing.
// With a GoXLR every app is routed to one of its channels. Without one (no utility, no
// device) apps are moved between the machine's own outputs and inputs instead, and master
// rows for the default output and microphone sit on top, so it is a full mixer either way.
// From six apps on every app takes one line; apps that play right now come first,
// idle ones are dimmed at the bottom, and the list scrolls inside the panel.
Item {
    id: root

    readonly property bool goxlr: Audio.goxlr
    // Moving a stream to another channel (or a short pause) drops its link for a moment, so
    // the order only follows idle changes after they held for a while; new and gone apps
    // show up at once
    readonly property var rawPlayback: sortActive(Audio.playback)
    readonly property var rawRecording: sortActive(Audio.recording)
    property var playback: []
    property var recording: []
    readonly property bool compact: Audio.playback.length > 5
    readonly property int activeCount: playback.filter(n => !Audio.isIdle(n)).length
    readonly property int idleCount: playback.length - activeCount
    // Without a GoXLR one empty state stands for both lists; with one each list says it
    readonly property bool empty: !goxlr && playback.length === 0 && recording.length === 0
    // The row whose device list is open: a stream node, or "output" / "input" for the
    // master rows. One at a time, so the panel does not grow with every click
    property var picking: null

    implicitHeight: column.implicitHeight + 46
    onVisibleChanged: {
        if (!visible)
            picking = null;
    }

    function sortActive(list) {
        return list.slice().sort((a, b) => (Audio.isIdle(a) ? 1 : 0) - (Audio.isIdle(b) ? 1 : 0));
    }

    function sameSet(a, b) {
        return a.length === b.length && a.every(n => b.includes(n));
    }

    function sameOrder(a, b) {
        return sameSet(a, b) && a.every((n, i) => n === b[i]);
    }

    onRawPlaybackChanged: sameSet(rawPlayback, playback) ? settle.restart() : playback = rawPlayback
    onRawRecordingChanged: sameSet(rawRecording, recording) ? settle.restart() : recording = rawRecording
    Component.onCompleted: {
        playback = rawPlayback;
        recording = rawRecording;
    }

    Timer {
        id: settle
        interval: 800
        onTriggered: {
            if (!root.sameOrder(root.rawPlayback, root.playback))
                root.playback = root.rawPlayback;
            if (!root.sameOrder(root.rawRecording, root.recording))
                root.recording = root.rawRecording;
        }
    }

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 16
    }

    // Speaker (or mic) that turns red while muted
    component MuteButton: TuiButton {
        id: mute

        property bool muted: false
        property bool mic: false

        implicitWidth: root.compact ? 30 : 34
        implicitHeight: root.compact ? 26 : 30
        accent: Theme.danger
        active: muted

        Text {
            anchors.centerIn: parent
            // Font Awesome volume-off / volume-up, microphone-slash / microphone
            text: String.fromCodePoint(mute.mic ? (mute.muted ? 0xF131 : 0xF130) : (mute.muted ? 0xF026 : 0xF028))
            color: mute.muted ? Theme.danger : Theme.secondary
            font.family: Theme.iconFont
            font.pixelSize: 15
        }
    }

    // The device a row plays on (or records from); a click opens the device list below
    // the row. Long names like "Starship/Matisse HD Audio Controller Analog Stereo" are cut
    component DeviceChip: TuiButton {
        id: chip

        property string name: ""
        property bool open: false
        property int maxWidth: 170

        implicitWidth: chipName.width + chipArrow.implicitWidth + 6 + (root.compact ? 14 : 18)
        implicitHeight: root.compact ? 22 : 26
        active: open

        Row {
            anchors.centerIn: parent
            spacing: 6

            Label {
                id: chipName
                width: Math.min(implicitWidth, chip.maxWidth)
                text: chip.name
                color: chip.open ? Theme.text : Theme.muted
                font.pixelSize: root.compact ? 12 : 13
                elide: Text.ElideRight
            }
            Label {
                id: chipArrow
                text: chip.open ? "▴" : "▾"
                color: chip.open ? Theme.secondary : Theme.frame
                font.pixelSize: root.compact ? 12 : 13
            }
        }
    }

    // Every device to pick from as chips that wrap; the current one is lit
    component DevicePicker: Flow {
        id: picker

        property var devices: []
        // Node name of the device in use
        property string current: ""
        signal picked(var device)

        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: picker.devices

            TuiButton {
                id: option

                required property var modelData

                implicitWidth: optionLabel.width + 18
                implicitHeight: 26
                active: modelData.name === picker.current
                onClicked: picker.picked(modelData)

                Label {
                    id: optionLabel
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, 300)
                    text: Audio.deviceLabel(option.modelData)
                    color: option.active ? Theme.text : Theme.textDim
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
            }
        }
    }

    // Default output or microphone: where every app goes that was not moved elsewhere
    component MasterRow: Item {
        id: master

        property var device: null
        property var devices: []
        property string key: ""
        property string title: ""
        property bool mic: false
        readonly property bool picking: root.picking === key
        readonly property real volume: device?.audio?.volume ?? 0
        readonly property bool muted: device?.audio?.muted ?? false

        Layout.fillWidth: true
        implicitHeight: masterBody.implicitHeight + 12

        ColumnLayout {
            id: masterBody

            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Label {
                    Layout.preferredWidth: 60
                    text: master.title
                    color: Theme.text
                    font.weight: Font.Medium
                }

                DeviceChip {
                    name: master.device ? Audio.deviceLabel(master.device) : "none"
                    open: master.picking
                    available: master.devices.length > 0
                    onClicked: root.picking = master.picking ? null : master.key
                }

                TuiSlider {
                    Layout.fillWidth: true
                    enabled: master.device !== null
                    value: master.volume
                    dimmed: master.muted
                    onMoved: value => Audio.setVolume(master.device, value)
                }

                Label {
                    Layout.preferredWidth: 52
                    horizontalAlignment: Text.AlignRight
                    text: `${Math.round(master.volume * 100)}%`
                }

                MuteButton {
                    muted: master.muted
                    mic: master.mic
                    available: master.device !== null
                    onClicked: Audio.toggleMute(master.device)
                }
            }

            DevicePicker {
                visible: master.picking
                Layout.leftMargin: 60 + 12
                devices: master.devices
                current: master.device?.name ?? ""
                onPicked: device => {
                    Audio.setDefault(device);
                    root.picking = null;
                }
            }
        }
    }

    component StreamRow: Item {
        id: row

        required property var node
        property var routes: []
        property bool last: false
        // idle and route settle with a delay too: while PipeWire relinks the stream, the
        // row would otherwise dim and lose its chip for a moment
        // No bindings on idle and route: the first change would follow them at once and
        // skip the delay; they start from the live values and then only the timer sets them
        readonly property bool idleNow: Audio.isIdle(node)
        property bool idle: false
        // With a GoXLR the channel key ("music"), without one the device's node name
        readonly property string routeNow: root.goxlr ? Audio.routeOf(node) : Audio.deviceOf(node)?.name ?? ""
        property string route: ""
        Component.onCompleted: {
            idle = idleNow;
            route = routeNow;
        }
        onIdleNowChanged: idleSettle.restart()
        onRouteNowChanged: {
            if (routeNow !== "")
                route = routeNow;
            else
                idleSettle.restart();
        }
        Timer {
            id: idleSettle
            interval: 800
            onTriggered: {
                row.idle = row.idleNow;
                row.route = row.routeNow;
            }
        }
        readonly property real volume: node.audio?.volume ?? 0
        readonly property bool muted: node.audio?.muted ?? false
        readonly property string app: Audio.appName(node)
        readonly property bool picking: root.picking === node

        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + (root.compact ? 12 : 20)
        opacity: idle ? 0.5 : 1
        Behavior on opacity { NumberAnimation { duration: Theme.anim.fast } }

        ColumnLayout {
            id: body

            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 10

            RowLayout {
                id: content

                Layout.fillWidth: true
                spacing: 14

                AppIcon {
                    Layout.alignment: root.compact ? Qt.AlignVCenter : Qt.AlignTop
                    size: root.compact ? 30 : 40
                    icon: Audio.iconName(row.node)
                    glyph: row.app.charAt(0).toUpperCase()
                    tint: Theme.primary
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: root.compact ? 2 : 1
                    columnSpacing: 12
                    rowSpacing: 8

                    // Name and what it plays
                    ColumnLayout {
                        Layout.preferredWidth: root.compact ? 170 : -1
                        Layout.maximumWidth: root.compact ? 170 : 100000
                        Layout.fillWidth: !root.compact
                        spacing: 0

                        RowLayout {
                            spacing: 8
                            Label {
                                Layout.fillWidth: true
                                text: row.app
                                color: Theme.text
                                font.pixelSize: root.compact ? 15 : 16
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Label {
                                visible: row.idle && !root.compact
                                text: "idle"
                                color: Theme.frame
                                font.pixelSize: 12
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: Audio.mediaName(row.node) + (row.idle && root.compact ? " · idle" : "")
                            color: Theme.frame
                            font.pixelSize: root.compact ? 12 : 14
                            elide: Text.ElideRight
                            visible: text !== ""
                        }
                    }

                    // Route chips or device, volume, mute
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        Row {
                            visible: root.goxlr
                            spacing: 6

                            Repeater {
                                model: row.routes

                                TuiButton {
                                    required property string modelData

                                    implicitWidth: chipLabel.implicitWidth + (root.compact ? 14 : 18)
                                    implicitHeight: root.compact ? 22 : 26
                                    active: row.route === modelData
                                    // Show the new chip at once; PipeWire confirms a moment later
                                    onClicked: {
                                        row.route = modelData;
                                        Audio.move(row.node, modelData);
                                    }

                                    Label {
                                        id: chipLabel
                                        anchors.centerIn: parent
                                        text: parent.parent.modelData
                                        color: parent.parent.active ? Theme.text : Theme.muted
                                        font.pixelSize: root.compact ? 12 : 13
                                    }
                                }
                            }
                        }

                        // A paused app has no link and so no device: it plays on the
                        // default one (or the one WirePlumber remembered) once it starts
                        DeviceChip {
                            visible: !root.goxlr
                            name: row.route === "" ? "default" : Audio.deviceLabel(Audio.deviceByName(row.route))
                            maxWidth: root.compact ? 110 : 170
                            open: row.picking
                            onClicked: root.picking = row.picking ? null : row.node
                        }

                        TuiSlider {
                            Layout.fillWidth: true
                            value: row.volume
                            dimmed: row.muted
                            onMoved: value => Audio.setVolume(row.node, value)
                        }

                        Label {
                            Layout.preferredWidth: 52
                            horizontalAlignment: Text.AlignRight
                            text: `${Math.round(row.volume * 100)}%`
                        }

                        // A mic on recording apps only without a GoXLR; with one the row
                        // stays as it always was
                        MuteButton {
                            muted: row.muted
                            mic: !root.goxlr && Audio.isRecording(row.node)
                            onClicked: Audio.toggleMute(row.node)
                        }
                    }
                }
            }

            // Below the row, lined up with the name
            DevicePicker {
                visible: row.picking
                Layout.leftMargin: (root.compact ? 30 : 40) + 14
                devices: Audio.isRecording(row.node) ? Audio.inputs : Audio.sinks
                current: row.route
                // Lit at once like the GoXLR chips; PipeWire confirms a moment later
                onPicked: device => {
                    row.route = device.name;
                    Audio.moveTo(row.node, device);
                    root.picking = null;
                }
            }
        }

        Rectangle {
            visible: !row.last
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: Theme.border
        }
    }

    // Scrollable list of StreamRows with a thin scroll indicator
    component StreamList: Item {
        id: list

        property var nodes: []
        property var routes: []
        property int maxHeight: 470
        property string empty: ""

        Layout.fillWidth: true
        implicitHeight: nodes.length === 0 ? emptyLabel.implicitHeight + 8 : Math.min(listColumn.implicitHeight, maxHeight)

        Label {
            id: emptyLabel
            visible: list.nodes.length === 0
            text: list.empty
            color: Theme.muted
        }

        Flickable {
            id: flick
            anchors.fill: parent
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: listColumn
                width: flick.width - (flick.contentHeight > flick.height ? 12 : 0)
                spacing: 0

                // ScriptModel keeps rows (and a slider being dragged) when PipeWire updates the list
                Repeater {
                    model: ScriptModel {
                        values: list.nodes
                    }

                    StreamRow {
                        required property var modelData
                        required property int index
                        node: modelData
                        routes: list.routes
                        last: index === list.nodes.length - 1
                    }
                }
            }
        }

        Rectangle {
            visible: flick.contentHeight > flick.height
            anchors.right: parent.right
            width: 4
            y: flick.visibleArea.yPosition * flick.height
            height: flick.visibleArea.heightRatio * flick.height
            color: Theme.frame
        }
    }

    // ── Layout ───────────────────────────────────────────────

    // Keeps clicks on the mixer from closing the control center
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
        label: "app mixer"
        borderColor: Theme.primary
        padding: 0
    }

    ColumnLayout {
        id: column

        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 28 }
        spacing: 22

        // Without a GoXLR nothing else sets the overall level, so it sits on top
        Frame {
            visible: !root.goxlr
            Layout.fillWidth: true
            implicitHeight: masterColumn.implicitHeight + 28
            label: "master · default devices"
            labelColor: Theme.muted
            padding: 14

            ColumnLayout {
                id: masterColumn
                anchors { left: parent.left; right: parent.right; top: parent.top }
                spacing: 4

                MasterRow {
                    key: "output"
                    title: "output"
                    device: Audio.defaultSink
                    devices: Audio.sinks
                }
                MasterRow {
                    key: "input"
                    title: "mic"
                    mic: true
                    device: Audio.defaultSource
                    devices: Audio.inputs
                }
            }
        }

        // No app plays or records: a prompt with a blinking cursor instead of two empty lists
        Frame {
            id: emptyFrame

            property bool blink: true

            visible: root.empty
            Layout.fillWidth: true
            implicitHeight: emptyColumn.implicitHeight + 28
            label: "apps"
            labelColor: Theme.muted
            padding: 14

            Timer {
                interval: 530
                repeat: true
                running: root.visible && root.empty
                onTriggered: emptyFrame.blink = !emptyFrame.blink
            }

            Column {
                id: emptyColumn
                anchors { left: parent.left; right: parent.right; top: parent.top }
                spacing: 6

                Row {
                    Label {
                        text: "$ "
                        color: Theme.primary
                    }
                    Label {
                        text: "nothing plays sound right now"
                        color: Theme.textDim
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 9
                        height: 18
                        color: Theme.secondary
                        opacity: emptyFrame.blink ? 1 : 0
                    }
                }
                Label {
                    width: parent.width
                    text: "apps show up here the moment they play or record"
                    color: Theme.frame
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                }
            }
        }

        Frame {
            visible: !root.empty
            Layout.fillWidth: true
            implicitHeight: playbackList.implicitHeight + 28
            label: `playback → ${root.goxlr ? "goxlr channel" : "output"} · ${root.activeCount} active${root.idleCount > 0 ? `, ${root.idleCount} idle` : ""}`
            labelColor: Theme.muted
            padding: 14

            StreamList {
                id: playbackList
                anchors { left: parent.left; right: parent.right; top: parent.top }
                nodes: root.playback
                routes: Audio.outputRoutes
                empty: "nothing is playing"
            }
        }

        Frame {
            visible: !root.empty
            Layout.fillWidth: true
            implicitHeight: recordingList.implicitHeight + 28
            label: root.goxlr ? "recording ← goxlr input" : "recording ← input"
            labelColor: Theme.muted
            padding: 14

            StreamList {
                id: recordingList
                anchors { left: parent.left; right: parent.right; top: parent.top }
                nodes: root.recording
                routes: Audio.inputRoutes
                maxHeight: 220
                empty: "nothing is recording"
            }
        }

        Label {
            Layout.fillWidth: true
            text: !root.goxlr
                ? "the device picked per app is remembered, so it stays there after a restart"
                : Audio.outputRoutes.length === 0
                ? "no goxlr outputs found · check goxlrOutputs in config/Config.qml"
                : "routing is remembered per app, so Spotify stays on music after a restart"
            color: Theme.frame
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }
}
