pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Clipboard history for the launcher (;, Super+V), from facet-clip (quickshell/.local/bin):
// Hyprland starts `wl-paste --watch facet-clip store` (hypr/facet/shell.lua), which keeps
// every copy as a file in ~/.cache/facet/clipboard. Pictures are files already, so the
// launcher shows them as they are.
//
// entries: [{ id, kind (txt, png, jpg, webp, gif), text (a text's first 700 characters, or a
//   picture's size), image, preview (a picture's file, else "") }]
Singleton {
    id: root

    property var entries: []
    property bool loaded: false
    readonly property string tool: `${Quickshell.env("HOME")}/.local/bin/facet-clip`
    readonly property string dir: `${Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache"}/facet/clipboard`

    function refresh() {
        list.running = true;
    }

    function parse(text) {
        const out = [];
        for (const line of text.split("\n")) {
            const parts = line.split("\t");
            if (parts.length < 3)
                continue;
            const [id, kind] = parts;
            const image = kind !== "txt";
            out.push({
                id, kind, image,
                // facet-clip writes a text's line breaks as \x1f, so one entry stays one line
                text: image ? `${kind} · ${parts[2]}` : parts.slice(2).join("\t").replace(/\x1f/g, "\n"),
                preview: image ? `${dir}/${id}.${kind}` : ""
            });
        }
        entries = out;
        loaded = true;
    }

    function copy(entry) {
        Quickshell.execDetached([tool, "copy", entry.id]);
    }

    function remove(entry) {
        entries = entries.filter(e => e.id !== entry.id);
        Quickshell.execDetached([tool, "delete", entry.id]);
    }

    Process {
        id: list
        command: [root.tool, "list"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
    }
}
