pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.config

// Screen recording with wf-recorder, started from the screenshot tool (Super+Shift+R,
// `qs ipc call screenshot record`): the same picker, then the region, window or screen is
// recorded until you stop it, from the bar (● rec) or with the same key again. Videos go
// to ~/Videos/recordings (your XDG videos folder); a notification offers open, folder,
// copy (the file, for pasting into chats) and delete.
//
// Sound: the picker's audio panel picks the channels (the GoXLR's System, Game, Chat, Music,
// the mic …, else the default output and input) and a level for each. More than nothing
// chosen, facet-record-mix loops them into one sink that wf-recorder records
// (quickshell/.local/bin/facet-record-mix). The choice is kept in
// ~/.local/state/facet/record-audio.json.
//
// Next to the mixed sound every chosen channel is also recorded on its own, into
// <recording>.tracks/ (one FLAC per channel, tracks.json, video-started), so the recording
// editor (editor/, "edit" on the notification) can set each one's level afterwards.
Singleton {
    id: root

    // The folder with the separate channels of a recording
    function tracksDir(video) {
        return video.replace(/\.[^./]+$/, "") + ".tracks";
    }

    property bool recording: false
    property bool stopping: false
    property real startedAt: 0
    property real now: Date.now()
    readonly property int seconds: recording ? Math.max(0, Math.floor((now - startedAt) / 1000)) : 0
    readonly property string elapsed: `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`

    property string videosDir: `${Quickshell.env("HOME")}/Videos`
    readonly property string folder: `${videosDir}/recordings`
    property string file: ""

    readonly property string mixTool: `${Quickshell.env("HOME")}/.local/bin/facet-record-mix`
    property bool mixing: false

    // ── Audio channels ───────────────────────────────────────

    // What can be recorded: [{ key, label, source }], source as pactl names it.
    // GoXLR: its outputs (their monitors) and inputs from Config.goxlrOutputs / goxlrInputs,
    // plus its stream mix. Virtual channels (facet audio channels): every channel's monitor
    // and the default input. Neither: the default output's monitor and the default input.
    readonly property var channels: {
        const out = [];
        if (Audio.channelSource === "goxlr") {
            for (const key of Object.keys(Config.goxlrOutputs)) {
                const node = Audio.goxlrDevice(Audio.sinks, Config.goxlrOutputs[key]);
                if (node)
                    out.push({ key, label: key, source: `${node.name}.monitor` });
            }
            for (const key of Object.keys(Config.goxlrInputs)) {
                const node = Audio.goxlrDevice(Audio.sources, Config.goxlrInputs[key]);
                if (node)
                    out.push({ key, label: key, source: node.name });
            }
            const mix = Audio.findDevice(Audio.sources, "GoXLR Stream Mix 1");
            if (mix)
                out.push({ key: "stream mix", label: "stream mix", source: mix.name });
        } else if (Audio.virtualActive) {
            for (const c of Audio.virtualChannels)
                out.push({ key: c.key, label: c.label.toLowerCase(), source: `${c.node.name}.monitor` });
        }
        const mic = Audio.sources.find(n => n.name === Pipewire.defaultAudioSource?.name && !Audio.isMonitor(n)) ?? Audio.inputs[0];
        if (Audio.virtualActive && mic && !out.some(c => c.key === "mic"))
            out.push({ key: "mic", label: "mic", source: mic.name });
        if (out.length === 0) {
            const sink = Audio.sinks.find(n => n.name === Pipewire.defaultAudioSink?.name) ?? Audio.sinks[0];
            if (sink)
                out.push({ key: "desktop", label: "desktop", source: `${sink.name}.monitor` });
            if (mic)
                out.push({ key: "mic", label: "mic", source: mic.name });
        }
        return out;
    }

    // key → { on, level 0..1 }; unknown keys are off at full level
    function channelState(key) {
        const s = saved.channels[key];
        return { on: s?.on === true, level: s?.level === undefined ? 1 : Math.max(0, Math.min(1, Number(s.level))) };
    }

    function setChannel(key, on, level) {
        const next = Object.assign({}, saved.channels);
        next[key] = { on, level: Math.max(0, Math.min(1, level)) };
        saved.channels = next;
        state.writeAdapter();
    }

    readonly property var chosen: channels.filter(c => channelState(c.key).on)

    FileView {
        id: state
        path: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/facet/record-audio.json`
        printErrors: false
        JsonAdapter {
            id: saved
            property var channels: ({})
        }
    }

    // ── Recording ────────────────────────────────────────────

    // args as grim takes them: ["-g", "x,y wxh"] or ["-o", "<monitor>"]
    function start(args) {
        if (recording || proc.running)
            return;
        const d = new Date();
        const p = n => String(n).padStart(2, "0");
        file = `${folder}/recording-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.mp4`;
        const mix = chosen.map(c => `${c.source}=${Math.round(channelState(c.key).level * 100)}`);
        const tracks = chosen.map(c => `${c.key}|${c.source}|${Math.round(channelState(c.key).level * 100)}`);
        mixing = mix.length > 0;
        if (mixing) {
            // The mix first, then every channel on its own track, then wf-recorder on the mix's
            // monitor. The mix sources come before the first "--", the tracks before the
            // second, the area after it (bash, for the arrays). video-started is the moment
            // the picture starts, for lining the tracks up.
            proc.command = ["bash", "-c", 'mkdir -p "$(dirname "$1")" && f=$1 && m=$2 && d=$3 && shift 3 && srcs=() && trk=() && while [ "$1" != "--" ]; do srcs+=("$1"); shift; done && shift && while [ "$1" != "--" ]; do trk+=("$1"); shift; done && shift && "$m" start "${srcs[@]}" >/dev/null && { "$m" tracks "$d" "${trk[@]}" || echo "facet-record: the separate tracks did not start" >&2; } && { date +%s%3N >"$d/video-started" 2>/dev/null || true; } && exec wf-recorder -f "$f" --audio=facet-rec.monitor "$@"',
                "facet-record", file, mixTool, tracksDir(file)].concat(mix).concat(["--"]).concat(tracks).concat(["--"]).concat(args);
        } else {
            proc.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && f=$1 && shift && exec wf-recorder -f "$f" "$@"', "facet-record", file].concat(args);
        }
        proc.running = true;
        startedAt = Date.now();
        now = startedAt;
        recording = true;
        stopping = false;
    }

    // wf-recorder finishes the file on SIGINT, as with Ctrl+C
    function stop() {
        if (!recording || stopping)
            return;
        stopping = true;
        proc.signal(2);
    }

    Process {
        id: proc
        stderr: StdioCollector {
            id: errors
        }
        onExited: code => {
            const file = root.file;
            const name = file.slice(file.lastIndexOf("/") + 1);
            const wasStopped = root.stopping;
            root.now = Date.now();
            // Read before recording turns false, which sets the clock back to 0:00
            const length = root.elapsed;
            root.recording = false;
            root.stopping = false;
            if (root.mixing) {
                root.mixing = false;
                Quickshell.execDetached([root.mixTool, "stop"]);
            }
            // wf-recorder ends with 0 or the signal's code when it was stopped
            if (!wasStopped && code !== 0) {
                Notifications.push({ app: "recording", glyph: "✗", title: "recording failed",
                    body: errors.text.trim().split("\n").pop() || "is wf-recorder installed?" });
                return;
            }
            Notifications.push({
                app: "recording",
                glyph: "●",
                title: `recording saved · ${length}`,
                body: name,
                actions: [
                    { id: "open", label: "open", style: "ok" },
                    { id: "edit", label: "edit", style: "" },
                    { id: "folder", label: "folder", style: "" },
                    { id: "copy", label: "copy", style: "" },
                    { id: "delete", label: "delete", style: "" }
                ],
                onAction: id => {
                    if (id === "open")
                        Quickshell.execDetached(["xdg-open", file]);
                    else if (id === "edit")
                        Editor.open(file);
                    else if (id === "folder")
                        Quickshell.execDetached(["xdg-open", root.folder]);
                    else if (id === "copy")
                        // As a file, so chat apps and file managers take the video itself
                        Quickshell.execDetached(["sh", "-c", 'printf "file://%s\\n" "$1" | wl-copy --type text/uri-list', "facet-record", file]);
                    else if (id === "delete")
                        // With its separate tracks and the editor's project
                        Quickshell.execDetached(["rm", "-rf", "--", file, root.tracksDir(file), file.replace(/\.[^./]+$/, "") + ".edit.json"]);
                }
            });
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.recording
        onTriggered: root.now = Date.now()
    }

    Process {
        command: ["xdg-user-dir", "VIDEOS"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const dir = this.text.trim();
                if (dir !== "")
                    root.videosDir = dir;
            }
        }
    }
}
