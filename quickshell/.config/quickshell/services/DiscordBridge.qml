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
// shell → Discord:
//   { cmd: "accept_call" | "decline_call" | "call_back" | "join_voice" | "open_channel" | "toggle_mute" | "toggle_deafen",
//     channelId?, guildId? }
//   { cmd: "list_contacts" } | { cmd: "open_dm" | "call_user", userId, channelId? } | { cmd: "send_dm", userId, content, channelId? }
//   | { cmd: "reply_last", content }
Singleton {
    id: root

    readonly property string path: `${Quickshell.env("XDG_RUNTIME_DIR")}/qs-discord.sock`
    property var clients: []
    readonly property bool connected: clients.length > 0

    // For the launcher (d): DMs and friends, and who "d reply" goes to
    property var contacts: []
    property var lastDm: null

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
            Notifications.push({
                app: "discord",
                rule: event.kind === "server" ? "dc.mention" : "dc.dm",
                title: root.messageTitle(event),
                body: event.content,
                image: event.avatar ?? "",
                actions: [{ id: "open", label: "open", style: "" }],
                onAction: () => {
                    root.send({ cmd: "open_channel", channelId: event.channelId, guildId: event.guildId });
                    root.focusWindow();
                }
            });
            break;
        case "voice":
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
                if (connected)
                    root.clients = root.clients.concat([client]);
                else
                    root.clients = root.clients.filter(c => c !== client);
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
