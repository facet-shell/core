import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.config
import qs.services

// Zoomed-out view of the infinite canvas (facet layout canvas) on the focused screen.
// Super+wheel down opens it: the desktop shrinks until every screen and every window is
// in view, each window a live preview, each screen an outline. The screens stay where
// they are (layout coordinates): moving a view moves its windows across the map, the
// frames never drift apart, so you always know which screen you are looking at. The wheel zooms around the
// cursor, dragging empty canvas moves the map, dragging a window moves the window (onto
// another screen's canvas too), dragging a window's bottom right corner resizes it, a
// click on a window focuses it and brings it to the middle of its screen, a click on empty
// canvas looks there. Zooming in past 1:1 picks what is under the cursor. Keys work on the
// window under the cursor (or the focused one): F fullscreen on the screen it is on,
// Enter go there, Q close it. Esc or right click goes back without changing anything.
//
// `qs ipc call overview toggle|open|close|zoomIn|zoomOut`; the Super+wheel binds are in
// hypr/frame/canvas.lua, everything else the overlay handles itself.
Scope {
    id: root

    property bool hidden: false
    property bool open: false

    property real shown: open && !hidden ? 1 : 0
    Behavior on shown {
        NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic }
    }

    // Canvas point in the middle of the screen and the scale canvas → screen
    property real cx: 0
    property real cy: 0
    property real zoom: 1
    Behavior on cx {
        id: cxAnim
        enabled: !area.dragging
        NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic }
    }
    Behavior on cy {
        id: cyAnim
        enabled: !area.dragging
        NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic }
    }
    Behavior on zoom {
        id: zoomAnim
        NumberAnimation { duration: Theme.anim.normal; easing.type: Easing.OutCubic }
    }

    readonly property real margin: 90
    readonly property real step: 1.25

    // The screen the overview is on; the map is in layout coordinates, so its middle is fixed
    property string screenName: ""
    readonly property var screenMon: CanvasLayout.monitor(screenName)
    readonly property real camCx: screenMon ? screenMon.x + screenMon.w / 2 : 0
    readonly property real camCy: screenMon ? screenMon.y + screenMon.h / 2 : 0

    // A window's place in layout coordinates: its canvas place minus its screen's camera
    function layoutX(w) {
        return w.x - (CanvasLayout.monitor(w.monitor)?.camera.x ?? 0);
    }
    function layoutY(w) {
        return w.y - (CanvasLayout.monitor(w.monitor)?.camera.y ?? 0);
    }

    // Every screen and every window, in layout coordinates
    function bounds() {
        let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
        for (const m of CanvasLayout.monitors) {
            x1 = Math.min(x1, m.x);
            y1 = Math.min(y1, m.y);
            x2 = Math.max(x2, m.x + m.w);
            y2 = Math.max(y2, m.y + m.h);
        }
        for (const w of CanvasLayout.windows) {
            const lx = layoutX(w), ly = layoutY(w);
            x1 = Math.min(x1, lx);
            y1 = Math.min(y1, ly);
            x2 = Math.max(x2, lx + w.w);
            y2 = Math.max(y2, ly + w.h);
        }
        if (x1 === Infinity)
            return { x: 0, y: 0, w: window.width, h: window.height };
        return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
    }

    // Everything in view, never larger than 0.6 so the overview always reads as zoomed out
    function fitZoom() {
        const b = bounds();
        return Math.min(0.6, (window.width - 2 * margin) / Math.max(1, b.w), (window.height - 2 * margin) / Math.max(1, b.h));
    }

    function toCanvasX(sx) { return (sx - window.width / 2) / zoom + cx; }
    function toCanvasY(sy) { return (sy - window.height / 2) / zoom + cy; }

    // A window being dragged: its address and where its top left corner is on the canvas.
    // The preview follows the mouse at once; Hyprland gets the position a few times a
    // second and once more on release, and the override stays until that move shows up
    property var drag: null

    // A window being resized from its corner: address and new size, same idea as drag
    property var resize: null

    function sizeW(w) { return resize && resize.address === w.address ? resize.w : w.w; }
    function sizeH(w) { return resize && resize.address === w.address ? resize.h : w.h; }

    function windowAt(x, y) {
        const list = CanvasLayout.windows;
        for (let i = list.length - 1; i >= 0; i--) {
            const w = list[i];
            const wx = drag && drag.address === w.address ? drag.x : layoutX(w);
            const wy = drag && drag.address === w.address ? drag.y : layoutY(w);
            if (x >= wx && x < wx + sizeW(w) && y >= wy && y < wy + sizeH(w))
                return w;
        }
        return null;
    }

    // The grab zone in the bottom right corner of a window, in screen pixels
    function grip(w) {
        return Math.max(14, Math.min(28, Math.min(sizeW(w), sizeH(w)) * zoom * 0.25));
    }

    // The window whose corner grip is under screen point sx, sy
    function cornerAt(sx, sy) {
        const w = windowAt(toCanvasX(sx), toCanvasY(sy));
        if (!w)
            return null;
        const right = window.width / 2 + (layoutX(w) + sizeW(w) - cx) * zoom;
        const bottom = window.height / 2 + (layoutY(w) + sizeH(w) - cy) * zoom;
        const g = grip(w);
        return right - sx <= g && bottom - sy <= g ? w : null;
    }

    // The window a key acts on: under the cursor, otherwise the focused one
    function keyTarget() {
        return area.hoverWindow ?? CanvasLayout.windows.find(w => w.active) ?? null;
    }

    // F: fullscreen on the screen the window sits on, and the overview goes away
    function fullscreenTarget() {
        const w = keyTarget();
        if (!w)
            return;
        CanvasLayout.fullscreen(w.address);
        close(layoutX(w) + sizeW(w) / 2, layoutY(w) + sizeH(w) / 2);
    }

    // Q: the window is asked to close; the overview stays open
    function closeTarget() {
        const w = keyTarget();
        if (w)
            CanvasLayout.closeWindow(w.address);
    }

    // Enter: like a click on the window
    function pickTarget() {
        const w = keyTarget();
        if (w) {
            CanvasLayout.select(w.address);
            close(layoutX(w) + sizeW(w) / 2, layoutY(w) + sizeH(w) / 2);
        }
    }

    function focusedScreen() {
        const name = Hyprland.focusedMonitor?.name;
        return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
    }

    // Starts at 1:1 on the current view, then zooms out until everything fits
    function show() {
        if (hidden || open || !CanvasLayout.enabled)
            return;
        area.pressSeen = false;
        const screen = focusedScreen();
        window.screen = screen;
        screenName = screen?.name ?? "";
        window.visible = true;
        jump(camCx, camCy, 1);
        open = true;
        const b = bounds();
        cx = b.x + b.w / 2;
        cy = b.y + b.h / 2;
        zoom = fitZoom();
    }

    // Without animation
    function jump(x, y, z) {
        const anims = [cxAnim, cyAnim, zoomAnim];
        const was = anims.map(a => a.enabled);
        anims.forEach(a => a.enabled = false);
        cx = x;
        cy = y;
        zoom = z;
        anims.forEach((a, i) => a.enabled = was[i]);
    }

    // Zooms back to 1:1 on (x, y) while fading out; the desktop below is moved there meanwhile
    function close(x, y) {
        if (!open)
            return;
        dragEnd();
        cx = x ?? camCx;
        cy = y ?? camCy;
        zoom = 1;
        open = false;
    }

    // Window under the cursor: focus and center it; empty canvas: look there
    function pick(sx, sy) {
        const x = toCanvasX(sx), y = toCanvasY(sy);
        const w = windowAt(x, y);
        if (w) {
            CanvasLayout.select(w.address);
            close(layoutX(w) + w.w / 2, layoutY(w) + w.h / 2);
        } else {
            // Hyprland thinks in canvas coordinates
            const c = CanvasLayout.toCanvas(x, y);
            CanvasLayout.lookAt(c.x, c.y, c.monitor);
            close(x, y);
        }
    }

    function zoomAround(sx, sy, factor) {
        const x = toCanvasX(sx), y = toCanvasY(sy);
        const z = Math.max(fitZoom() * 0.4, Math.min(1, zoom * factor));
        cx = x - (sx - window.width / 2) / z;
        cy = y - (sy - window.height / 2) / z;
        zoom = z;
    }

    function zoomIn(sx, sy) {
        if (!open)
            return;
        if (zoom * step >= 0.95)
            pick(sx, sy);
        else
            zoomAround(sx, sy, step);
    }

    function zoomOut(sx, sy) {
        if (!open)
            show();
        else
            zoomAround(sx, sy, 1 / step);
    }

    function dragTo(x, y) {
        if (!drag)
            return;
        drag = { address: drag.address, x: x, y: y };
        if (!dragSend.running)
            dragSend.start();
    }

    // The window's top left corner on the map → canvas coordinates of the screen it is over
    // Only the drop (final) may move it to another monitor (canvas.lua move_to)
    function sendDrag(final) {
        const c = CanvasLayout.toCanvas(drag.x + 1, drag.y + 1);
        CanvasLayout.moveTo(drag.address, c.x, c.y, c.monitor, final);
    }

    function dragEnd() {
        if (!drag)
            return;
        dragSend.stop();
        sendDrag(true);
        dragSettle.restart();
    }

    Timer {
        id: dragSend
        interval: 120
        onTriggered: if (root.drag) root.sendDrag()
    }
    // Not while the next drag already started within that time
    Timer {
        id: dragSettle
        interval: 700
        onTriggered: if (!area.movingWindow) root.drag = null
    }

    function resizeTo(w, h) {
        if (!resize)
            return;
        resize = { address: resize.address, w: Math.max(100, w), h: Math.max(80, h) };
        if (!resizeSend.running)
            resizeSend.start();
    }

    function sendResize() {
        CanvasLayout.resizeTo(resize.address, resize.w, resize.h);
    }

    function resizeEnd() {
        if (!resize)
            return;
        resizeSend.stop();
        sendResize();
        resizeSettle.restart();
    }

    Timer {
        id: resizeSend
        interval: 120
        onTriggered: if (root.resize) root.sendResize()
    }
    Timer {
        id: resizeSettle
        interval: 700
        onTriggered: if (!area.resizingWindow) root.resize = null
    }

    onHiddenChanged: if (hidden) open = false
    // Super + mouse would still drag the windows behind the overlay
    onOpenChanged: CanvasLayout.overview(open)

    PanelWindow {
        id: window

        visible: false
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-overview"
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Gone once the fade finished
        Timer {
            running: !root.open && window.visible && root.shown < 0.01
            interval: 50
            onTriggered: window.visible = false
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.bg
            opacity: 0.88 * root.shown
        }

        // Fine grid in canvas coordinates, so the map is seen to move
        Canvas {
            id: grid
            anchors.fill: parent
            opacity: 0.5 * root.shown
            readonly property real spacing: 200
            Connections {
                target: root
                function onCxChanged() { grid.requestPaint(); }
                function onCyChanged() { grid.requestPaint(); }
                function onZoomChanged() { grid.requestPaint(); }
            }
            onPaint: {
                const ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                const s = spacing * root.zoom;
                if (s < 24)
                    return;
                ctx.strokeStyle = Theme.border;
                ctx.lineWidth = 1;
                const ox = width / 2 - root.cx * root.zoom;
                const oy = height / 2 - root.cy * root.zoom;
                ctx.beginPath();
                for (let x = ox % s; x < width; x += s) {
                    ctx.moveTo(Math.round(x) + 0.5, 0);
                    ctx.lineTo(Math.round(x) + 0.5, height);
                }
                for (let y = oy % s; y < height; y += s) {
                    ctx.moveTo(0, Math.round(y) + 0.5);
                    ctx.lineTo(width, Math.round(y) + 0.5);
                }
                ctx.stroke();
            }
        }

        Item {
            id: map
            anchors.fill: parent
            opacity: root.shown

            // Every screen as it is now
            Repeater {
                model: ScriptModel {
                    values: CanvasLayout.monitors
                    objectProp: "name"
                }

                Item {
                    id: mon

                    required property var modelData
                    readonly property bool here: modelData.name === root.screenName

                    x: window.width / 2 + (modelData.x - root.cx) * root.zoom
                    y: window.height / 2 + (modelData.y - root.cy) * root.zoom
                    width: modelData.w * root.zoom
                    height: modelData.h * root.zoom

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface
                        opacity: mon.here ? 0.5 : 0.3
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: mon.here ? Theme.secondary : Theme.frame
                    }
                    Text {
                        anchors { left: parent.left; top: parent.top; margins: 8 }
                        text: mon.modelData.name
                        color: mon.here ? Theme.secondary : Theme.frame
                        font.family: Theme.font
                        font.pixelSize: Theme.size.small
                    }
                }
            }

            // Each delegate sticks to its window (address): without that a changed order in
            // the list handed delegates another window, and the capture kept showing the
            // old one's picture when the new one gave no frame
            Repeater {
                model: ScriptModel {
                    values: CanvasLayout.windows
                    objectProp: "address"
                }

                Item {
                    id: win

                    required property var modelData
                    readonly property bool hovered: area.hoverWindow !== null && area.hoverWindow.address === modelData.address
                    readonly property bool dragged: root.drag !== null && root.drag.address === modelData.address
                    readonly property bool resized: root.resize !== null && root.resize.address === modelData.address
                    readonly property real canvasX: dragged ? root.drag.x : root.layoutX(modelData)
                    readonly property real canvasY: dragged ? root.drag.y : root.layoutY(modelData)
                    readonly property var toplevel: {
                        const wanted = String(modelData.address ?? "").replace(/^0x/, "").toLowerCase();
                        const t = Hyprland.toplevels.values.find(t => String(t.address ?? "").replace(/^0x/, "").toLowerCase() === wanted);
                        return t?.wayland ?? null;
                    }

                    x: window.width / 2 + (canvasX - root.cx) * root.zoom
                    y: window.height / 2 + (canvasY - root.cy) * root.zoom
                    width: Math.max(2, root.sizeW(modelData) * root.zoom)
                    height: Math.max(2, root.sizeH(modelData) * root.zoom)
                    z: dragged || resized ? 2 : hovered ? 1 : 0

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface2
                    }

                    ScreencopyView {
                        id: preview
                        anchors.fill: parent
                        captureSource: win.toplevel
                        live: true
                        paintCursor: false
                    }

                    // Hyprland gives no picture of a window that lies fully off every screen:
                    // the last one taken while it was on one (CanvasThumbs.qml)
                    Image {
                        id: cached
                        anchors.fill: parent
                        visible: !preview.hasContent && source != ""
                        source: Thumbnails.url(win.modelData.address)
                        asynchronous: true
                        cache: false
                        fillMode: Image.Stretch
                    }

                    // No preview yet (or the window has none): class and title
                    Column {
                        anchors.centerIn: parent
                        visible: !preview.hasContent && !cached.visible
                        width: parent.width - 24
                        spacing: 4
                        Text {
                            width: parent.width
                            text: win.modelData.class
                            color: Theme.text
                            font.family: Theme.font
                            font.pixelSize: Math.max(10, Math.min(22, 18 * root.zoom / 0.6))
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: win.modelData.title
                            color: Theme.muted
                            font.family: Theme.font
                            font.pixelSize: Math.max(9, Math.min(16, 14 * root.zoom / 0.6))
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            visible: win.height > 60
                        }
                    }

                    // Dim everything the cursor is not on
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.bg
                        opacity: win.hovered || win.dragged || win.resized || win.modelData.active ? 0 : 0.35
                        Behavior on opacity { NumberAnimation { duration: Theme.anim.fast } }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: win.hovered || win.dragged || win.resized ? 2 : 1
                        border.color: win.hovered || win.dragged || win.resized ? Theme.text : win.modelData.active ? Theme.primary : Theme.frame
                    }

                    // Resize grip in the bottom right corner while hovered; the size while resizing
                    Rectangle {
                        anchors { right: parent.right; bottom: parent.bottom }
                        width: root.grip(win.modelData)
                        height: width
                        color: win.resized ? Theme.text : "transparent"
                        border.width: 2
                        border.color: Theme.text
                        visible: win.hovered || win.resized
                        opacity: win.resized ? 1 : 0.7
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: win.resized
                        text: `${Math.round(root.sizeW(win.modelData))} × ${Math.round(root.sizeH(win.modelData))}`
                        color: Theme.text
                        font.family: Theme.font
                        font.pixelSize: 15
                        style: Text.Outline
                        styleColor: Theme.bg
                    }

                    // Title above the window while hovered or dragged
                    Rectangle {
                        anchors { left: parent.left; bottom: parent.top; bottomMargin: 6 }
                        width: Math.min(Math.max(win.width, 120), titleLabel.implicitWidth + 16)
                        height: 24
                        color: Theme.bg
                        border.width: 1
                        border.color: Theme.text
                        visible: win.hovered || win.dragged || win.resized
                        Text {
                            id: titleLabel
                            anchors.centerIn: parent
                            width: parent.width - 16
                            text: `${win.modelData.class} · ${win.modelData.title}`
                            color: Theme.text
                            font.family: Theme.font
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        // Position and help
        Text {
            anchors { left: parent.left; top: parent.top; margins: 28 }
            text: `${CanvasLayout.short(root.toCanvasX(area.hoverX))}, ${CanvasLayout.short(root.toCanvasY(area.hoverY))} · ${Math.round(root.zoom * 100)}% · ${CanvasLayout.windows.length} windows`
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.size.small
            opacity: root.shown
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
            text: "wheel · zoom    drag window · move    drag corner · resize    click / enter · go there    f · fullscreen    q · close    esc · back"
            color: Theme.frame
            font.family: Theme.font
            font.pixelSize: Theme.size.small
            opacity: root.shown
        }

        MouseArea {
            id: area

            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: resizingWindow || hoverCorner ? Qt.SizeFDiagCursor : dragging || movingWindow ? Qt.ClosedHandCursor : hoverWindow ? Qt.OpenHandCursor : Qt.ArrowCursor

            property real hoverX: width / 2
            property real hoverY: height / 2
            readonly property var hoverWindow: root.open && !dragging && !movingWindow && !resizingWindow ? root.windowAt(root.toCanvasX(hoverX), root.toCanvasY(hoverY)) : null
            readonly property bool hoverCorner: hoverWindow !== null && root.cornerAt(hoverX, hoverY) !== null

            // dragging: the map moves; movingWindow: the pressed window moves; resizingWindow: its corner
            property bool dragging: false
            property bool movingWindow: false
            property bool resizingWindow: false
            property var pressedWindow: null
            // Opened while a Hyprland window drag was going on (Super+drag, then the wheel):
            // the button's release reaches the overlay without a press and must not count
            property bool pressSeen: false
            property real pressX: 0
            property real pressY: 0
            property real startCx: 0
            property real startCy: 0
            // Where inside the window it was grabbed, in canvas pixels
            property real grabX: 0
            property real grabY: 0

            onPressed: mouse => {
                pressSeen = true;
                pressX = mouse.x;
                pressY = mouse.y;
                startCx = root.cx;
                startCy = root.cy;
                dragging = false;
                movingWindow = false;
                resizingWindow = false;
                pressedWindow = mouse.button === Qt.LeftButton ? root.windowAt(root.toCanvasX(mouse.x), root.toCanvasY(mouse.y)) : null;
                if (pressedWindow && root.cornerAt(mouse.x, mouse.y)) {
                    resizingWindow = true;
                    resizeSettle.stop();
                    root.resize = { address: pressedWindow.address, w: root.sizeW(pressedWindow), h: root.sizeH(pressedWindow) };
                    return;
                }
                if (pressedWindow) {
                    grabX = root.toCanvasX(mouse.x) - root.layoutX(pressedWindow);
                    grabY = root.toCanvasY(mouse.y) - root.layoutY(pressedWindow);
                }
            }
            onPositionChanged: mouse => {
                hoverX = mouse.x;
                hoverY = mouse.y;
                if (!pressed || !(mouse.buttons & (Qt.LeftButton | Qt.MiddleButton)))
                    return;
                const moved = Math.hypot(mouse.x - pressX, mouse.y - pressY) > 6;
                if (resizingWindow && pressedWindow) {
                    root.resizeTo(root.toCanvasX(mouse.x) - root.layoutX(pressedWindow), root.toCanvasY(mouse.y) - root.layoutY(pressedWindow));
                    return;
                }
                if (pressedWindow && (mouse.buttons & Qt.LeftButton)) {
                    if (!movingWindow && moved) {
                        movingWindow = true;
                        dragSettle.stop();
                        root.drag = { address: pressedWindow.address, x: root.layoutX(pressedWindow), y: root.layoutY(pressedWindow) };
                    }
                    if (movingWindow)
                        root.dragTo(root.toCanvasX(mouse.x) - grabX, root.toCanvasY(mouse.y) - grabY);
                    return;
                }
                if (!dragging && moved)
                    dragging = true;
                if (dragging) {
                    root.cx = startCx - (mouse.x - pressX) / root.zoom;
                    root.cy = startCy - (mouse.y - pressY) / root.zoom;
                }
            }
            onReleased: mouse => {
                if (!pressSeen)
                    return;
                pressSeen = false;
                if (resizingWindow) {
                    resizingWindow = false;
                    pressedWindow = null;
                    root.resizeEnd();
                    return;
                }
                if (movingWindow) {
                    movingWindow = false;
                    pressedWindow = null;
                    root.dragEnd();
                    return;
                }
                pressedWindow = null;
                if (dragging) {
                    dragging = false;
                    return;
                }
                if (mouse.button === Qt.RightButton)
                    root.close();
                else if (mouse.button === Qt.LeftButton)
                    root.pick(mouse.x, mouse.y);
            }
            onWheel: wheel => {
                hoverX = wheel.x;
                hoverY = wheel.y;
                if (wheel.angleDelta.y > 0)
                    root.zoomIn(wheel.x, wheel.y);
                else if (wheel.angleDelta.y < 0)
                    root.zoomOut(wheel.x, wheel.y);
            }
        }

        FocusScope {
            anchors.fill: parent
            focus: root.open
            Keys.onEscapePressed: root.close()
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_F:
                    root.fullscreenTarget();
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    root.pickTarget();
                    break;
                case Qt.Key_Q:
                case Qt.Key_Delete:
                    root.closeTarget();
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }
        }
    }

    // The other screens while the overview is open: a click on one of them closes it (the
    // click goes no further; the next one lands where it was aimed)
    Variants {
        model: root.open ? Quickshell.screens.filter(s => s.name !== root.screenName) : []

        PanelWindow {
            required property var modelData

            screen: modelData
            visible: root.open
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qs-overview-other"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: root.close()
            }
        }
    }

    IpcHandler {
        target: "overview"

        function open(): void {
            root.show();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            if (root.open)
                root.close();
            else
                root.show();
        }

        // Super+wheel from Hyprland: around wherever the cursor is
        function zoomIn(): void {
            root.zoomIn(area.hoverX, area.hoverY);
        }

        function zoomOut(): void {
            root.zoomOut(area.hoverX, area.hoverY);
        }
    }
}
