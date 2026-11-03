import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.config
import qs.services

// One notification popup, in the look Config.notificationStyle picks: card (the TUI frame
// with picture and buttons), line (one line) or minimal (who and what). On either side the
// icon is on the left and the text left-aligned, the card only slides in from its side; in
// the middle there is no icon and everything is centered. A bar counts down the timeout and pauses while
// hovered; calls pulse green and stay until answered.
Item {
    id: root

    required property var entry
    // "left", "right" or "center", from Popups
    property string side: "right"

    readonly property bool isCall: entry.kind === "call"
    readonly property bool mini: entry.kind === "mini"
    // Minimal has no buttons, so whatever waits for an answer (a call, an invite) is a line
    readonly property string look: Config.notificationStyle === "minimal" && entry.timeout === 0 && entry.actions.length > 0
        ? "line" : Config.notificationStyle
    readonly property bool showIcon: side !== "center"
    // Where the content lines up: left on both sides, centered in the middle
    readonly property string align: side === "center" ? "center" : "left"
    readonly property bool mirrored: false
    readonly property int textAlign: align === "center" ? Text.AlignHCenter : Text.AlignLeft

    readonly property color accent: entry.critical ? Theme.danger
        : isCall ? Theme.ok
        : entry.kind === "voice" ? Theme.accent
        : Theme.border
    readonly property color labelColor: entry.critical ? Theme.danger
        : isCall ? Theme.ok
        : entry.kind === "voice" ? Theme.accent
        : Theme.muted
    readonly property color iconTint: entry.kind === "voice" ? Theme.accent : isCall ? Theme.ok : Theme.primary

    // 1 → 0 over the timeout
    property real remaining: 1
    property bool leaving: false
    property real appear: 0

    implicitWidth: look === "minimal" ? Math.min(Config.notificationWidth, minimalRow.implicitWidth + 28) : Config.notificationWidth
    implicitHeight: look === "card" ? cardContent.implicitHeight + (mini ? 32 : 40)
        : look === "line" ? 48
        : 34
    opacity: leaving ? 0 : appear
    // In from the side it sits on; in the middle it drops in
    readonly property real away: leaving ? 1 : 1 - appear
    transform: Translate {
        x: root.side === "right" ? 30 * root.away : root.side === "left" ? -30 * root.away : 0
        y: root.side === "center" ? -16 * root.away : 0
    }

    Behavior on opacity { NumberAnimation { duration: Theme.anim.fast } }

    Component.onCompleted: appear = 1
    Behavior on appear { NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic } }

    function close(expired) {
        if (leaving)
            return;
        leaving = true;
        closeLater.expired = expired;
        closeLater.start();
    }

    Timer {
        id: closeLater
        property bool expired: false
        interval: Theme.anim.fast + 40
        onTriggered: Notifications.dismiss(root.entry.uid, expired)
    }

    NumberAnimation on remaining {
        from: 1
        to: 0
        duration: Math.max(1, root.entry.timeout)
        running: root.entry.timeout > 0
        paused: hover.hovered
        onFinished: root.close(true)
    }

    HoverHandler {
        id: hover
    }

    // Calls pulse until accepted or declined
    property color lineColor: accent
    SequentialAnimation on lineColor {
        running: root.isCall
        loops: Animation.Infinite
        ColorAnimation { to: Theme.border; duration: 600; easing.type: Easing.InOutSine }
        ColorAnimation { to: Theme.ok; duration: 600; easing.type: Easing.InOutSine }
    }

    // ── Pieces ───────────────────────────────────────────────

    // An action of the notification; uid says which one it belongs to
    component ActionButton: TuiButton {
        id: action

        required property var modelData
        property int uid
        readonly property color tone: modelData.style === "ok" ? Theme.ok
            : modelData.style === "no" ? Theme.danger
            : Theme.secondary

        implicitWidth: actionLabel.implicitWidth + 24
        implicitHeight: 26
        accent: tone
        border.color: modelData.style !== "" ? tone : hovered ? Theme.primary : Theme.border
        onClicked: Notifications.invoke(uid, modelData.id)

        // The label's parent is the button's inner item, so go by id
        Text {
            id: actionLabel
            anchors.centerIn: parent
            text: action.modelData.label
            color: action.tone
            font.family: Theme.font
            font.pixelSize: 13
        }
    }

    component CloseButton: TuiButton {
        id: closer

        implicitWidth: 26
        implicitHeight: 24
        // Framed like the other buttons, the accent while hovered
        border.color: hovered ? Theme.primary : Theme.border

        Text {
            anchors.centerIn: parent
            text: "×"
            color: closer.hovered ? Theme.text : Theme.muted
            font.family: Theme.font
            font.pixelSize: 15
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        opacity: root.look === "minimal" ? 0.9 : 0.96
    }

    // ── card ─────────────────────────────────────────────────

    Frame {
        anchors.fill: parent
        visible: root.look === "card"
        label: `${root.entry.app} · ${Notifications.ago(root.entry.time)}`
        labelAlign: root.align
        borderColor: root.isCall ? root.lineColor : root.accent
        labelColor: root.labelColor
        padding: 0
    }

    RowLayout {
        id: cardContent

        visible: root.look === "card"
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: root.mirrored ? 14 : 16; rightMargin: root.mirrored ? 16 : 14; topMargin: root.mini ? 18 : 22 }
        layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
        spacing: 14

        AppIcon {
            visible: root.showIcon
            Layout.alignment: Qt.AlignTop
            size: root.mini ? 30 : 44
            icon: root.entry.image
            glyph: root.entry.glyph
            tint: root.iconTint
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                Layout.fillWidth: true
                // Room for the close button on its side (both sides in the middle, so it stays centered)
                Layout.rightMargin: root.isCall || root.mirrored ? 0 : 30
                Layout.leftMargin: !root.isCall && root.align !== "left" ? 30 : 0
                horizontalAlignment: root.textAlign
                text: root.entry.title
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: root.mini ? 15 : 16
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                horizontalAlignment: root.textAlign
                text: root.entry.body
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: root.mini ? 13 : 15
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            Row {
                Layout.topMargin: 10
                Layout.alignment: root.align === "right" ? Qt.AlignRight : root.align === "center" ? Qt.AlignHCenter : Qt.AlignLeft
                visible: root.entry.actions.length > 0
                layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
                spacing: 8

                Repeater {
                    model: root.entry.actions

                    ActionButton {
                        uid: root.entry.uid
                    }
                }
            }
        }
    }

    // Close button in the corner away from the icon; calls have to be answered instead
    CloseButton {
        visible: root.look === "card" && !root.isCall
        anchors { top: parent.top; topMargin: 12 }
        x: root.mirrored ? 10 : parent.width - width - 10
        onClicked: root.close(false)
    }

    // ── line ─────────────────────────────────────────────────

    // A stripe on the icon's side marks it; in the middle a line along the bottom
    Rectangle {
        visible: root.look === "line"
        x: root.mirrored ? parent.width - width : 0
        width: root.align === "center" ? parent.width : 3
        height: root.align === "center" ? 2 : parent.height
        y: root.align === "center" ? parent.height - height : 0
        color: root.isCall ? root.lineColor : root.entry.critical ? Theme.danger : Theme.primary
    }

    Rectangle {
        anchors.fill: parent
        visible: root.look === "line"
        color: "transparent"
        border.width: 1
        border.color: Theme.border
    }

    RowLayout {
        visible: root.look === "line"
        anchors { fill: parent; leftMargin: 14; rightMargin: 10 }
        layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
        spacing: 10

        AppIcon {
            visible: root.showIcon
            size: 26
            icon: root.entry.image
            glyph: root.entry.glyph
            tint: root.iconTint
        }

        Text {
            text: root.entry.app
            color: root.labelColor
            font.family: Theme.font
            font.pixelSize: 12
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: root.textAlign
            text: root.entry.body !== "" ? `${root.entry.title}  ·  ${root.entry.body}` : root.entry.title
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 14
            elide: Text.ElideRight
        }

        Repeater {
            model: root.entry.actions

            ActionButton {
                uid: root.entry.uid
            }
        }

        CloseButton {
            visible: !root.isCall
            onClicked: root.close(false)
        }
    }

    // ── minimal ──────────────────────────────────────────────

    Row {
        id: minimalRow

        visible: root.look === "minimal"
        anchors.centerIn: parent
        layoutDirection: root.mirrored ? Qt.RightToLeft : Qt.LeftToRight
        spacing: 10

        Text {
            text: root.entry.app
            color: root.entry.critical ? Theme.danger : Theme.primary
            font.family: Theme.font
            font.pixelSize: 13
        }
        Text {
            width: Math.min(implicitWidth, Config.notificationWidth - 60)
            text: root.entry.title
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 13
            elide: Text.ElideRight
        }
    }

    Rectangle {
        visible: root.look === "minimal"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: root.entry.critical ? Theme.danger : Theme.primary
    }

    // A click on a minimal one puts it away
    MouseArea {
        anchors.fill: parent
        visible: root.look === "minimal"
        onClicked: root.close(false)
    }

    // Time left, shrinking toward the side it sits on
    Rectangle {
        visible: root.entry.timeout > 0 && root.look !== "minimal"
        y: parent.height - height
        width: parent.width * root.remaining
        x: root.align === "right" ? parent.width - width : root.align === "center" ? (parent.width - width) / 2 : 0
        height: 2
        color: root.entry.critical ? Theme.danger : Theme.primary
    }
}
