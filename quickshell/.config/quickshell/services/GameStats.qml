pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// The game's frame rate for the fps overlay (Config.fpsOverlay). Nothing in Wayland tells a
// shell how fast a game draws, so MangoHud does the counting inside the game: the shell
// writes it a config that draws nothing itself and logs fps every half second to
// /tmp/facet-mangohud, and reads the newest line from there while game mode is on.
// Games need MangoHud loaded (Steam: launch options `mangohud %command%`); without it fps
// stays -1 and the overlay shows only what SystemStats knows.
Singleton {
    id: root

    readonly property string logDir: "/tmp/facet-mangohud"
    readonly property string configFile: `${Quickshell.env("HOME")}/.config/MangoHud/MangoHud.conf`
    readonly property bool active: Config.fpsOverlay && Toggles.gameMode

    property int fps: -1
    property real frametime: 0     // ms

    // The first line marks the file as ours; a MangoHud.conf without it is left alone
    readonly property string config: [
        "# facet: written by the shell for the fps overlay (settings, game mode). Remove this line to keep your own config.",
        "no_display",
        "autostart_log=1",
        "log_interval=500",
        `output_folder=${logDir}`,
        ""
    ].join("\n")

    // Writes the config once the overlay is switched on, unless the file is someone else's
    function writeConfig() {
        Quickshell.execDetached(["sh", "-c", `
            f="$1"; mkdir -p "$(dirname "$f")" "$2"
            if [ ! -s "$f" ] || head -n1 "$f" | grep -q '^# facet:'; then printf '%s' "$3" >"$f"; fi
        `, "facet-mangohud", configFile, logDir, config]);
    }

    Component.onCompleted: if (Config.fpsOverlay) writeConfig()
    Connections {
        target: Config
        function onFpsOverlayChanged() {
            if (Config.fpsOverlay)
                root.writeConfig();
        }
    }

    // Logs of earlier games go when the next game mode starts
    onActiveChanged: {
        fps = -1;
        if (active)
            Quickshell.execDetached(["sh", "-c", 'find "$1" -name "*.csv" -mmin +10 -delete 2>/dev/null', "facet-mangohud", logDir]);
    }

    // What the reader prints: now and the log's mtime (seconds), MangoHud's column names
    // (its third line) and the newest sample
    function parse(text) {
        const lines = text.split("\n");
        const age = Number(lines[0]) - Number(lines[1]);
        const header = (lines[2] ?? "").split(",");
        const values = (lines[3] ?? "").split(",");
        const at = header.indexOf("fps");
        // A log that stopped growing belongs to a game that is gone
        if (at < 0 || isNaN(age) || age > 3) {
            fps = -1;
            return;
        }
        fps = Math.round(Number(values[at]) || 0);
        frametime = Number(values[header.indexOf("frametime")]) || 0;
    }

    Process {
        id: reader
        command: ["sh", "-c", `
            f=$(ls -t "$1"/*.csv 2>/dev/null | grep -v '_summary' | head -n1)
            [ -n "$f" ] || exit 0
            date +%s; stat -c %Y "$f"; sed -n 3p "$f"; tail -n1 "$f"
        `, "facet-mangohud", root.logDir]
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
    }

    Timer {
        running: root.active
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!reader.running) reader.running = true
    }
}
