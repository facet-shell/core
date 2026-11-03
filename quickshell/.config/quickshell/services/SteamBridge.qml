pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Unix socket the Millennium plugin (steam/.local/share/millennium/plugins/frameshell) connects to. Steam's own
// toasts are switched off while the plugin is connected; it sends them here instead.
// One JSON object per line in both directions.
//
// Steam → shell:
//   { type: "hello", version, suppressing }   (on connect; suppressing: Steam's own toasts are off)
//   { type: "message", from, steamId, avatar, text, chat, groupId, chatId }
//     (chat: group chat name, empty for a direct message; groupId/chatId only in group chats)
//   { type: "friend", state: "online" | "ingame", name, steamId, avatar, game }
//   { type: "invite", kind: "game", from, steamId, avatar, text, url }   (Steam's invite text; url: the steam:// link that joins)
//   { type: "invite", kind: "friend", from, steamId, avatar }            (friend request)
//   { type: "achievement", game, appId, name, description, icon }
//   { type: "download", state: "done", game, appId }
// Everything else (gifts, wishlist sales, achievement progress, …) keeps Steam's own toast.
// shell → Steam:
//   { cmd: "open_chat", steamId } | { cmd: "open_group", groupId, chatId } | { cmd: "accept_invite", url }
//   { cmd: "play", appId } | { cmd: "open_downloads" } | { cmd: "show_friends" } | { cmd: "show" }
Singleton {
    id: root

    readonly property string path: `${Quickshell.env("XDG_RUNTIME_DIR")}/qs-steam.sock`
    property var clients: []
    readonly property bool connected: clients.length > 0
    // Steam turned its own toasts off for us (from "hello")
    property bool suppressing: false

    // Brings Steam to the front (Hyprland does the focusing, the plugin the navigation)
    function focusWindow() {
        Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.focus({ window = \"class:steam\" })' | grep -q ok || steam"]);
    }

    function send(command) {
        const line = `${JSON.stringify(command)}\n`;
        for (const client of clients) {
            client.write(line);
            client.flush();
        }
    }

    // Sends a command and brings Steam up to show its result
    function open(command) {
        send(command);
        focusWindow();
    }

    function handle(event) {
        switch (event.type) {
        case "hello":
            suppressing = event.suppressing === true;
            break;
        case "message":
            // You are in Steam's chat already (Config.steamMessagesWhen)
            if (!Notifications.messageShows(Config.steamMessagesWhen, "steam"))
                break;
            Notifications.push({
                app: "steam",
                rule: "st.message",
                title: event.chat ? `${event.from} · ${event.chat}` : event.from,
                body: event.text ?? "",
                image: event.avatar ?? "",
                actions: [{ id: "open", label: "open", style: "" }],
                onAction: () => root.open(event.groupId
                    ? { cmd: "open_group", groupId: event.groupId, chatId: event.chatId }
                    : { cmd: "open_chat", steamId: event.steamId })
            });
            break;
        case "friend":
            Notifications.push({
                app: "steam · friends",
                rule: "st.friends",
                kind: "mini",
                timeout: 4000,
                glyph: event.state === "ingame" ? "▶" : "●",
                title: event.state === "ingame" ? `${event.name} is playing ${event.game || "a game"}` : `${event.name} is online`,
                body: "",
                image: event.avatar ?? "",
                actions: [{ id: "chat", label: "chat", style: "" }],
                onAction: () => root.open({ cmd: "open_chat", steamId: event.steamId })
            });
            break;
        case "invite":
            if (event.kind === "game")
                Notifications.push({
                    app: "steam · invite",
                    rule: "st.invite",
                    timeout: 0,
                    title: `${event.from} invites you`,
                    body: event.text || "to a game",
                    image: event.avatar ?? "",
                    actions: [
                        { id: "accept", label: "join", style: "ok" },
                        { id: "chat", label: "chat", style: "" }
                    ],
                    onAction: id => root.open(id === "accept"
                        ? { cmd: "accept_invite", url: event.url }
                        : { cmd: "open_chat", steamId: event.steamId })
                });
            else
                Notifications.push({
                    app: "steam · friends",
                    rule: "st.request",
                    title: `friend request from ${event.from}`,
                    body: "",
                    image: event.avatar ?? "",
                    actions: [{ id: "show", label: "show", style: "" }],
                    onAction: () => root.open({ cmd: "show_friends" })
                });
            break;
        case "achievement":
            Notifications.push({
                app: event.game ? `steam · ${event.game}` : "steam",
                rule: "st.achievement",
                glyph: "★",
                title: `achievement · ${event.name}`,
                body: event.description ?? "",
                image: event.icon ?? ""
            });
            break;
        case "download":
            Notifications.push({
                app: "steam · downloads",
                rule: "st.download",
                kind: "mini",
                timeout: 6000,
                glyph: "✓",
                title: `${event.game} is ready`,
                body: "",
                actions: [
                    { id: "play", label: "play", style: "ok" },
                    { id: "downloads", label: "downloads", style: "" }
                ],
                onAction: id => root.open(id === "play" ? { cmd: "play", appId: event.appId } : { cmd: "open_downloads" })
            });
            break;
        default:
            console.warn(`steam bridge: unknown event ${event.type}`);
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
                        console.warn(`steam bridge: ${e}`);
                    }
                }
            }
        }
    }
}
