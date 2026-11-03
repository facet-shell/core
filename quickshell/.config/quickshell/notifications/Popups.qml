import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.config
import qs.services

// Notification popups on the focused screen, where Config.notificationPosition says (top
// right by default). On the right they move left while the control center or the history
// panel is open, so nothing overlaps; at the bottom the newest sits nearest the edge.
Scope {
    id: root

    property int rightOffset: 14
    readonly property string position: Config.notificationPosition
    readonly property string side: Config.side(position)
    readonly property bool top: Config.atTop(position)

    property int animatedOffset: side === "right" ? rightOffset : 14
    Behavior on animatedOffset {
        NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic }
    }

    readonly property ShellScreen focusedScreen: {
        const name = Hyprland.focusedMonitor?.name;
        return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
    }

    PanelWindow {
        screen: root.focusedScreen
        visible: Notifications.popups.length > 0
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-notifications"
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
            right: root.animatedOffset
        }
        implicitWidth: Config.notificationWidth
        implicitHeight: column.implicitHeight + 16

        Column {
            id: column

            y: root.top ? 14 : 2
            width: Config.notificationWidth
            spacing: Config.notificationStyle === "card" ? 20 : 10

            // ScriptModel keeps existing cards (and their timers) when the list changes
            Repeater {
                model: ScriptModel {
                    values: root.top ? Notifications.popups : Notifications.popups.slice().reverse()
                }

                NotificationCard {
                    required property var modelData
                    entry: modelData
                    side: root.side
                    // Narrower ones (minimal) sit on the side the popups are on
                    x: root.side === "left" ? 0 : root.side === "right" ? column.width - width : (column.width - width) / 2
                }
            }

            move: Transition {
                NumberAnimation { properties: "y"; duration: Theme.anim.normal; easing.type: Easing.OutCubic }
            }
        }
    }
}
