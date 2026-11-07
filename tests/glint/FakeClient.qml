import QtQuick
import Quickshell

Scope {
    id: root
    property bool enabled: false
    property bool connected: false
    property int nextId: 1
    property var states: ({
        "DP-2": { path: "/test/42", kind: "scene", state: "running", options: { fps: 60, volume: 0.5, scaling: "fit" } },
        "HDMI-A-1": { path: "/other/video", kind: "video", state: "running", options: { fps: 30, volume: 0.2, scaling: "fill" } }
    })
    property bool clock: true
    signal response(int id, string operation, var result)
    signal requestFailed(int id, string operation, string message)
    signal eventReceived(string event, var data)
    Component.onCompleted: Qt.callLater(() => connected = enabled)
    onEnabledChanged: Qt.callLater(() => connected = enabled)

    function send(operation, fields) {
        const id = nextId++;
        const request = Object.assign({}, fields || {}, { op: operation });
        console.log("FAKE_REQUEST", JSON.stringify(request));
        let result = {};
        if (operation === "version") result = { operations: ["list", "set", "status", "props", "outputs"] };
        else if (operation === "list") result = [{ id: "42", title: "Scene", type: "scene", path: "/test/42", preview: "/tmp/absolute-preview.png", tags: [] }];
        else if (operation === "outputs") result = Object.keys(states).map(name => ({ name: name, wallpaper: { path: states[name].path, kind: states[name].kind, state: states[name].state } }));
        else if (operation === "status") result = JSON.parse(JSON.stringify(states));
        else if (operation === "set") {
            const names = request.output === "*" ? Object.keys(states) : [request.output];
            for (const name of names) {
                states[name].options = request.options;
                states[name].path = request.path;
            }
        } else if (operation === "props") {
            if (request.set) {
                if (states[request.output].path !== "/test/42") { console.error("Property leaked to another project"); Qt.exit(1); }
                clock = request.set.clock;
            } else result = [
                { name: "clock", text: "Clock", type: "bool", value: clock },
                { name: "strength", text: "Strength", type: "slider", value: 0.5, min: 0, max: 1, step: 0.1 },
                { name: "scheme", text: "Scheme", type: "combo", value: "a", options: [{ label: "A", value: "a" }, { label: "B", value: "b" }] },
                { name: "color", text: "Color", type: "color", value: "#aabbcc" },
                { name: "message", text: "Message", type: "textinput", value: "Hello" }
            ];
        } else if (operation === "pause" || operation === "resume") {
            for (const name of Object.keys(states)) states[name].state = operation === "pause" ? "paused" : "running";
            Qt.callLater(() => root.eventReceived("state", {}));
        }
        Qt.callLater(() => root.response(id, operation, result));
        return id;
    }
    function outputs() { return send("outputs"); }
    function list(search) { return send("list", { search: search }); }
    function settings(output) { return send("props", { output: output }); }
    function setSettings(output, values) { return send("props", { output: output, set: values }); }
    function setWallpaper(output, path, options) { return send("set", { output: output, path: path, options: options }); }
    function pause(output, reason) { return send("pause", { output: output, reason: reason }); }
    function resume(output, reason) { return send("resume", { output: output, reason: reason }); }
}
