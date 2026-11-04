import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.config
import qs.services

// Super+P: draw on the live desktop. A see-through layer over every screen (Overlay) with
// the toolbar at the bottom of the screen that had focus. Super+P again hides the drawing
// and gives the screens back; it is still there next time, also after a shell restart
// (DrawDoc, draw.json). Super+Shift+P clears it. "click through" keeps the drawing on
// screen while mouse and keys go to the windows; only the toolbar still takes clicks.
// With the infinite canvas (facet layout canvas) the drawing lives in canvas coordinates
// like the windows: it moves when the view moves, and right drag on it moves the view.
// Without it, in layout coordinates (where the screens are).
// Keys: the tool letters (p h l a r e t x), Ctrl+Z / Ctrl+Shift+Z, Esc hides.
// `qs ipc call draw toggle|show|hide|clear|through`
Scope {
    id: root

    property bool hidden: false
    property bool open: false
    // The screen with the toolbar (focused when opened), and the one that takes the keys
    // (the one last drawn on)
    property string barScreen: ""
    property string keyScreen: ""

    function show() {
        if (hidden)
            return;
        const screens = Quickshell.screens.map(s => s.name);
        const focused = Hyprland.focusedMonitor?.name ?? "";
        barScreen = screens.includes(focused) ? focused : screens[0] ?? "";
        keyScreen = barScreen;
        drawTools.through = false;
        open = true;
    }

    function hide() {
        open = false;
        drawTools.through = false;
        doc.writeNow();
    }

    function toggle() {
        if (open)
            hide();
        else
            show();
    }

    onHiddenChanged: {
        if (hidden)
            hide();
    }

    DrawTools {
        id: drawTools
    }

    DrawDoc {
        id: doc
    }

    Variants {
        model: root.open ? Quickshell.screens : []

        PanelWindow {
            id: win

            required property ShellScreen modelData
            readonly property bool hasBar: modelData.name === root.barScreen
            // This screen's view of the canvas, plus drag steps the map does not have yet
            readonly property var mon: CanvasLayout.enabled ? CanvasLayout.monitor(modelData.name) : null
            readonly property var view: mon ? CanvasLayout.viewOf(mon) : null
            readonly property var pend: CanvasLayout.pending[modelData.name] ?? null

            // Right drag: steps to Hyprland at most every 40 ms, like the canvas desk
            property real dueX: 0
            property real dueY: 0

            function flush() {
                if (dueX === 0 && dueY === 0)
                    return;
                CanvasLayout.dragBy(-dueX, -dueY, modelData.name);
                dueX = 0;
                dueY = 0;
            }

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qs-draw"
            WlrLayershell.keyboardFocus: !drawTools.through && root.keyScreen === modelData.name
                ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // Click through: only the toolbar takes the mouse, the rest goes to the windows
            mask: Region {
                item: !drawTools.through ? canvas : win.hasBar ? bar : null
            }

            Timer {
                id: step
                interval: 40
                repeat: true
                onTriggered: win.flush()
            }

            Item {
                id: keys

                anchors.fill: parent
                focus: true

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape)
                        root.hide();
                    else if (!bar.handleKey(event))
                        return;
                    event.accepted = true;
                }
            }

            DrawCanvas {
                id: canvas

                anchors.fill: parent
                store: doc
                tools: drawTools
                originX: win.view ? win.view.x + (win.pend?.x ?? 0) : win.modelData.x
                originY: win.view ? win.view.y + (win.pend?.y ?? 0) : win.modelData.y
                active: !drawTools.through
                placesRuler: win.hasBar
                keyTarget: keys
                rightDragPans: CanvasLayout.enabled
                onTouched: {
                    root.keyScreen = win.modelData.name;
                    if (!typing)
                        keys.forceActiveFocus();
                }
                onPanBy: (dx, dy) => {
                    win.dueX += dx;
                    win.dueY += dy;
                    if (!step.running)
                        step.start();
                }
                onPanDone: {
                    step.stop();
                    win.flush();
                    CanvasLayout.dragDone();
                }
            }

            DrawToolbar {
                id: bar

                visible: win.hasBar
                tools: drawTools
                store: doc
                vertical: drawTools.docked
                overlayButtons: true
                title: drawTools.through ? "draw · clicks go through" : "draw"
                x: drawTools.docked ? 24 : Math.round((parent.width - width) / 2)
                y: drawTools.docked ? Math.round((parent.height - height) / 2) : parent.height - height - Math.round(parent.height * 0.04)
                width: implicitWidth
                height: implicitHeight
            }
        }
    }

    IpcHandler {
        target: "draw"

        function toggle(): void {
            root.toggle();
        }

        function show(): void {
            root.show();
        }

        function hide(): void {
            root.hide();
        }

        // Super+Shift+P; undo brings it back while drawing
        function clear(): void {
            doc.clearShapes();
        }

        function through(): void {
            if (root.open)
                drawTools.through = !drawTools.through;
        }
    }
}
