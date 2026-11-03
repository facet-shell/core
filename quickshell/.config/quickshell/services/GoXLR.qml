pragma Singleton

import QtQuick
import QtWebSockets
import Quickshell
import qs.config

// Fader levels and fader mute buttons of the GoXLR, from the goxlr-utility API.
// Levels are display only, the faders are physical; mutes can be toggled.
//
// Expected in the utility's status JSON:
//   mixers.<serial>.levels.volumes.<Channel>   0..255
//   mixers.<serial>.fader_status.<A..D>         { channel: "Mic", mute_state: "Unmuted" }
//   mixers.<serial>.cough_button.state           "Unmuted" | "MutedToX" | "MutedToAll"  (mic mute button)
// If your goxlr-utility version names things differently, adjust parse() and setMuted().
//
// Live over the utility's websocket (<goxlrApi>/api/websocket, same port): it answers
// { id, data: "GetStatus" } with the whole status once, then pushes every change as an
// RFC 6902 patch ({ data: { Patch: [...] } }) the moment the daemon sees it, and takes the
// same commands as POST /api/command. Polling GET /api/get-devices fetched the whole
// status every 300-600 ms, so a fader move showed up late; that poll now only runs while
// the socket is down (utility restarting, not running, or too old for the socket).
Singleton {
    id: root

    property bool available: false
    property string serial: ""
    // [{ key, label, fader }] in fader order A..D. Only replaced when a fader is assigned
    // another channel, so the rows in the control center stay put between polls
    property var faders: []
    // key → { level (0..100), muted }, replaced only when a value changed
    property var live: ({})
    // Every channel's volume, lowercase name → 0..100 (system, game, chat, music, mic, …),
    // faders or not; a Mini has no fader for System, so the bar and the control center
    // set that one over the API
    property var volumes: ({})
    readonly property bool systemOnFader: faders.some(f => f.channel === "system")
    // Mic mute button on the GoXLR (cough button), separate from the mic fader's mute
    property bool micButtonMuted: false
    // Poll faster while the control center shows the levels (only while the websocket is down)
    property bool fast: false

    // The whole status as the utility last sent it over the websocket, kept to apply its
    // patches to; null while the socket is down or the first status has not come yet
    property var daemonStatus: null
    readonly property bool socketOpen: socket.status === WebSocket.Open
    // Changes arrive as patches, no poll needed
    readonly property bool streaming: socketOpen && daemonStatus !== null
    property int nextId: 1
    // Request id → callback(data) for answers over the websocket
    property var pending: ({})
    // Wait before the next connection attempt, doubled after each failed one
    property int retryDelay: 1000

    // { key, label, fader, level, muted } or null
    function fader(key) {
        const f = faders.find(f => f.key === key);
        if (!f)
            return null;
        const l = live[key] ?? { level: 0, muted: false };
        return { key: f.key, label: f.label, fader: f.fader, level: l.level, muted: l.muted };
    }

    function state(key) {
        return live[key] ?? { level: 0, muted: false };
    }

    function request(method, path, body, onDone) {
        const xhr = new XMLHttpRequest();
        xhr.open(method, `${Config.goxlrApi}${path}`);
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status !== 200) {
                root.available = false;
                return;
            }
            if (onDone)
                onDone(xhr.responseText);
        };
        if (body !== null)
            xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(body);
    }

    function refresh() {
        request("GET", "/api/get-devices", null, text => {
            const was = root.available;
            try {
                parse(JSON.parse(text));
            } catch (e) {
                console.warn(`goxlr: ${e}`);
                root.available = false;
            }
            // The utility is back: connect now instead of waiting out the backoff
            if (!was && root.available && socket.status !== WebSocket.Open && socket.status !== WebSocket.Connecting) {
                root.retryDelay = 1000;
                reconnect.stop();
                socket.active = true;
            }
        });
    }

    // ── Websocket ────────────────────────────────────────────

    function send(data, onDone) {
        const id = root.nextId++;
        if (onDone)
            root.pending[id] = onDone;
        socket.sendTextMessage(JSON.stringify({ id, data }));
    }

    function loadStatus() {
        send("GetStatus", data => {
            if (data?.Status === undefined) {
                console.warn(`goxlr: GetStatus over the websocket answered ${JSON.stringify(data)}`);
                return;
            }
            root.daemonStatus = data.Status;
            root.take(root.daemonStatus);
        });
    }

    // parse() for the socket; odd data must not break the message handler
    function take(data) {
        try {
            parse(data);
        } catch (e) {
            console.warn(`goxlr: ${e}`);
            root.available = false;
        }
    }

    function receive(message) {
        let msg;
        try {
            msg = JSON.parse(message);
        } catch (e) {
            console.warn(`goxlr: websocket sent something that is not JSON: ${e}`);
            return;
        }
        const data = msg.data;
        if (data?.Patch !== undefined) {
            // Patches from before the first status are already in it
            if (root.daemonStatus === null)
                return;
            try {
                root.daemonStatus = applyPatch(root.daemonStatus, data.Patch);
            } catch (e) {
                console.warn(`goxlr: a patch did not fit (${e}), loading the whole status again`);
                root.daemonStatus = null;
                root.loadStatus();
                return;
            }
            root.take(root.daemonStatus);
            return;
        }
        const callback = root.pending[msg.id];
        delete root.pending[msg.id];
        if (callback)
            callback(data);
    }

    // Applies an RFC 6902 patch to doc in place and returns the result (a patch on the
    // root path replaces it). The utility builds its patches with json_patch::diff, which
    // only writes add, remove and replace; anything else, or a path that does not fit the
    // kept status, throws, and receive() loads the whole status again.
    function applyPatch(doc, ops) {
        const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
        for (const op of ops) {
            if (op.op !== "add" && op.op !== "replace" && op.op !== "remove")
                throw new Error(`unsupported op ${op.op}`);
            if (op.path === "") {
                if (op.op === "remove")
                    throw new Error("cannot remove the whole document");
                doc = op.value;
                continue;
            }
            if (!op.path.startsWith("/"))
                throw new Error(`bad path ${op.path}`);
            // JSON Pointer: ~1 is "/", ~0 is "~", in that order
            const keys = op.path.slice(1).split("/").map(k => k.replace(/~1/g, "/").replace(/~0/g, "~"));
            const last = keys.pop();
            let parent = doc;
            for (const k of keys) {
                if (parent === null || typeof parent !== "object" || !has(parent, k))
                    throw new Error(`no ${op.path}`);
                parent = parent[k];
            }
            if (parent === null || typeof parent !== "object")
                throw new Error(`no ${op.path}`);
            if (Array.isArray(parent)) {
                const index = last === "-" ? parent.length : /^(0|[1-9][0-9]*)$/.test(last) ? Number(last) : -1;
                const limit = op.op === "add" ? parent.length : parent.length - 1;
                if (index < 0 || index > limit || (last === "-" && op.op !== "add"))
                    throw new Error(`no ${op.path}`);
                if (op.op === "add")
                    parent.splice(index, 0, op.value);
                else if (op.op === "replace")
                    parent[index] = op.value;
                else
                    parent.splice(index, 1);
            } else {
                if (op.op !== "add" && !has(parent, last))
                    throw new Error(`no ${op.path}`);
                if (op.op === "remove")
                    delete parent[last];
                else
                    parent[last] = op.value;
            }
        }
        return doc;
    }

    WebSocket {
        id: socket
        // http://host:port → ws://host:port (https → wss)
        url: `${Config.goxlrApi.replace(/^http/, "ws").replace(/\/+$/, "")}/api/websocket`
        active: true

        onStatusChanged: {
            if (status === WebSocket.Open) {
                console.info("goxlr: live over the utility's websocket");
                root.retryDelay = 1000;
                root.loadStatus();
            } else if ((status === WebSocket.Closed || status === WebSocket.Error) && active) {
                if (root.daemonStatus !== null)
                    console.warn(`goxlr: lost the utility's websocket (${errorString || "closed"}), polling until it is back`);
                root.daemonStatus = null;
                root.pending = {};
                // Opening again needs active to go false and back to true
                active = false;
                reconnect.interval = root.retryDelay;
                reconnect.restart();
                root.retryDelay = Math.min(root.retryDelay * 2, 30000);
            }
        }
        onTextMessageReceived: message => root.receive(message)
    }

    Timer {
        id: reconnect
        onTriggered: socket.active = true
    }

    // Sends a GoXLRCommand for this mixer: over the websocket when it is up (the utility's
    // patch then brings the new state), else over HTTP, polling right after when confirm
    function command(cmd, confirm) {
        if (serial === "")
            return;
        const body = { Command: [serial, cmd] };
        if (socketOpen)
            send(body, data => {
                if (data?.Error !== undefined)
                    console.warn(`goxlr: ${JSON.stringify(cmd)} failed: ${data.Error}`);
            });
        else
            request("POST", "/api/command", JSON.stringify(body), () => {
                if (confirm)
                    refresh();
            });
    }

    function parse(data) {
        const id = Object.keys(data.mixers ?? {})[0];
        if (!id) {
            available = false;
            return;
        }
        const mixer = data.mixers[id];
        const volumes = mixer.levels?.volumes ?? {};
        const status = mixer.fader_status ?? {};
        const list = [];
        const next = {};
        const all = {};
        const now = Date.now();
        for (const name of Object.keys(volumes)) {
            const key = name.toLowerCase();
            // Set from here a moment ago: a patch or poll from before the device took the
            // newest value would make the slider jump back
            all[key] = now - (setAt[key] ?? 0) < 600 && root.volumes[key] !== undefined
                ? root.volumes[key] : Math.round((volumes[name] ?? 0) / 255 * 100);
        }
        if (JSON.stringify(all) !== JSON.stringify(root.volumes))
            root.volumes = all;
        for (const letter of Object.keys(status).sort()) {
            // Each fader is its own channel (Game and System are two, also on a Mini)
            const channel = String(status[letter].channel ?? "");
            const key = channel.toLowerCase();
            list.push({ key, label: key, fader: letter, channel: key });
            next[key] = {
                level: Math.round((volumes[channel] ?? 0) / 255 * 100),
                muted: String(status[letter].mute_state ?? "Unmuted") !== "Unmuted"
            };
        }
        const sameFaders = list.length === faders.length
            && list.every((f, i) => f.key === faders[i].key && f.fader === faders[i].fader && f.label === faders[i].label && f.channel === faders[i].channel);
        if (!sameFaders)
            faders = list;
        if (JSON.stringify(next) !== JSON.stringify(live))
            live = next;
        micButtonMuted = String(mixer.cough_button?.state ?? "Unmuted") !== "Unmuted";
        profile = String(mixer.profile_name ?? "");
        serial = id;
        available = true;
    }

    function setMuted(key, muted) {
        const target = fader(key);
        if (!target || serial === "")
            return;
        // Show it right away; the utility's patch (or the next poll) confirms
        live = Object.assign({}, live, { [key]: Object.assign({}, state(key), { muted }) });
        command({ SetFaderMuteState: [target.fader, muted ? "MutedToAll" : "Unmuted"] }, true);
    }

    // Sets a channel's volume (0..100) over the API, e.g. "System" on a Mini, which has no
    // fader for it. Shown right away; the utility's patch (or the next poll) confirms.
    // A slider sends a value on every mouse move; only the newest one goes out, every 60 ms
    function setChannelVolume(channel, level) {
        if (serial === "")
            return;
        level = Math.max(0, Math.min(100, Math.round(level)));
        const name = channel.charAt(0).toUpperCase() + channel.slice(1).toLowerCase();
        const key = name.toLowerCase();
        volumes = Object.assign({}, volumes, { [key]: level });
        setAt = Object.assign({}, setAt, { [key]: Date.now() });
        pendingVolumes = Object.assign({}, pendingVolumes, { [name]: level });
        if (!sendVolumes.running)
            sendVolumes.start();
    }

    // When each channel was last set from the shell (ms), see parse()
    property var setAt: ({})
    property var pendingVolumes: ({})

    Timer {
        id: sendVolumes
        interval: 60
        onTriggered: {
            const pending = root.pendingVolumes;
            root.pendingVolumes = {};
            for (const name of Object.keys(pending))
                root.command({ SetVolume: [name, Math.round(pending[name] / 100 * 255)] }, false);
        }
    }

    // The profile that is loaded now (mixer.profile_name), and switching to another one,
    // e.g. for game mode. LoadProfile takes the name and whether to keep it as the profile
    // the utility starts with (false: only for now). Not tried on a device yet.
    property string profile: ""

    function loadProfile(name) {
        if (serial === "" || name === "" || name === profile)
            return;
        command({ LoadProfile: [name, false] }, true);
    }

    function stepSystem(delta) {
        setChannelVolume("System", (volumes.system ?? 0) + delta);
    }

    // Fallback while the websocket is down. A utility that answers over HTTP but not on the
    // socket (too old) keeps the old rate; one that does not answer at all is only checked
    // every 2 s, and the socket connects as soon as it answers again (see refresh())
    Timer {
        interval: root.available ? (root.fast ? 300 : 600) : 2000
        running: !root.streaming
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
