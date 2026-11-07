pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// CanvasLayout (not "Canvas": that name is QtQuick.Canvas). The infinite-canvas layout
// (hypr/facet/canvas.lua) as the bar and the overview see it.
// enabled: ~/.local/state/facet/layout says "canvas" (`facet layout canvas`).
// The rest comes from $XDG_RUNTIME_DIR/facet-canvas.json, which canvas.lua rewrites on
// every change: { monitors: [{ name, focused, workspace, x, y, w, h, camera: { x, y } }],
//   windows: [{ address, monitor, x, y, w, h, active, class, title }] }
// in global canvas coordinates: a monitor's view starts at its position plus its camera,
// so every monitor's canvas lies where the monitor is.
Singleton {
    id: root

    property bool enabled: false
    property var monitors: []
    property var windows: []
    // Drag steps sent since canvas.lua last wrote the map (it writes once a drag ends), per
    // monitor name: { x, y } to add to that monitor's view, so the screen drawing (draw/)
    // moves with the windows while the canvas is dragged
    property var pending: ({})

    readonly property var focused: monitors.find(m => m.focused) ?? monitors[0] ?? null

    // The monitor with that name, or the focused one
    function monitor(name) {
        return monitors.find(m => m.name === name) ?? focused;
    }

    // The monitor whose screen (layout rectangle) holds point x, y, else the nearest one
    function monitorAt(x, y) {
        let best = null, bestD = Infinity;
        for (const m of monitors) {
            const dx = Math.max(m.x - x, 0, x - (m.x + m.w));
            const dy = Math.max(m.y - y, 0, y - (m.y + m.h));
            const d = dx * dx + dy * dy;
            if (d < bestD) {
                best = m;
                bestD = d;
            }
        }
        return best;
    }

    // Layout point (where things are on the screens right now) → canvas point
    function toCanvas(x, y) {
        const m = monitorAt(x, y);
        return m ? { x: x + m.camera.x, y: y + m.camera.y, monitor: m.name } : { x, y, monitor: "" };
    }

    // Where a monitor's view is on the canvas
    function viewOf(m) {
        return m ? { x: m.x + m.camera.x, y: m.y + m.camera.y, w: m.w, h: m.h } : { x: 0, y: 0, w: 1920, h: 1080 };
    }

    // Everything worth showing: every screen and every window
    readonly property var bounds: {
        let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
        for (const m of monitors) {
            const v = viewOf(m);
            x1 = Math.min(x1, v.x);
            y1 = Math.min(y1, v.y);
            x2 = Math.max(x2, v.x + v.w);
            y2 = Math.max(y2, v.y + v.h);
        }
        for (const w of windows) {
            x1 = Math.min(x1, w.x);
            y1 = Math.min(y1, w.y);
            x2 = Math.max(x2, w.x + w.w);
            y2 = Math.max(y2, w.y + w.h);
        }
        if (x1 === Infinity)
            return { x: 0, y: 0, w: 1920, h: 1080 };
        return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
    }

    function run(code) {
        Quickshell.execDetached(["hyprctl", "eval", code]);
    }

    function addr(address) {
        return String(address).replace(/[^0-9a-fx]/gi, "");
    }

    // Monitor names go into Lua code, so only what a name can contain
    function monitorArg(monitor) {
        return `"${String(monitor ?? "").replace(/[^\w-]/g, "")}"`;
    }

    // Puts canvas point x, y in the middle of a screen: the named monitor's, or (no name)
    // the one whose canvas holds the point. Canvases overlap once cameras differ, so
    // callers that know the monitor pass it.
    function lookAt(x, y, monitor) {
        run(`frame_canvas.look_at(${Math.round(x)}, ${Math.round(y)}, ${monitorArg(monitor)})`);
    }

    // Focuses the window and brings it to the middle of its screen (overview)
    function select(address) {
        run(`frame_canvas.select("${addr(address)}")`);
    }

    // Puts the window's top left corner at canvas point x, y (overview drag); dropped
    // (final) with its middle on another screen, it moves to that monitor
    function moveTo(address, x, y, monitor, final) {
        run(`frame_canvas.move_to("${addr(address)}", ${Math.round(x)}, ${Math.round(y)}, ${monitorArg(monitor)}, ${final ? "true" : "false"})`);
    }

    // Enter in the launcher on an app that already runs: its window comes into the middle
    // of the focused screen's view and takes focus (Apps.qml)
    function summon(address) {
        run(`frame_canvas.summon("${addr(address)}")`);
    }

    // Fullscreen on the screen the window is on (overview, F)
    function fullscreen(address) {
        run(`frame_canvas.fullscreen("${addr(address)}")`);
    }

    // The window's new size in pixels (overview, dragging a corner)
    function resizeTo(address, w, h) {
        run(`frame_canvas.resize_to("${addr(address)}", ${Math.round(w)}, ${Math.round(h)})`);
    }

    // Asks the window to close (overview, Q)
    function closeWindow(address) {
        run(`frame_canvas.close_window("${addr(address)}")`);
    }

    // Dragging empty canvas: small steps while the mouse moves, one write-out at the end
    function dragBy(dx, dy, monitor) {
        run(`frame_canvas.drag_by("${String(monitor).replace(/[^\w-]/g, "")}", ${Math.round(dx)}, ${Math.round(dy)})`);
        const name = String(monitor);
        const p = pending[name] ?? { x: 0, y: 0 };
        pending = Object.assign({}, pending, { [name]: { x: p.x + Math.round(dx), y: p.y + Math.round(dy) } });
    }

    function dragDone() {
        run("frame_canvas.drag_done()");
    }

    // Overview open or closed: Hyprland drops its Super + mouse drag binds meanwhile
    function overview(open) {
        run(`frame_canvas.overview(${open ? "true" : "false"})`);
    }

    // Moves the view of that monitor (default: the focused one)
    function pan(dx, dy, monitor) {
        if (monitor)
            run(`frame_canvas.pan_on("${String(monitor).replace(/[^\w-]/g, "")}", ${Math.round(dx)}, ${Math.round(dy)})`);
        else
            run(`frame_canvas.pan(${Math.round(dx)}, ${Math.round(dy)})`);
    }

    // "1.2k" for the position next to the minimap
    function short(n) {
        const a = Math.abs(n);
        return a >= 10000 ? `${Math.round(n / 1000)}k` : a >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${Math.round(n)}`;
    }

    FileView {
        path: `${Quickshell.env("HOME")}/.local/state/facet/layout`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.enabled = text().trim() === "canvas"
        onLoadFailed: root.enabled = false
    }

    FileView {
        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/facet-canvas.json`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const data = JSON.parse(text());
                root.monitors = data.monitors ?? [];
                root.windows = data.windows ?? [];
                // The cameras in the map include the steps sent so far
                root.pending = {};
            } catch (e) {
                // Half written; the next change brings a whole one
            }
        }
    }
}
