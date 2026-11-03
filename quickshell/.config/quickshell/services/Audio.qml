pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.config

// App audio streams, the default devices and the routing through PipeWire.
// goxlr-utility creates one PipeWire output per channel (system, game, chat,
// music) and inputs for the mics; moving a stream there routes the app. Without
// a GoXLR streams are moved between the machine's own sinks and sources the same way.
// WirePlumber remembers the target per app, so routing survives restarts.
Singleton {
    id: root

    readonly property var nodes: Pipewire.nodes.values.filter(n => n.audio)
    // Apps that play audio (they output into a sink)
    readonly property var playback: nodes.filter(n => n.isStream && !isRecording(n) && !isMonitor(n))
    // Apps that record audio (they take input from a source)
    readonly property var recording: nodes.filter(n => n.isStream && isRecording(n) && !isMonitor(n))
    readonly property var sinks: nodes.filter(n => !n.isStream && n.isSink)
    readonly property var sources: nodes.filter(n => !n.isStream && !n.isSink)
    // Sources a person would pick as a microphone
    readonly property var inputs: sources.filter(n => !isMonitor(n))
    readonly property PwNode defaultSink: Pipewire.defaultAudioSink
    readonly property PwNode defaultSource: Pipewire.defaultAudioSource

    // Route keys that exist on this machine, in Config order
    readonly property var outputRoutes: Object.keys(Config.goxlrOutputs).filter(k => findDevice(sinks, Config.goxlrOutputs[k]) !== null)
    readonly property var inputRoutes: Object.keys(Config.goxlrInputs).filter(k => findDevice(sources, Config.goxlrInputs[k]) !== null)
    // A GoXLR is in use when its channels exist in PipeWire; without them the mixer moves
    // apps between the machine's own devices instead of GoXLR channels
    readonly property bool goxlr: outputRoutes.length > 0 || inputRoutes.length > 0

    // Volume and mute only work on tracked nodes
    PwObjectTracker {
        objects: root.playback.concat(root.recording, [root.defaultSink, root.defaultSource].filter(n => n))
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

    // "music", "chat mic" … or "" when the stream is on a non-GoXLR device
    function routeOf(node) {
        const device = deviceOf(node);
        if (!device)
            return "";
        const map = isRecording(node) ? Config.goxlrInputs : Config.goxlrOutputs;
        const list = isRecording(node) ? sources : sinks;
        return Object.keys(map).find(k => findDevice(list, map[k]) === device) ?? "";
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
        const map = isRecording(node) ? Config.goxlrInputs : Config.goxlrOutputs;
        moveTo(node, findDevice(isRecording(node) ? sources : sinks, map[route]));
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
}
