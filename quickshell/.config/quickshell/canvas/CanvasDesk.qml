import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// The desk behind the windows (facet layout canvas): a see-through layer on every screen
// that only the empty canvas lets clicks through to. Dragging it with the left or middle
// button moves the view, the wheel moves it too (Shift: sideways). Hyprland handles
// Super + mouse on its own, so this never sees those.
Scope {
    id: root

    readonly property int wheelPx: 160

    Variants {
        model: CanvasLayout.enabled ? Quickshell.screens : []

        PanelWindow {
            id: desk

            required property ShellScreen modelData

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.namespace: "qs-canvas-desk"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            MouseArea {
                id: area

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor

                property real lastX: 0
                property real lastY: 0
                // Movement since the last step sent to Hyprland
                property real dueX: 0
                property real dueY: 0
                property bool moved: false

                function flush() {
                    if (dueX === 0 && dueY === 0)
                        return;
                    CanvasLayout.dragBy(-dueX, -dueY, desk.modelData.name);
                    dueX = 0;
                    dueY = 0;
                }

                onPressed: mouse => {
                    lastX = mouse.x;
                    lastY = mouse.y;
                    dueX = 0;
                    dueY = 0;
                    moved = false;
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return;
                    dueX += mouse.x - lastX;
                    dueY += mouse.y - lastY;
                    lastX = mouse.x;
                    lastY = mouse.y;
                    moved = true;
                    if (!step.running)
                        step.start();
                }
                onReleased: {
                    step.stop();
                    flush();
                    if (moved)
                        CanvasLayout.dragDone();
                }
                onWheel: wheel => {
                    const d = wheel.angleDelta.y > 0 ? -root.wheelPx : root.wheelPx;
                    if (wheel.modifiers & Qt.ShiftModifier)
                        CanvasLayout.pan(d, 0, desk.modelData.name);
                    else
                        CanvasLayout.pan(0, d, desk.modelData.name);
                }

                // Hyprland gets at most one step every 40 ms, the window animation smooths it
                Timer {
                    id: step
                    interval: 40
                    repeat: true
                    onTriggered: area.flush()
                }
            }
        }
    }
}
