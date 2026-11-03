import QtQuick
import qs.config
import "DrawEngine.js" as Engine

// One view of a drawing: paints the store's shapes and, while `active`, draws into it with
// what the tools picked. The store is a DrawDoc (screen) or the picture editor's
// ImageProject; both keep shapes in document units, shown here as
// item = (doc - origin) * scale. Used once per screen by DrawOverlay.qml and once in the
// picture editor.
Item {
    id: root

    required property var store
    required property DrawTools tools
    property real originX: 0
    property real originY: 0
    property real scale: 1
    property bool active: true
    // Turning the ruler on puts it in this view (the screen with the toolbar, the editor)
    property bool placesRuler: true
    // Gets the keys back once a text is placed or given up
    property Item keyTarget: null
    // Right drag moves the infinite canvas (overlay); the host does the moving
    property bool rightDragPans: false

    signal panBy(real dx, real dy)
    signal panDone()
    // Any press: the overlay hands this screen the keys
    signal touched()

    readonly property bool typing: textInput.visible
    // The shape being drawn; changed in place while the mouse moves, painted on `top`
    property var live: null
    // Where the eraser ring is drawn, in item pixels
    property point hover: Qt.point(-1, -1)

    readonly property var view: ({ ox: originX, oy: originY, k: scale })

    function toDoc(x, y) {
        return { x: x / scale + originX, y: y / scale + originY };
    }

    function colorOf(role) {
        return Theme[role] ?? Theme.accent;
    }

    function point(p) {
        return { x: Engine.round1(p.x), y: Engine.round1(p.y) };
    }

    // Pen, highlighter and line follow the ruler's edge when they come near it
    function snapped(d, tool) {
        if (tools.ruler && tools.rulerAt && (Engine.isStroke(tool) || tool === "line"))
            return Engine.snapToRuler(tools.rulerAt, d, 1 / scale);
        return d;
    }

    function placeRuler() {
        if (!tools.ruler || !placesRuler || width <= 0 || height <= 0)
            return;
        const r = tools.rulerAt;
        if (r) {
            const c = { x: (r.x - originX) * scale, y: (r.y - originY) * scale };
            if (c.x > 0 && c.x < width && c.y > 0 && c.y < height)
                return;
        }
        const c = toDoc(width / 2, height * 0.55);
        tools.rulerAt = { x: c.x, y: c.y, a: r?.a ?? -12, len: width * 0.42 / scale, h: 34 / scale };
    }

    function eraseAt(d, first) {
        const hit = Engine.hits(store.shapes, d, 10 / scale);
        if (hit.length === 0)
            return false;
        store.removeShapes(hit, first);
        return true;
    }

    // ── Text ─────────────────────────────────────────────────

    function placeText(x, y) {
        commitText();
        const size = Engine.round1(Engine.textSize(tools.width) / scale);
        const d = toDoc(x, y);
        // The click is about the middle of the line, not its baseline
        textInput.at = point({ x: d.x, y: d.y + size * 0.35 });
        textInput.size = size;
        textInput.role = tools.color;
        textInput.text = "";
        textInput.visible = true;
        textInput.forceActiveFocus();
    }

    function commitText() {
        if (!textInput.visible)
            return;
        if (textInput.text.trim() !== "")
            store.addShape({
                tool: "text", color: textInput.role, width: Engine.round1(tools.width / scale),
                size: textInput.size, text: textInput.text, points: [textInput.at]
            });
        closeText();
    }

    function closeText() {
        textInput.visible = false;
        textInput.text = "";
        if (keyTarget)
            keyTarget.forceActiveFocus();
    }

    onViewChanged: {
        ink.requestPaint();
        top.requestPaint();
    }
    onWidthChanged: {
        placeRuler();
        ink.requestPaint();
        top.requestPaint();
    }
    onHeightChanged: {
        ink.requestPaint();
        top.requestPaint();
    }
    onActiveChanged: {
        if (!active)
            commitText();
    }

    Connections {
        target: root.store

        function onShapesChanged() {
            ink.requestPaint();
        }
    }

    Connections {
        target: root.tools

        function onRulerChanged() {
            root.placeRuler();
            top.requestPaint();
        }
        function onRulerAtChanged() {
            top.requestPaint();
        }
        function onToolChanged() {
            if (root.tools.tool !== "text")
                root.commitText();
            top.requestPaint();
        }
    }

    // The drawing itself; repainted only when the shapes or the view change
    Canvas {
        id: ink

        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.clearRect(0, 0, width, height);
            Engine.paintShapes(ctx, root.store.shapes ?? [], root.view, root.colorOf, Theme.font);
        }
    }

    // What changes with every mouse move: the shape being drawn, the ruler, the eraser ring
    Canvas {
        id: top

        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.clearRect(0, 0, width, height);
            if (root.live)
                Engine.paintShapes(ctx, [root.live], root.view, root.colorOf, Theme.font);
            if (root.tools.ruler && root.tools.rulerAt)
                Engine.paintRuler(ctx, root.tools.rulerAt, root.view, root.colorOf, Theme.font);
            if (root.active && root.tools.tool === "erase" && root.hover.x >= 0) {
                ctx.strokeStyle = Theme.danger;
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.arc(root.hover.x, root.hover.y, 10, 0, Math.PI * 2);
                ctx.stroke();
            }
        }
    }

    MouseArea {
        id: area

        // draw | erase | ruler | turn | pan, for the press in progress
        property string mode: ""
        property var start: null
        property var rulerFrom: null
        // Turning: the ruler's angle minus the grab's direction from its centre
        property real turnOffset: 0
        property real lastX: 0
        property real lastY: 0
        property bool erased: false
        readonly property bool overRuler: root.tools.ruler && root.tools.rulerAt !== null
            && Engine.onRuler(root.tools.rulerAt, root.toDoc(mouseX, mouseY))
        readonly property bool overRulerEnd: overRuler
            && Engine.onRulerEnd(root.tools.rulerAt, root.toDoc(mouseX, mouseY), 1 / root.scale)

        anchors.fill: parent
        enabled: root.active
        hoverEnabled: true
        acceptedButtons: root.rightDragPans ? Qt.LeftButton | Qt.RightButton : Qt.LeftButton
        cursorShape: mode === "pan" || mode === "turn" ? Qt.ClosedHandCursor
            : overRulerEnd ? Qt.OpenHandCursor
            : mode === "ruler" || overRuler ? Qt.SizeAllCursor
            : root.tools.tool === "text" ? Qt.IBeamCursor
            : root.tools.tool === "erase" ? Qt.BlankCursor
            : root.tools.tool === "" ? Qt.ArrowCursor
            : Qt.CrossCursor

        onExited: {
            root.hover = Qt.point(-1, -1);
            top.requestPaint();
        }

        onPressed: mouse => {
            root.touched();
            if (mouse.button === Qt.RightButton) {
                mode = "pan";
                lastX = mouse.x;
                lastY = mouse.y;
                return;
            }
            const d = root.toDoc(mouse.x, mouse.y);
            // Checked at the press itself: mouseX still holds the last hover until the bindings catch up
            const r = root.tools.ruler ? root.tools.rulerAt : null;
            // The grips at its ends turn the ruler around its centre
            if (r && Engine.onRulerEnd(r, d, 1 / root.scale)) {
                mode = "turn";
                turnOffset = root.tools.rulerAt.a - Engine.rulerAngleTo(root.tools.rulerAt, d);
                return;
            }
            if (r && Engine.onRuler(r, d)) {
                mode = "ruler";
                start = d;
                rulerFrom = Object.assign({}, root.tools.rulerAt);
                return;
            }
            const tool = root.tools.tool;
            if (tool === "text") {
                mode = "";
                root.placeText(mouse.x, mouse.y);
                return;
            }
            root.commitText();
            if (tool === "erase") {
                mode = "erase";
                erased = root.eraseAt(d, true);
                return;
            }
            if (tool === "") {
                mode = "";
                return;
            }
            mode = "draw";
            root.live = {
                tool, color: root.tools.color, width: Engine.round1(root.tools.width / root.scale),
                points: [root.point(root.snapped(d, tool))]
            };
            top.requestPaint();
        }

        onPositionChanged: mouse => {
            if (root.tools.tool === "erase") {
                root.hover = Qt.point(mouse.x, mouse.y);
                top.requestPaint();
            }
            if (!pressed)
                return;
            if (mode === "pan") {
                root.panBy(mouse.x - lastX, mouse.y - lastY);
                lastX = mouse.x;
                lastY = mouse.y;
                return;
            }
            const d = root.toDoc(mouse.x, mouse.y);
            if (mode === "ruler") {
                root.tools.rulerAt = Object.assign({}, rulerFrom, { x: rulerFrom.x + d.x - start.x, y: rulerFrom.y + d.y - start.y });
                return;
            }
            if (mode === "turn") {
                let a = Engine.rulerAngleTo(root.tools.rulerAt, d) + turnOffset;
                // Shift holds it to 15° steps
                if (mouse.modifiers & Qt.ShiftModifier)
                    a = Math.round(a / 15) * 15;
                root.tools.rulerAt = Object.assign({}, root.tools.rulerAt, { a });
                return;
            }
            if (mode === "erase") {
                // One undo brings back everything one drag took
                if (root.eraseAt(d, !erased))
                    erased = true;
                return;
            }
            const s = root.live;
            if (mode !== "draw" || !s)
                return;
            let p = root.snapped(d, s.tool);
            if (Engine.isStroke(s.tool)) {
                const last = s.points[s.points.length - 1];
                if (Math.hypot(p.x - last.x, p.y - last.y) < 0.75 / root.scale)
                    return;
                s.points.push(root.point(p));
            } else {
                const a = s.points[0];
                if (mouse.modifiers & Qt.ShiftModifier)
                    p = s.tool === "line" || s.tool === "arrow" ? Engine.snapAngle(a, p) : Engine.snapSquare(a, p);
                s.points = [a, root.point(p)];
            }
            top.requestPaint();
        }

        onReleased: {
            if (mode === "pan")
                root.panDone();
            const s = root.live;
            root.live = null;
            if (mode === "draw" && s) {
                const a = s.points[0], b = s.points[s.points.length - 1];
                // A click with a line or box tool is not a shape
                if (Engine.isStroke(s.tool) || Math.hypot(b.x - a.x, b.y - a.y) * root.scale >= 3)
                    root.store.addShape(s);
            }
            mode = "";
            top.requestPaint();
        }

        onCanceled: {
            if (mode === "pan")
                root.panDone();
            root.live = null;
            mode = "";
            top.requestPaint();
        }

        // The wheel turns the ruler under the mouse, 3° a notch
        onWheel: wheel => {
            if (!overRuler) {
                wheel.accepted = false;
                return;
            }
            root.tools.rulerAt = Object.assign({}, root.tools.rulerAt, { a: root.tools.rulerAt.a + (wheel.angleDelta.y > 0 ? -3 : 3) });
        }
    }

    TextInput {
        id: textInput

        // Start of the baseline in document units, size in document units, color role
        property var at: ({ x: 0, y: 0 })
        property real size: 20
        property string role: "accent"

        visible: false
        x: (at.x - root.originX) * root.scale
        y: (at.y - root.originY) * root.scale - baselineOffset
        width: Math.max(contentWidth + 8, 80)
        color: root.colorOf(role)
        selectionColor: Theme.surface2
        font.family: Theme.font
        font.pixelSize: Math.max(4, Math.round(size * root.scale))
        selectByMouse: true

        Keys.onReturnPressed: root.commitText()
        Keys.onEnterPressed: root.commitText()
        Keys.onEscapePressed: root.closeText()

        Rectangle {
            anchors.fill: parent
            anchors.margins: -4
            z: -1
            color: "transparent"
            border.width: 1
            border.color: Theme.accent
        }
    }
}
