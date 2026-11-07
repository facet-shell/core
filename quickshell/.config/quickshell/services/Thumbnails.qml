pragma Singleton

import QtQuick
import Quickshell

// The last picture of every canvas window, taken while it was on a screen
// (canvas/CanvasThumbs.qml). Hyprland gives no preview of a window that lies fully off
// every screen, so the overview shows this one instead of a placeholder.
// Files: $XDG_RUNTIME_DIR/facet-thumbs/<address>.png
Singleton {
    id: root

    readonly property string dir: `${Quickshell.env("XDG_RUNTIME_DIR")}/facet-thumbs`
    // address → time of the last picture; a new time makes Image load the file again
    property var stamps: ({})

    function key(address) {
        return String(address ?? "").replace(/[^0-9a-fx]/gi, "");
    }

    function file(address) {
        return `${dir}/${key(address)}.png`;
    }

    // "" until a picture was taken
    function url(address) {
        const t = stamps[key(address)];
        return t ? `file://${file(address)}?${t}` : "";
    }

    function touch(address) {
        const next = Object.assign({}, stamps);
        next[key(address)] = Date.now();
        stamps = next;
    }

    function forget(address) {
        const k = key(address);
        if (!(k in stamps))
            return;
        const next = Object.assign({}, stamps);
        delete next[k];
        stamps = next;
        Quickshell.execDetached(["rm", "-f", "--", `${dir}/${k}.png`]);
    }
}
