pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Front end for ~/.local/bin/facet-keyboard (keyboard package): lighting, Fn keys and
// per-key colors of the board picked with `facet keyboard set` (or the one plugged in).
// Key ids are physical keys named like a US board ("y" is the key labelled Z on QWERTZ);
// actions typed by hand are read as QWERTZ.
//
// Nothing reaches the keyboard while `live` is false: facet-keyboard then only prints the
// packets it would send (shown in `log`) and answers reads with placeholder data.
Singleton {
    id: root

    // Hyprland's environment usually has no ~/.local/bin in PATH
    readonly property string tool: `${Quickshell.env("HOME")}/.local/bin/facet-keyboard`
    property bool available: true
    // Starts from Config.keyboardLive; the switch in the app changes it until the next restart
    property bool live: Config.keyboardLive
    readonly property bool busy: queue.length > 0 || proc.job !== null

    // facet-keyboard board --json --layout de: { id, name, vendor, family, tested, can: {
    //   effects, brightness, speed, perkey, live, fn, layers }, rows: [[{ id, label, w }]], keys }
    property var board: null
    readonly property string boardName: board?.name ?? "keyboard"
    readonly property var can: board?.can ?? ({ effects: true, brightness: 9, speed: 4, perkey: true, live: true, fn: true, layers: ["base", "fn1", "fn2", "tap"] })
    // The map in the app: [label, key id, width in keys] per key, an empty id is a gap
    readonly property var keyRows: (board?.rows ?? []).map(row => row.map(k => [k.label, k.id, k.w]))
    property string tablesFor: ""

    property var devices: []
    property var effects: []
    property var actions: ({ media: [], lighting: [], mods: [], keys: [], defaults: {} })
    // facet-keyboard info --json: { dry, model, id, node, effect, effects: { name: { brightness,
    //   speed, slot } }, layer, keys: { id: { bytes, text } }, colors: { id: "#rrggbb" } }
    property var info: null
    property string layer: "fn1"
    // Output of the last write: in a dry run the packets that would have been sent
    property string log: ""
    property string error: ""

    // The picked board's configuration interface is there (facet-keyboard list --json)
    readonly property bool connected: devices.some(d => d.config && (!board || (d.boards ?? []).includes(board.id)))
    readonly property bool dongleOnly: !connected && devices.some(d => d.kind === "dongle")

    property var queue: []

    // ── Hotkey hints on the keys ─────────────────────────────
    // What is held right now, from Hyprland (hypr/facet/hotkeys.lua): "super", "super+shift",
    // "ctrl+alt", … and "" on release. While the hotkey overlay is open by hand, Super counts.
    property string heldMods: ""
    property bool overlayOpen: false
    readonly property string hintMods: !Config.keyboardHotkeyHints ? "" : heldMods !== "" ? heldMods : (overlayOpen ? "super" : "")

    function setHeldMods(text) {
        const next = String(text ?? "").trim().toLowerCase();
        // Binds change with the mode (the canvas swaps them while the overview is open)
        if (next !== "" && heldMods === "")
            Binds.refresh();
        heldMods = next;
    }

    // One word per key for `facet-keyboard highlight`: keys bound with exactly what is held
    // in the text color, keys that need one modifier more dimmed, the held modifiers in primary
    readonly property var hintKeys: {
        if (hintMods === "")
            return [];
        const held = hintMods.split("+");
        const same = {}, more = {};
        for (const r of Binds.rows) {
            const keys = r.key === "1…0" ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] : [r.key];
            const exact = r.mods.length === held.length && held.every(m => r.mods.includes(m));
            const superset = !exact && held.every(m => r.mods.includes(m));
            for (const k of keys) {
                if (exact)
                    same[k] = true;
                else if (superset)
                    more[k] = true;
            }
        }
        const out = [];
        for (const k in same)
            out.push(`${k}=text`);
        for (const k in more)
            if (!same[k])
                out.push(`${k}=muted`);
        const modKeys = { super: ["super_l"], shift: ["shift_l", "shift_r"], ctrl: ["control_l", "control_r"], alt: ["alt_l"] };
        for (const m of held)
            for (const k of (modKeys[m] ?? []))
                out.push(`${k}=primary`);
        return out;
    }

    readonly property bool hintWanted: live && available && can.live && hintKeys.length > 0
    onHintWantedChanged: hint.running = hintWanted
    onHintKeysChanged: pushHint()

    function pushHint() {
        if (hint.running && hintKeys.length > 0)
            hint.write(hintKeys.join(" ") + "\n");
    }

    // One facet-keyboard for the whole time something is held: new key lists go in over
    // stdin, so the frame changes without the board falling back to its effect in between.
    // Nothing is saved on the board; ending the process sends the stop packet.
    Process {
        id: hint
        stdinEnabled: true
        command: [root.tool, "highlight", "--live", "--stdin", "--layout", "de", "--skip-unknown", "--base", "bg"]
        onStarted: root.pushHint()
    }

    function refresh() {
        // The board first: the effects and Fn actions are its own (loadTables)
        run(["board", "--json", "--layout", "de"], "board");
        run(["list", "--json"], "devices");
        readInfo();
    }

    // Effects and Fn actions of the board, once per board
    function loadTables() {
        // An older facet-keyboard knows no boards: one set of tables, as before
        const id = board?.id ?? "-";
        if (tablesFor === id)
            return;
        tablesFor = id;
        effects = [];
        actions = { media: [], lighting: [], mods: [], keys: [], defaults: {} };
        if (can.effects)
            run(["effects", "--json"], "effects");
        if (can.fn)
            run(["actions", "--json"], "actions");
    }

    function readInfo() {
        run(device(["info", "--json", "--layout", "de", "--layer", layer]), "info");
    }

    function setLive(on) {
        live = on;
        readInfo();
    }

    function setLayer(name) {
        layer = name;
        readInfo();
    }

    // speed < 0 and color "" leave those as they are
    function effect(name, brightness, speed, color) {
        const args = ["effect", name, "-b", String(brightness)];
        if (speed >= 0)
            args.push("-s", String(speed));
        if (color !== "")
            args.push("-c", color);
        write(args);
    }

    // items: ["f1=play", "q=ctrl+z", …] with physical key ids on the current layer
    function assign(items) {
        write(["fn", "--layer", layer, "--layout", "us", "--action-layout", "de", "--allow-knob"].concat(items));
    }

    // Back to the factory Fn action (fn1 only)
    function resetKeys(ids) {
        write(["fn", "--reset", "--layer", "fn1", "--layout", "us", "--allow-knob"].concat(ids));
    }

    // colors: { id: "#rrggbb" } for every key that should change
    function paint(colors, brightness) {
        const items = Object.keys(colors).map(id => `${id}=${colors[id]}`);
        if (items.length > 0)
            write(["colors", "--layout", "us", "-b", String(brightness)].concat(items));
    }

    function style(name, brightness) {
        write(["style", name, "-b", String(brightness)]);
    }

    function write(args) {
        run(device(args), "write");
        readInfo();
    }

    function device(args) {
        return live ? args.concat(["--live"]) : args;
    }

    function run(args, kind) {
        queue = queue.concat([{ args: args, kind: kind }]);
        next();
    }

    function next() {
        if (proc.running || proc.job !== null || queue.length === 0)
            return;
        proc.job = queue[0];
        queue = queue.slice(1);
        proc.command = [tool].concat(proc.job.args);
        proc.running = true;
    }

    // The output arrives after the exit signal, so the next command only starts once the
    // output of this one is read (as in Wallpapers)
    Process {
        id: proc

        property var job: null

        onStarted: root.error = ""

        stdout: StdioCollector {
            onStreamFinished: {
                const job = proc.job;
                const text = this.text;
                if (job.kind === "write") {
                    root.log = `$ facet-keyboard ${job.args.join(" ")}\n${text}`;
                } else if (job.kind === "board" && text.trim() === "") {
                    root.loadTables();
                } else if (text.trim() !== "") {
                    try {
                        const data = JSON.parse(text);
                        if (job.kind === "board") {
                            root.board = data;
                            root.loadTables();
                        } else if (job.kind === "devices")
                            root.devices = data;
                        else if (job.kind === "effects")
                            root.effects = data;
                        else if (job.kind === "actions")
                            root.actions = data;
                        else if (job.kind === "info")
                            root.info = data;
                    } catch (e) {
                        console.warn(`keyboard: ${job.kind}: ${e}`);
                    }
                }
                proc.job = null;
                Qt.callLater(root.next);
            }
        }

        // facet-keyboard ends a failed command with "facet-keyboard: <reason>"
        stderr: StdioCollector {
            onStreamFinished: {
                const failure = this.text.trim().split("\n").filter(l => l.startsWith("facet-keyboard: ")).pop() ?? "";
                if (failure !== "")
                    root.error = failure.slice("facet-keyboard: ".length);
            }
        }
    }

    // The keyboard package is not linked into ~/.local/bin (yet)
    FileView {
        path: root.tool
        printErrors: false
        onLoadFailed: root.available = false
        onLoaded: root.available = true
    }
}
