pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "WallpaperState.js" as State

Singleton {
    id: root

    readonly property string tool: `${Quickshell.env("HOME")}/.local/bin/facet-wallpaper`
    property bool legacyAvailable: true
    property bool glintConfigured: false
    readonly property bool useGlint: glintConfigured || Quickshell.env("FACET_GLINT") === "1"
    readonly property bool glintActive: glintReady && glint.connected
    readonly property bool available: useGlint ? glintActive : legacyAvailable
    property bool glintReady: false
    property bool loading: false
    property string glintError: ""
    property var items: []
    property var localItems: []
    property var glintItems: []
    property var glintOutputs: []
    property var glintStatus: ({})
    property var sceneSettings: ({})
    property var propertyRequests: ({})
    property var optionRequests: ({})
    property var pendingPauses: ({})
    property var settings: ({ backend: "both", fps: 60, volume: 0, scaling: "fill", pause: true, mature: true, screens: {} })
    property var queue: []

    function refresh() {
        loading = true;
        if (useGlint) {
            run(["list-local"]);
            if (glintActive) {
                glint.outputs();
                glint.list("");
                glint.send("status");
            } else {
                glintError = "Connecting to glint…";
            }
        } else {
            run(["state"]);
            run(["list"]);
        }
    }

    function updateItems() {
        const source = useGlint ? localItems.filter(item => item.source === "file").concat(glintItems) : localItems;
        items = source.filter(item => settings.mature !== false || String(item.rating || "").toLowerCase() !== "mature");
    }

    function current(output) {
        if (useGlint) {
            if (output && output !== "*") return glintOutputs.find(o => o.name === output)?.wallpaper?.path ?? "";
            const paths = glintOutputs.map(o => o.wallpaper?.path ?? "");
            return paths.length && paths.every(path => path === paths[0]) ? paths[0] : "";
        }
        const screens = settings.screens ?? {};
        return (screens[output] ?? screens["*"])?.path ?? "";
    }

    function optionsFor(output) { return State.optionsFor(glintStatus, output || "*"); }
    function propertiesFor(output, project) { return State.propertiesFor(sceneSettings, glintStatus, output, project); }
    function propertyLabel(property) { return State.propertyLabel(property); }

    function apply(path, output) {
        const target = output || "*";
        if (useGlint) {
            if (!glintActive) { glintError = "Glint is not connected. Start the engine first."; return; }
            glintError = "";
            const options = optionsFor(target);
            glint.setWallpaper(target, path, { fps: options.fps, scaling: options.scaling,
                volume: options.volume, mute: options.mute, transition: options.transition, duration: options.duration });
            return;
        }
        queue = queue.filter(args => !(args[0] === "set" && (target === "*" || args[2] === target)));
        run(["set", path, target]);
        run(["state"]);
    }

    function setDisplaySetting(output, name, value) {
        setDisplaySettings(output, { [name]: value });
    }

    function setDisplaySettings(output, changes) {
        if (!glintActive) { glintError = "Glint is not connected"; return; }
        const allowed = ["fps", "scaling", "volume", "mute", "transition", "duration", "color"];
        if (!Object.keys(changes).length || Object.keys(changes).some(key => !allowed.includes(key))) return;
        glintError = "";
        const id = glint.send("status");
        if (id >= 0) optionRequests[id] = { output: output || "*", changes: changes };
    }

    function option(key, value) {
        if (useGlint) {
            if (key === "volume") setDisplaySetting("*", key, value / 100);
            else if (["fps", "scaling"].includes(key)) setDisplaySetting("*", key, value);
            return;
        }
        settings = Object.assign({}, settings, { [key]: value });
        run(["option", key, String(value)]);
        run(["state"]);
    }

    function setBackend(name) {
        if (useGlint) return;
        settings = Object.assign({}, settings, { backend: name });
        run(["backend", name]);
        run(["state"]);
        run(["list"]);
    }

    function refreshSceneSettings(output, project) {
        if (!glintActive) return;
        const names = project ? State.propertyTargets(glintStatus, output || "*", project)
                              : State.targets(glintStatus, output || "*", "").filter(name =>
                                  !["loading", "error", "none"].includes(glintStatus[name].state));
        for (const name of names) {
            const id = glint.settings(name);
            if (id >= 0) propertyRequests[id] = { output: name, path: glintStatus[name]?.path };
        }
    }

    function setSceneSetting(output, name, value, project) {
        if (!glintActive) { glintError = "Glint is not connected"; return; }
        glintError = "";
        for (const display of State.propertyTargets(glintStatus, output || "*", project)) {
            const id = glint.setSettings(display, { [name]: value });
            if (id >= 0) propertyRequests[id] = { output: display, path: project };
        }
    }

    function pauseGlint(reason) {
        const key = reason || "request";
        pendingPauses[key] = true;
        if (glintActive) glint.pause("*", key);
    }
    function resumeGlint(reason) {
        const key = reason || "request";
        delete pendingPauses[key];
        if (glintActive) glint.resume("*", key);
    }
    function startGlint() {
        glintError = "Starting glint…";
        Quickshell.execDetached([`${Quickshell.env("HOME")}/.local/bin/facet-glint-start`]);
    }

    GlintClient {
        id: glint
        enabled: root.useGlint
        onConnectedChanged: {
            if (connected) send("version");
            else {
                root.glintReady = false;
                root.glintOutputs = [];
                root.glintStatus = {};
                root.sceneSettings = {};
                root.propertyRequests = {};
                root.optionRequests = {};
                if (root.useGlint) root.glintError = "Glint is not connected";
                root.updateItems();
            }
        }
        onResponse: (id, operation, result) => {
            result = JSON.parse(JSON.stringify(result));
            if (operation === "version") {
                root.glintReady = Array.isArray(result.operations) && result.operations.includes("list");
                if (root.glintReady) {
                    root.glintError = "";
                    outputs(); list(""); send("status");
                    for (const reason of Object.keys(root.pendingPauses)) pause("*", reason);
                } else root.glintError = "Update glint to use its library API";
            } else if (operation === "outputs") {
                root.glintOutputs = Array.isArray(result) ? result : [];
            } else if (operation === "status") {
                root.glintStatus = result || {};
                const common = root.optionsFor("*");
                root.settings = Object.assign({}, root.settings, { backend: "both", fps: common.fps,
                    scaling: common.scaling, volume: Math.round(common.volume * 100) });
                const change = root.optionRequests[id];
                if (change) {
                    delete root.optionRequests[id];
                    const requests = State.optionRequests(result, change.output, change.changes);
                    if (!requests.length) root.glintError = "No running wallpaper on the selected display";
                    for (const request of requests) send(request.op, request);
                }
            } else if (operation === "list") {
                root.glintItems = State.libraryItems(result);
                root.updateItems(); root.loading = false;
            } else if (operation === "props" && root.propertyRequests[id]) {
                const request = root.propertyRequests[id];
                const output = request.output;
                delete root.propertyRequests[id];
                if (root.glintStatus[output]?.path !== request.path) return;
                if (Array.isArray(result)) root.sceneSettings = Object.assign({}, root.sceneSettings, { [output]: result });
                else root.refreshSceneSettings(output);
            } else if (operation === "set") {
                outputs(); send("status");
            }
        }
        onRequestFailed: (id, operation, message) => {
            delete root.propertyRequests[id]; delete root.optionRequests[id];
            if (operation !== "subscribe") root.glintError = message;
            if (operation === "list") root.loading = false;
        }
        onEventReceived: (event, data) => {
            if (event === "outputs" || event === "state") { outputs(); send("status"); }
            if (event === "props" && data.output) root.refreshSceneSettings(data.output);
            if (event === "error") root.glintError = data.message || "Wallpaper failed";
        }
    }

    FileView {
        path: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/facet/wallpaper-backend`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.glintConfigured = text().trim() === "glint"
        onLoadFailed: root.glintConfigured = false
    }
    function run(args) { queue = queue.concat([args]); next(); }
    function next() {
        if (proc.running || proc.busy || !queue.length) return;
        proc.args = queue[0]; queue = queue.slice(1);
        proc.busy = true; proc.command = [tool].concat(proc.args); proc.running = true;
    }
    Process {
        id: proc
        property var args: []
        property bool busy: false
        stdout: StdioCollector {
            onStreamFinished: {
                const kind = proc.args[0];
                if (["list", "list-local", "state"].includes(kind)) {
                    try {
                        const data = JSON.parse(text);
                        if (kind === "state" && !root.useGlint) root.settings = data;
                        else if (kind !== "state") { root.localItems = Array.isArray(data) ? data : []; root.updateItems(); }
                        root.legacyAvailable = true;
                    } catch (e) { console.warn(`wallpapers: ${kind}: ${e}`); }
                }
                root.loading = false; proc.busy = false; Qt.callLater(root.next);
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim()) console.warn(`wallpapers: ${text.trim()}`); }
        }
    }
    FileView {
        path: root.tool
        printErrors: false
        onLoadFailed: root.legacyAvailable = false
        onLoaded: root.legacyAvailable = true
    }
    FileView {
        path: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/facet/wallpaper.json`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.settings = Object.assign({}, root.settings, { mature: JSON.parse(text()).mature !== false }); }
            catch (e) { console.warn(`wallpapers: preferences: ${e}`); }
        }
    }
}
