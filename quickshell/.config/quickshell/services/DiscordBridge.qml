pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Unix socket the Vencord plugin (vencord/plugins/shellBridge) connects to.
// One JSON object per line in both directions.
//
// Discord → shell:
//   { type: "message", kind: "dm" | "group" | "server", author, channel (group DM: its name), guild, mentioned,
//     content, avatar, channelId, guildId }
//   { type: "voice", action: "join" | "leave", user, channel, count, avatar, channelId, watched }
//   { type: "event", name, guild, channel, location, channelId, guildId }
//   { type: "call", state: "ringing" | "ended", reason ("accepted" | "declined" | "missed", ended only),
//     caller, avatar, channelId }
//   { type: "self", muted, deafened, channel }
//   { type: "contacts", list: [{ userId, name, username, avatar, channelId, group, time, last, unread, mentions }], lastDm }
//     (answer to list_contacts; a group DM has no userId, its channelId is opened or called; time is the
//     newest message's ms, last { author, content, mine, time } that message, mentions the ping count)
//   { type: "last_dm", userId, name, channelId, guessed }   (you wrote a DM; guessed: most recent DM, not known)
//   { type: "sent", ok, to, error }
//   { type: "voice_state", channelId (empty: in no voice channel), channel, guild,
//     members: [{ userId, name, avatar, you, muted, deafened, streaming, speaking }] }   (for the overlay)
//   { type: "speaking", userId, speaking }
//   { type: "stream", live, viewers: [{ id, name, avatar }] }   (your own Go Live stream and who watches it;
//     sent on every change and after voice_state)
// shell → Discord:
//   { cmd: "accept_call" | "decline_call" | "call_back" | "join_voice" | "leave_voice" | "open_channel"
//     | "toggle_mute" | "toggle_deafen" | "voice_state", channelId?, guildId? }
//   { cmd: "list_contacts" } | { cmd: "open_dm" | "call_user", userId, channelId? } | { cmd: "send_dm", userId, content, channelId? }
//   | { cmd: "reply_last", content } | { cmd: "send_message", channelId, content }   (a notification's reply field)
//   | { cmd: "audio_sources" } → { type: "audio_sources", ok, list: [{ name, node }] }
//   | { cmd: "start_stream", resolution, fps, hint, audio ("none" | "system" | "apps"), nodes } | { cmd: "stop_stream" }
//   | { cmd: "stream_quality", resolution, fps, hint }   (onto the running stream)
//     (problems come back as { type: "stream_error", error })
Singleton {
    id: root

    readonly property string path: `${Quickshell.env("XDG_RUNTIME_DIR")}/qs-discord.sock`
    property var clients: []
    readonly property bool connected: clients.length > 0

    // For the launcher (d): DMs and friends, and who "d reply" goes to
    property var contacts: []
    property var lastDm: null

    // ── Voice overlay (voice/VoiceOverlay.qml) ───────────────

    // Your voice channel and who is in it; speaking: userId → true while their mic is open
    readonly property var noVoice: ({ channelId: "", channel: "", guild: "", members: [] })
    property var voice: noVoice
    property var speaking: ({})
    readonly property bool inVoice: connected && voice.channelId !== ""

    // Your own Go Live stream: whether it runs and who watches it ({ id, name, avatar }, by name)
    property bool streamLive: false
    property var streamViewers: []

    // ── Go Live from the shell (bar/StreamPanel.qml) ─────────

    // Apps playing sound right now: [{ name, node }] (node: venmic's description, handed back)
    property var audioSources: []
    property bool audioSourcesOk: true
    // How the last stream was set up; the panel starts from it
    readonly property var streamSettings: Object.assign({
        source: "screen:" + (Quickshell.screens[0]?.name ?? ""), resolution: "1080", fps: "60", hint: "motion",
        audio: "system", exclude: [], include: []
    }, Config.user.streamSettings ?? {})

    function setStreamSetting(key, value) {
        const next = Object.assign({}, streamSettings);
        next[key] = value;
        Config.set("streamSettings", next);
    }

    // The window picked in the panel for source "window" (a Hyprland address), not kept
    property string shareWindow: ""
    // What the running stream was started or last changed with (settings + window), so the
    // panel can tell an edit apart; null while not live
    property var liveSettings: null
    readonly property var currentShare: Object.assign({}, streamSettings, { window: streamSettings.source === "window" ? shareWindow : "" })
    readonly property bool streamEdited: streamLive && liveSettings !== null && JSON.stringify(liveSettings) !== JSON.stringify(currentShare)

    onStreamLiveChanged: {
        if (!streamLive)
            liveSettings = null;
        else if (liveSettings === null)
            liveSettings = currentShare;
    }

    // Apply the panel's edits to the running stream: quality goes onto it as it runs; a new
    // source or other sound needs a new stream (the web client cannot swap them), so it stops
    // and starts again
    function updateStream() {
        if (!streamEdited)
            return;
        const was = liveSettings, now = currentShare;
        const restart = ["source", "window", "audio", "exclude", "include"].some(k => JSON.stringify(was[k]) !== JSON.stringify(now[k]));
        liveSettings = now;
        if (restart) {
            stopStream();
            restartTimer.restart();
        } else {
            send({ cmd: "stream_quality", resolution: now.resolution, fps: now.fps, hint: now.hint });
        }
    }

    Timer {
        id: restartTimer
        interval: 1200
        onTriggered: root.startStream()
    }

    function listAudio() {
        send({ cmd: "audio_sources" });
    }

    // The screen or window is picked in the desktop portal after this; Vesktop's own picker
    // is answered by the plugin with these settings
    function startStream() {
        const st = streamSettings;
        liveSettings = currentShare;
        // facet-share-picker answers the portal with this; "" leaves the choice to its picker
        const target = st.source === "window" ? (shareWindow !== "" ? `window:${shareWindow}` : "") : st.source;
        Quickshell.execDetached(["sh", "-c", 'f="$XDG_RUNTIME_DIR/facet-share-target"; if [ -n "$1" ]; then printf %s "$1" > "$f"; else rm -f "$f"; fi', "share-target", target]);
        const names = st.audio === "system" ? st.exclude : st.audio === "apps" ? st.include : [];
        const nodes = audioSources.filter(a => names.includes(a.name)).map(a => a.node);
        send({ cmd: "start_stream", resolution: st.resolution, fps: st.fps, hint: st.hint, audio: st.audio, nodes });
    }

    function stopStream() {
        send({ cmd: "stop_stream" });
    }

    // The overlay is on screen (Config.voiceOverlayWhen); then joins, leaves and your mute
    // go there instead of, or as well as, a notification (Config.voiceOverlayFeed)
    readonly property bool overlayShown: inVoice && (Config.voiceOverlayWhen === "always"
        || (Config.voiceOverlayWhen === "hidden" && !Notifications.onScreen("vesktop"))
        || (Config.voiceOverlayWhen === "game" && Toggles.gameMode))
    readonly property bool feedsOverlay: overlayShown && Config.voiceOverlayFeed !== "notify"
    readonly property bool overlayOnly: overlayShown && Config.voiceOverlayFeed === "overlay"

    // A line for the overlay's feed: "in" (joined, went live), "out" (left), "self" (your mute)
    signal voiceLine(string text, string kind)

    function setVoice(event) {
        // Who went live since the last list, for the feed
        if (feedsOverlay && event.channelId === voice.channelId) {
            const before = new Set(voice.members.filter(m => m.streaming).map(m => m.userId));
            for (const m of event.members ?? [])
                if (m.streaming && !before.has(m.userId) && !m.you)
                    voiceLine(`● ${m.name} went live`, "in");
        }
        voice = { channelId: event.channelId ?? "", channel: event.channel ?? "", guild: event.guild ?? "", members: event.members ?? [] };
        const next = {};
        for (const m of voice.members)
            if (m.speaking)
                next[m.userId] = true;
        speaking = next;
    }

    // Viewers coming and going get a line like joins and leaves. The stream starting or ending
    // stays quiet: its viewers all arrive or go with it, that is not news.
    function setStream(event) {
        const live = event.live === true;
        const viewers = event.viewers ?? [];
        if (live && streamLive) {
            const before = new Set(streamViewers.map(v => v.id));
            const after = new Set(viewers.map(v => v.id));
            for (const v of viewers)
                if (!before.has(v.id))
                    viewerLine(v, true, viewers.length);
            for (const v of streamViewers)
                if (!after.has(v.id))
                    viewerLine(v, false, viewers.length);
        }
        streamLive = live;
        streamViewers = viewers;
    }

    // Same way as a join or leave in your channel: the overlay's feed while it shows, a
    // notification under dc.voice unless Config.voiceOverlayFeed keeps it to the overlay
    function viewerLine(viewer, watching, count) {
        const name = viewer.name || "someone";
        if (feedsOverlay)
            voiceLine(`${watching ? "◉" : "○"} ${name} ${watching ? "is watching your stream" : "stopped watching"}`, watching ? "in" : "out");
        if (overlayOnly)
            return;
        Notifications.push({
            app: "discord · voice",
            rule: "dc.voice",
            kind: "voice",
            title: `${name} ${watching ? "is watching your stream" : "stopped watching your stream"}`,
            body: `${count} watching`,
            image: viewer.avatar ?? ""
        });
    }

    function refreshContacts() {
        send({ cmd: "list_contacts" });
    }

    // Brings the Vesktop window to the front (Hyprland does the focusing, the plugin the
    // navigation); a Vesktop that is not running gets started
    function focusWindow() {
        Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.focus({ window = \"class:vesktop\" })' | grep -q ok || vesktop"]);
    }

    function send(command) {
        const line = `${JSON.stringify(command)}\n`;
        for (const client of clients) {
            client.write(line);
            client.flush();
        }
    }

    // A reply typed into a message's notification goes straight into that channel (a DM, a
    // group or a server channel); the plugin answers with a "sent" event like the launcher's DMs
    function reply(channelId, content) {
        send({ cmd: "send_message", channelId, content });
    }

    // A ringing call stopped: the card goes away and its history entry says how it ended.
    // A missed call also gets a short notice with "call back".
    function callEnded(event) {
        const caller = event.caller || "someone";
        Notifications.removeWhere(p => p.callChannel === event.channelId);
        const texts = {
            accepted: { title: `call with ${caller}`, body: "answered" },
            declined: { title: `declined call from ${caller}`, body: "you declined" },
            missed: { title: `missed call from ${caller}`, body: "hung up before you answered" }
        };
        const text = texts[event.reason] ?? texts.missed;
        Notifications.updateHistory(h => h.kind === "call" && h.callChannel === event.channelId && !h.callEnded,
            Object.assign({ callEnded: true, actions: [] }, text));
        if (event.reason === "accepted" || event.reason === "declined")
            return;
        Notifications.push({
            app: "discord · call",
            rule: "dc.call",
            kind: "mini",
            logged: false,
            timeout: 8000,
            glyph: "✕",
            title: `missed call · ${caller}`,
            body: "hung up before you answered",
            image: event.avatar ?? "",
            actions: [{ id: "call", label: "call back", style: "ok" }],
            onAction: () => {
                root.send({ cmd: "call_back", channelId: event.channelId });
                root.focusWindow();
            }
        });
    }

    // Who wrote where: a DM is just the author, a group DM names the group, a server
    // channel names server and channel; "@" marks a ping
    function messageTitle(event) {
        const ping = event.mentioned ? "@ " : "";
        if (event.kind === "group")
            return `${ping}${event.author} · group ${event.channel}`;
        if (event.kind === "server" || event.guild)
            return `${ping}${event.author} · ${event.guild} #${event.channel}`;
        return event.author;
    }

    function handle(event) {
        switch (event.type) {
        case "message":
            // You are in Discord already: the message is on screen (Config.discordMessagesWhen)
            if (!Notifications.messageShows(Config.discordMessagesWhen, "vesktop"))
                break;
            // With a channel the card can answer in place (Config.notificationInlineReply);
            // where there is no field (history, in-game pill, other looks) "reply" opens
            // the channel like "open"
            Notifications.push({
                app: "discord",
                rule: event.kind === "server" ? "dc.mention" : "dc.dm",
                title: root.messageTitle(event),
                body: event.content,
                image: event.avatar ?? "",
                replyChannel: event.channelId ?? "",
                replyTo: event.kind === "group" ? event.channel : event.kind === "server" ? `#${event.channel}` : event.author,
                actions: (Config.notificationInlineReply && event.channelId ? [{ id: "reply", label: "reply", style: "" }] : [])
                    .concat([{ id: "open", label: "open", style: "" }]),
                onAction: () => {
                    root.send({ cmd: "open_channel", channelId: event.channelId, guildId: event.guildId });
                    root.focusWindow();
                }
            });
            break;
        case "voice":
            // Your own channel: into the overlay while it shows (and as a notification, if
            // Config.voiceOverlayFeed says so)
            if (!event.watched && root.feedsOverlay)
                root.voiceLine(`${event.action === "join" ? "→" : "←"} ${event.user} ${event.action === "join" ? "joined" : "left"}`,
                    event.action === "join" ? "in" : "out");
            if (!event.watched && root.overlayOnly)
                break;
            // Your own channel: just the news. A watched channel: offer to join
            Notifications.push({
                app: event.watched ? "discord · watching" : "discord · voice",
                rule: "dc.voice",
                kind: "voice",
                title: `${event.user} ${event.action === "join" ? "joined" : "left"} ${event.channel}`,
                body: `${event.count} in the channel`,
                image: event.avatar ?? "",
                actions: event.watched && event.action === "join" ? [{ id: "join", label: "join", style: "" }] : [],
                onAction: () => root.send({ cmd: "join_voice", channelId: event.channelId })
            });
            break;
        case "event":
            // Stage/voice events can be joined directly, external ones only opened
            Notifications.push({
                app: "discord · event",
                rule: "dc.event",
                kind: "voice",
                title: `${event.name} started`,
                body: [event.guild, event.channel || event.location].filter(Boolean).join(" · "),
                actions: event.channelId ? [{ id: "join", label: "join", style: "ok" }] : [{ id: "open", label: "open", style: "" }],
                onAction: id => root.send(id === "join"
                    ? { cmd: "join_voice", channelId: event.channelId }
                    : { cmd: "open_channel", channelId: event.channelId, guildId: event.guildId })
            });
            break;
        case "call":
            if (event.state === "ringing")
                Notifications.push({
                    app: "discord · call",
                    rule: "dc.call",
                    kind: "call",
                    timeout: 0,
                    title: `${event.caller} is calling`,
                    body: "direct call · ringing",
                    image: event.avatar ?? "",
                    callChannel: event.channelId,
                    actions: [
                        { id: "accept", label: "accept", style: "ok" },
                        { id: "decline", label: "decline", style: "no" }
                    ],
                    onAction: id => root.send({ cmd: id === "accept" ? "accept_call" : "decline_call", channelId: event.channelId })
                });
            else
                root.callEnded(event);
            break;
        case "self":
            if (root.feedsOverlay)
                root.voiceLine(event.deafened ? "✕ you are deafened" : event.muted ? "✕ you muted yourself" : "✓ you unmuted yourself",
                    event.muted || event.deafened ? "self" : "in");
            if (root.overlayOnly)
                break;
            Notifications.push({
                app: "discord",
                rule: "dc.self",
                kind: "mini",
                timeout: 2500,
                glyph: event.muted || event.deafened ? "✕" : "✓",
                title: event.deafened ? "you are deafened" : event.muted ? "you muted yourself" : "you unmuted yourself",
                body: event.channel ? `in ${event.channel}` : "",
                actions: event.deafened ? [{ id: "undeafen", label: "undeafen", style: "" }]
                    : event.muted ? [{ id: "unmute", label: "unmute", style: "" }] : [],
                onAction: id => root.send({ cmd: id === "undeafen" ? "toggle_deafen" : "toggle_mute" })
            });
            break;
        case "contacts":
            contacts = event.list ?? [];
            lastDm = event.lastDm ?? lastDm;
            break;
        case "last_dm":
            lastDm = event;
            break;
        case "voice_state":
            root.setVoice(event);
            break;
        case "stream":
            root.setStream(event);
            break;
        case "audio_sources":
            audioSourcesOk = event.ok !== false;
            audioSources = event.list ?? [];
            break;
        case "stream_log":
            console.info(`discord stream: ${event.step}`);
            break;
        case "stream_error":
            console.warn(`discord stream: ${event.error}`);
            Notifications.push({
                app: "discord",
                rule: "dc.self",
                kind: "mini",
                logged: false,
                timeout: 6000,
                glyph: "✕",
                title: "stream did not start",
                body: event.error ?? ""
            });
            break;
        case "speaking": {
            const next = Object.assign({}, speaking);
            if (event.speaking)
                next[event.userId] = true;
            else
                delete next[event.userId];
            speaking = next;
            break;
        }
        case "sent":
            Notifications.push({
                app: "discord",
                rule: "dc.self",
                kind: "mini",
                logged: false,
                timeout: event.ok ? 2500 : 6000,
                glyph: event.ok ? "✓" : "✕",
                title: event.ok ? `sent to ${event.to}` : `not sent${event.to ? ` to ${event.to}` : ""}`,
                body: event.ok ? "" : event.error ?? ""
            });
            break;
        default:
            console.warn(`discord bridge: unknown event ${event.type}`);
        }
    }

    SocketServer {
        active: true
        path: root.path

        handler: Socket {
            id: client

            onConnectedChanged: {
                if (connected) {
                    root.clients = root.clients.concat([client]);
                    // A shell that started while you were in a call learns who is in it
                    root.send({ cmd: "voice_state" });
                } else {
                    root.clients = root.clients.filter(c => c !== client);
                    // Discord closed: no call any more
                    if (root.clients.length === 0) {
                        root.voice = root.noVoice;
                        root.speaking = {};
                        root.streamLive = false;
                        root.streamViewers = [];
                    }
                }
            }

            parser: SplitParser {
                onRead: line => {
                    try {
                        root.handle(JSON.parse(line));
                    } catch (e) {
                        console.warn(`discord bridge: ${e}`);
                    }
                }
            }
        }
    }
}
