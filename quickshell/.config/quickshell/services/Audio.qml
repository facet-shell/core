pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.config

// App audio streams, the default devices and the routing through PipeWire.
//
// Channels (the app mixer's route chips, the control center's faders, the recorder's tracks)
// come from one of two places, picked by Config.audioChannels ("auto" takes the first that is
// there):
//   goxlr    goxlr-utility's PipeWire outputs per channel (system, game, chat, music) and
//            inputs for the mics; moving a stream there routes the app
//   virtual  the virtual sinks `facet audio channels on` set up (PipeWire loopbacks into the
//            real output, listed in ~/.local/state/facet/audio-channels.json); the shell
//            never makes them itself
// Without either, streams are moved between the machine's own sinks and sources the same way.
// WirePlumber remembers the target per app, so routing survives restarts.
Singleton {
    id: root

    readonly property var nodes: Pipewire.nodes.values.filter(n => n.audio)
    // Apps that play audio (they output into a sink); the virtual channels' own loopback
    // streams are plumbing, not apps
    readonly property var playback: nodes.filter(n => n.isStream && !isRecording(n) && !isMonitor(n) && !isChannelInternal(n))
    // Apps that record audio (they take input from a source)
    readonly property var recording: nodes.filter(n => n.isStream && isRecording(n) && !isMonitor(n) && !isChannelInternal(n))
    readonly property var sinks: nodes.filter(n => !n.isStream && n.isSink)
    readonly property var sources: nodes.filter(n => !n.isStream && !n.isSink)
    // Sources a person would pick as a microphone
    readonly property var inputs: sources.filter(n => !isMonitor(n))
    readonly property PwNode defaultSink: Pipewire.defaultAudioSink
    readonly property PwNode defaultSource: Pipewire.defaultAudioSource

    // ── Virtual channels (facet audio channels) ──────────────

    readonly property string channelsFile: `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/facet/audio-channels.json`
    // { output, channels: [{ key, label, sink }] } as the facet command wrote it; null while
    // they are not set up
    property var virtualSetup: null

    FileView {
        id: channelsView
        path: root.channelsFile
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                root.virtualSetup = parsed && Array.isArray(parsed.channels) ? parsed : null;
            } catch (e) {
                console.warn(`audio: ${root.channelsFile} is not valid JSON (${e})`);
                root.virtualSetup = null;
            }
        }
        onLoadFailed: root.virtualSetup = null
    }

    // A file that is not there yet is not watched; `facet audio channels on` restarts the
    // shell anyway, this only covers a setup made while the shell keeps running
    Timer {
        interval: 15000
        repeat: true
        running: root.virtualSetup === null
        onTriggered: channelsView.reload()
    }

    // [{ key, label, node }] of the set-up channels whose sink is in PipeWire right now
    readonly property var virtualChannels: {
        const out = [];
        for (const c of virtualSetup?.channels ?? []) {
            const key = String(c.key ?? "");
            const node = sinks.find(n => n.name === c.sink) ?? null;
            if (key !== "" && node)
                out.push({ key, label: String(c.label || key.charAt(0).toUpperCase() + key.slice(1)), node });
        }
        return out;
    }
    readonly property var virtualNodes: virtualChannels.map(c => c.node)
    // The loopbacks' link groups: their playback streams (into the real output) carry them too
    readonly property var virtualGroups: virtualNodes.map(n => String((n.properties ?? {})["node.link-group"] ?? "")).filter(g => g !== "")

    // The loopback streams that carry the channels into the real output
    readonly property var channelLoopbacks: nodes.filter(n => n.isStream && !isRecording(n) && isChannelInternal(n))
    // Where the virtual channels play: the device their loopbacks are linked to, else the one
    // the setup picked
    readonly property PwNode channelOutput: {
        for (const s of channelLoopbacks) {
            const d = deviceOf(s);
            if (d && !virtualNodes.includes(d))
                return d;
        }
        return deviceByName(String(virtualSetup?.output ?? ""));
    }
    // Real outputs a channel loopback can play into (not the channels themselves, not the
    // recorder's mix sink)
    readonly property var hardwareSinks: sinks.filter(n => !virtualNodes.includes(n) && n.name !== "facet-rec")

    // ── GoXLR channels ───────────────────────────────────────

    // Route keys whose GoXLR device exists on this machine, in Config order
    readonly property var goxlrOutputKeys: Object.keys(Config.goxlrOutputs).filter(k => goxlrDevice(sinks, Config.goxlrOutputs[k]) !== null)
    readonly property var goxlrInputKeys: Object.keys(Config.goxlrInputs).filter(k => goxlrDevice(sources, Config.goxlrInputs[k]) !== null)
    // "auto" only takes the GoXLR for one that is really there: a device with GoXLR in its
    // name, or the utility answering (renamed devices). "goxlr" in the settings skips the check.
    readonly property bool goxlrFound: GoXLR.available
        || goxlrOutputKeys.some(k => looksGoxlr(goxlrDevice(sinks, Config.goxlrOutputs[k])))
        || goxlrInputKeys.some(k => looksGoxlr(goxlrDevice(sources, Config.goxlrInputs[k])))

    // ── Which channels are in use ────────────────────────────

    // "goxlr", "virtual" or "none"
    readonly property string channelSource: {
        const s = Config.audioChannels;
        if (s === "goxlr" || s === "virtual" || s === "none")
            return s;
        if (goxlrFound && goxlrOutputKeys.length + goxlrInputKeys.length > 0)
            return "goxlr";
        if (virtualChannels.length > 0)
            return "virtual";
        return "none";
    }
    // What can be picked in the settings: the GoXLR and/or the virtual channels, when there
    readonly property bool goxlrAvailable: goxlrOutputKeys.length + goxlrInputKeys.length > 0
    readonly property bool virtualAvailable: virtualChannels.length > 0

    // Route keys that exist on this machine, in Config order (GoXLR) or setup order (virtual)
    readonly property var outputRoutes: channelSource === "goxlr" ? goxlrOutputKeys
        : channelSource === "virtual" ? virtualChannels.map(c => c.key) : []
    readonly property var inputRoutes: channelSource === "goxlr" ? goxlrInputKeys : []
    // A GoXLR is in use when its channels exist in PipeWire
    readonly property bool goxlr: channelSource === "goxlr" && (outputRoutes.length > 0 || inputRoutes.length > 0)
    // The virtual channels are in use
    readonly property bool virtualActive: channelSource === "virtual" && outputRoutes.length > 0
    // Apps are routed onto channels (either kind); without them the mixer moves apps between
    // the machine's own devices
    readonly property bool routed: goxlr || virtualActive

    // A stream moved onto a channel from the shell (the mixer), for Channels' memory
    signal routeChosen(var node, string route)

    // Volume and mute only work on tracked nodes
    PwObjectTracker {
        objects: root.playback.concat(root.recording, root.virtualNodes, [root.defaultSink, root.defaultSource, root.channelOutput].filter(n => n))
    }

    // Quickshell 0.3 reports isSink = true for playback streams (Stream/Output/Audio), so
    // streams are told apart by their media.class type, not by isSink
    function isRecording(node) {
        return node.type === PwNodeType.AudioInStream;
    }

    function isMonitor(node) {
        const props = node.properties ?? {};
        return props["stream.monitor"] === "true" || props["stream.monitor"] === true;
    }

    // The loopback streams behind facet's virtual channels (node names facet-*), or behind
    // channels the setup took over from an existing set of sinks (same link group)
    function isChannelInternal(node) {
        const props = node.properties ?? {};
        if (String(node.name ?? "").startsWith("facet-"))
            return true;
        const group = String(props["node.link-group"] ?? "");
        return group !== "" && virtualGroups.includes(group);
    }

    // "GoXLR Music" in the config matches "GoXLR Music" and "GoXLRMini Music" (the Mini
    // names its devices that way); spaces and case do not matter
    function channelKey(text) {
        return String(text ?? "").toLowerCase().replace(/\s+/g, "").replace(/^goxlr(mini)?/, "");
    }

    function findDevice(list, label) {
        const wanted = channelKey(label);
        if (wanted === "")
            return null;
        return list.find(n => channelKey(n.description) === wanted || channelKey(n.nickname) === wanted) ?? null;
    }

    // findDevice for the GoXLR's channels: never one of the virtual channels, whose "Game"
    // would otherwise match "GoXLR Game"
    function goxlrDevice(list, label) {
        return findDevice(list.filter(n => !virtualNodes.includes(n) && !String(n.name ?? "").startsWith("facet-")), label);
    }

    function looksGoxlr(device) {
        return device !== null && /goxlr/i.test(`${device.description ?? ""} ${device.nickname ?? ""} ${device.name ?? ""}`);
    }

    function appName(node) {
        const props = node.properties ?? {};
        return props["application.name"] || node.description || node.name || "unknown";
    }

    function mediaName(node) {
        return (node.properties ?? {})["media.name"] ?? "";
    }

    function iconName(node) {
        const props = node.properties ?? {};
        return props["application.icon-name"] || appName(node).toLowerCase().replace(/\s+/g, "-");
    }

    // The link between a stream and its device, if any
    function linkOf(node) {
        return Pipewire.linkGroups.values.find(g => isRecording(node) ? g.target === node : g.source === node) ?? null;
    }

    function deviceOf(node) {
        const link = linkOf(node);
        return link ? (isRecording(node) ? link.source : link.target) : null;
    }

    // No running link means the app is paused or silent
    function isIdle(node) {
        const link = linkOf(node);
        return !link || link.state !== PwLinkState.Active;
    }

    // The device behind a route key in the channels in use, or null
    function routeDevice(route, input) {
        if (channelSource === "goxlr") {
            const map = input ? Config.goxlrInputs : Config.goxlrOutputs;
            return map[route] === undefined ? null : goxlrDevice(input ? sources : sinks, map[route]);
        }
        if (channelSource === "virtual" && !input)
            return virtualChannels.find(c => c.key === route)?.node ?? null;
        return null;
    }

    // How a route key is shown: the virtual channel's label ("Game"), else the key ("music")
    function routeLabel(route) {
        return virtualChannels.find(c => c.key === route)?.label ?? route;
    }

    // "music", "chat mic" … or "" when the stream is on a device that is no channel
    function routeOf(node) {
        const device = deviceOf(node);
        if (!device)
            return "";
        const input = isRecording(node);
        return (input ? inputRoutes : outputRoutes).find(k => routeDevice(k, input) === device) ?? "";
    }

    // "Starship/Matisse HD Audio Controller Analog Stereo", as wpctl and pavucontrol show it
    function deviceLabel(device) {
        return device ? (device.description || device.nickname || device.name || "unknown") : "default";
    }

    // Any sink or source by its node name (streams report the device they are linked to)
    function deviceByName(name) {
        return name === "" ? null : sinks.concat(sources).find(n => n.name === name) ?? null;
    }

    function move(node, route) {
        const device = routeDevice(route, isRecording(node));
        if (!device)
            return;
        moveTo(node, device);
        routeChosen(node, route);
    }

    // WirePlumber stores the target per app like a GoXLR route, so the app stays there
    function moveTo(node, device) {
        if (!device)
            return;
        // pipewire-pulse indexes streams by object.serial, not by the PipeWire node id
        const serial = (node.properties ?? {})["object.serial"];
        if (serial === undefined)
            return;
        Quickshell.execDetached(["pactl", isRecording(node) ? "move-source-output" : "move-sink-input", String(serial), device.name]);
    }

    function setVolume(node, value) {
        if (node?.audio)
            node.audio.volume = Math.max(0, Math.min(1, value));
    }

    // The speaker icon for a volume (0..1): off when muted or silent, then one more wave per
    // third, so the bar, the OSD and the control center agree on the thresholds
    function volumeIcon(volume, muted) {
        const v = Number(volume) || 0;
        if (muted || v < 0.005)
            return "volume_off";
        return v < 0.34 ? "volume_mute" : v < 0.67 ? "volume_down" : "volume_up";
    }

    function micIcon(muted) {
        return muted ? "mic_off" : "mic";
    }

    function toggleMute(node) {
        if (node?.audio)
            node.audio.muted = !node.audio.muted;
    }

    // Same as picking the device in settings > sound
    function setDefault(device) {
        if (!device)
            return;
        if (device.isSink)
            Pipewire.preferredDefaultAudioSink = device;
        else
            Pipewire.preferredDefaultAudioSource = device;
    }

    // ── The output everything ends up on ─────────────────────

    // With the virtual channels the default output is the System channel, and the real
    // device is where the channels play into; otherwise it is simply the default output.
    // The mixer's "output" row and settings > sound use these.
    readonly property PwNode masterOutput: virtualActive ? channelOutput : defaultSink
    readonly property var masterOutputs: virtualActive ? hardwareSinks : sinks

    function pickOutput(device) {
        if (!device)
            return;
        if (!virtualActive) {
            setDefault(device);
            return;
        }
        // Right away for every channel, then into the PipeWire config for the next start
        for (const s of channelLoopbacks)
            moveTo(s, device);
        Quickshell.execDetached(["sh", "-c", 'f="$HOME/.local/bin/facet"; [ -x "$f" ] && exec "$f" audio channels output "$1" >/dev/null 2>&1', "facet-audio", device.name]);
    }
}
