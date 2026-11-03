pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Opens a video or a picture in the editor window (editor/EditorWindow.qml): "edit" on a
// recording's or screenshot's notification, the media app (Super+G) and
// `qs ipc call editor open <file>` all come through here. Paint (newPicture) too: an
// empty page in the picture editor, no app of its own.
Singleton {
    id: root

    signal openRequested(string file)

    function isVideo(path) {
        return /\.(mp4|mkv|webm|mov)$/i.test(path);
    }

    function isImage(path) {
        return /\.(png|jpe?g|webp|gif|bmp)$/i.test(path);
    }

    function open(file) {
        if (isVideo(file) || isImage(file))
            openRequested(file);
    }

    // ── Paint: the picture editor with an empty page ─────────

    // paper: theme (the theme's background), white or clear (transparent)
    readonly property var papers: ["theme", "white", "clear"]

    // A blank PNG in <pictures>/paintings, opened in the picture editor once it is there.
    // ffmpeg (a dependency anyway) makes it, so nothing new is needed. "new" in the media
    // app, `qs ipc call editor paint`, the launcher (frameshell-paint.desktop).
    function newPicture(paper, width, height) {
        if (paintProc.running)
            return;
        const w = Math.max(16, Math.round(width || 1920)), h = Math.max(16, Math.round(height || 1080));
        // 0xRRGGBB: ffmpeg's own spelling, nothing in a filter string to quote
        const color = paper === "white" ? "white" : paper === "clear" ? "black@0" : `0x${Theme.bg.toString().slice(-6)}`;
        const source = `color=c=${color}:s=${w}x${h},format=${paper === "clear" ? "rgba" : "rgb24"}`;
        const d = new Date();
        const p = n => String(n).padStart(2, "0");
        const stamp = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
        paintProc.command = ["sh", "-c",
            'dir=$(xdg-user-dir PICTURES 2>/dev/null); [ -n "$dir" ] && [ "$dir" != "$HOME" ] || dir=$HOME/Pictures; '
            + 'dir=$dir/paintings; mkdir -p "$dir" && f=$dir/painting-$2.png && '
            + 'ffmpeg -y -nostdin -v error -f lavfi -i "$1" -frames:v 1 "$f" && printf %s "$f"',
            "frame-paint", source, stamp];
        paintProc.running = true;
    }

    Process {
        id: paintProc

        stdout: StdioCollector {
            id: paintOut
        }
        stderr: StdioCollector {
            id: paintErr
        }
        onExited: code => {
            const file = paintOut.text.trim();
            if (code === 0 && file !== "") {
                root.open(file);
                return;
            }
            Notifications.push({
                app: "editor",
                glyph: "✗",
                title: "no empty page",
                body: paintErr.text.trim().split("\n").pop() || `ffmpeg stopped (${code})`
            });
        }
    }
}
