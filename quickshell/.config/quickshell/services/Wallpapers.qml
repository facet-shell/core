pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Front end for ~/.local/bin/frame-wallpaper (wallpaper package), which owns the state
// and starts linux-wallpaperengine or mpvpaper; still pictures are drawn by wallpapers/Backdrop.qml.
//
// items:    [{ id, title, kind ("scene" | "video" | "web" | "image"), source ("workshop" | "file"),
//              tags, path, preview }] – only what the current backend can show
// settings: { backend ("both" | "mpv" | "image"), fps, volume, scaling ("fill" | "fit"), pause,
//              screens: { "<monitor>" | "*": { path, kind } } }
Singleton {
    id: root

    // Hyprland's environment usually has no ~/.local/bin in PATH
    readonly property string tool: `${Quickshell.env("HOME")}/.local/bin/frame-wallpaper`
    property bool available: true
    property bool loading: false
    property var items: []
    property var settings: ({ backend: "both", fps: 30, volume: 0, scaling: "fill", pause: true, screens: {} })

    // Commands wait here so two of them never run at the same time
    property var queue: []

    function refresh() {
        loading = true;
        run(["state"]);
        run(["list"]);
    }

    // Path shown on a screen ("*" = the one for all screens)
    function current(screen) {
        const screens = settings.screens ?? {};
        return (screens[screen] ?? screens["*"])?.path ?? "";
    }

    function apply(path, screen) {
        const target = screen || "*";
        // A pick that has not run yet is overridden by this one, so it is dropped instead of
        // starting an engine that would be replaced right away
        queue = queue.filter(args => !(args[0] === "set" && (target === "*" || args[2] === target)));
        run(["set", path, target]);
        run(["state"]);
    }

    function option(key, value) {
        // Show it right away; the state read afterwards confirms it
        settings = Object.assign({}, settings, { [key]: value });
        run(["option", key, String(value)]);
        run(["state"]);
    }

    function setBackend(name) {
        settings = Object.assign({}, settings, { backend: name });
        run(["backend", name]);
        run(["state"]);
        run(["list"]);
    }

    function run(args) {
        queue = queue.concat([args]);
        next();
    }

    function next() {
        if (proc.running || proc.busy || queue.length === 0)
            return;
        proc.args = queue[0];
        queue = queue.slice(1);
        proc.busy = true;
        proc.command = [tool].concat(proc.args);
        proc.running = true;
    }

    // The output arrives after the exit signal, so the next command only starts once the
    // output of this one is read; otherwise a "list" answer would be taken for "state"
    Process {
        id: proc

        property var args: []
        property bool busy: false

        stdout: StdioCollector {
            onStreamFinished: {
                const kind = proc.args[0];
                if (kind === "list" || kind === "state") {
                    try {
                        const data = JSON.parse(this.text);
                        if (kind === "list") {
                            root.items = Array.isArray(data) ? data : [];
                            root.loading = false;
                        } else {
                            root.settings = data;
                        }
                        root.available = true;
                    } catch (e) {
                        console.warn(`wallpapers: ${kind}: ${e}`);
                    }
                }
                proc.busy = false;
                Qt.callLater(root.next);
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim() !== "")
                    console.warn(`wallpapers: ${this.text.trim()}`);
            }
        }

        onExited: code => {
            if (proc.args[0] === "list")
                root.loading = false;
        }
    }

    // The wallpaper package is not installed (or not stowed yet)
    FileView {
        path: root.tool
        printErrors: false
        onLoadFailed: root.available = false
        onLoaded: root.available = true
    }
}
