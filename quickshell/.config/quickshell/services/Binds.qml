pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Keybinds as Hyprland reports them (`hyprctl binds -j`), turned into rows for the hotkey overlay.
//
// rows: [{ mods: ["super", "shift"], key: "space", label, group, source ("frame" | "hyprland") }]
// Descriptions like "facet shell · launcher" (see hypr/facet/*.lua) give group and label;
// your own binds can use "group · text". Without a description the row is built from
// dispatcher and argument. Expected JSON per bind: modmask (Super 64, Shift 1, Ctrl 4,
// Alt 8), key, mouse, description, dispatcher, arg, submap. Not checked against the Lua
// config yet; if Hyprland names things differently, adjust parse().
Singleton {
    id: root

    property var rows: []
    property bool loaded: false

    readonly property var groupOrder: ["shell", "apps", "canvas", "windows", "workspaces", "media", "other"]

    function refresh() {
        proc.running = true;
    }

    function modsOf(mask) {
        const out = [];
        if (mask & 64) out.push("super");
        if (mask & 4) out.push("ctrl");
        if (mask & 8) out.push("alt");
        if (mask & 1) out.push("shift");
        return out;
    }

    // Key names as the keyboard map uses them: lower case, mouse buttons spelled out
    function keyName(key) {
        const k = String(key ?? "").toLowerCase();
        const named = {
            "mouse:272": "left drag", "mouse:273": "right drag",
            "mouse_down": "scroll down", "mouse_up": "scroll up"
        };
        return named[k] ?? k;
    }

    // Readable names for common dispatchers, old names and Lua ones (hl.dsp.window.close …)
    function pretty(dispatcher, arg) {
        const d = dispatcher.toLowerCase();
        const names = [
            [/killactive|window\.close/, "close window"], [/window\.kill/, "kill window"],
            [/togglefloating|window\.float/, "float"], [/fullscreen/, "fullscreen"],
            [/pseudo/, "pseudo-tile"], [/togglesplit/, "toggle split"],
            [/movewindow|window\.drag/, "move window"], [/resizewindow|window\.resize/, "resize window"],
            [/movetoworkspace|window\.move/, "move window to workspace"], [/^workspace$/, "go to workspace"],
            [/movefocus|^focus$|dsp\.focus/, arg !== "" ? `focus ${arg}` : "focus"],
            [/togglespecialworkspace|toggle_special/, "scratchpad"], [/^exit$|dsp\.exit/, "quit Hyprland"]
        ];
        for (const [re, text] of names)
            if (re.test(d))
                return text;
        return "";
    }

    // A Lua bind without a description only reports "__lua <id>": its key is all there is
    // to go by, enough for the media and brightness keys
    function fromKey(key) {
        const names = [
            [/audioraisevolume/, "volume up"], [/audiolowervolume/, "volume down"], [/audiomicmute/, "mute the microphone"],
            [/audiomute/, "mute"], [/audioplay|audiopause/, "play / pause"], [/audionext/, "next track"],
            [/audioprev/, "previous track"], [/monbrightnessup/, "brightness up"], [/monbrightnessdown/, "brightness down"],
            [/calculator/, "calculator"]
        ];
        for (const [re, text] of names)
            if (re.test(key))
                return text;
        return "";
    }

    function guessGroup(key, text) {
        const t = text.toLowerCase();
        if (key.startsWith("xf86") || key === "print") return "media";
        if (t.includes("workspace") || t.includes("special")) return "workspaces";
        if (/window|focus|move|close|kill|float|fullscreen|drag|resize|pseudo|split/.test(t)) return "windows";
        if (t.startsWith("exec")) return "apps";
        return "other";
    }

    function parse(list) {
        const out = [];
        const seen = {};
        for (const b of list) {
            if (b.submap && b.submap !== "")
                continue;
            const mods = modsOf(Number(b.modmask) || 0);
            let key = keyName(b.key);
            if (key === "")
                continue;
            let label = "", group = "", source = "hyprland";
            const desc = String(b.description ?? "").trim();
            let m;
            if ((m = /^frame (\w+) · (.+)$/.exec(desc))) {
                source = "frame"; group = m[1]; label = m[2];
            } else if ((m = /^(\w+) · (.+)$/.exec(desc))) {
                group = m[1].toLowerCase(); label = m[2];
            } else if (desc !== "") {
                label = desc;
                group = guessGroup(key, desc);
            } else {
                const dispatcher = String(b.dispatcher ?? "");
                const arg = String(b.arg ?? "").trim();
                // exec binds read better as the program name
                label = dispatcher.startsWith("exec") && arg !== "" ? arg.split(/\s+/)[0].replace(/^.*\//, "")
                    : dispatcher === "__lua" ? fromKey(key) || "lua bind without a description"
                    : pretty(dispatcher, arg) || [dispatcher, arg].filter(s => s !== "").join(" ");
                group = guessGroup(key, `${dispatcher} ${arg}`);
            }
            // Super+1 … Super+0 become one row; their labels only differ by the number
            if (/^[0-9]$/.test(key) && desc === "") {
                const id = `${mods.join("+")}|${label.replace(/[0-9]+/g, "")}`;
                if (seen[id])
                    continue;
                seen[id] = true;
                key = "1…0";
                label = label.replace(/\s*[0-9]+\s*/g, " ").trim();
            }
            out.push({ mods, key, label, group: groupOrder.includes(group) ? group : "other", source });
        }
        rows = out;
        loaded = true;
    }

    // Rows of one group, frame binds first
    function inGroup(name) {
        return rows.filter(r => r.group === name).sort((a, b) => (a.source === "frame" ? 0 : 1) - (b.source === "frame" ? 0 : 1));
    }

    // What Super+key and Super+Shift+key do, for the keyboard map
    function forKey(key) {
        return rows.filter(r => r.key === key && r.mods.includes("super") && !r.mods.includes("ctrl") && !r.mods.includes("alt"));
    }

    Process {
        id: proc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.parse(JSON.parse(this.text));
                } catch (e) {
                    console.warn(`binds: ${e}`);
                }
            }
        }
    }
}
