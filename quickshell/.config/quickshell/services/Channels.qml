pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.config

// Puts apps on the virtual channels (`facet audio channels on`) when they start playing:
// Config.audioRules ([pattern, channel], first match wins; "@game" is the game that runs, as
// game mode sees it) and what you chose in the app mixer, which always wins over the rules
// (kept in ~/.local/state/frameshell/audio-routes.json). Only while the virtual channels are
// the channels in use (Audio.virtualActive) and Config.audioRulesOn; never with a GoXLR or
// without channels, so nothing moves there that did not move before.
//
// Each stream is looked at once, a moment after it appears (it needs its first link), and
// only moved when it sits on the System channel (the default output) or nowhere: a stream
// WirePlumber put on another channel by itself stays there. Starting a game looks at every
// stream again, so a game that opened its sound before its window still lands on Game.
Singleton {
    id: root

    readonly property bool active: Audio.virtualActive && Config.audioRulesOn
    readonly property var streams: active ? Audio.playback : []

    // node id → tries, for every stream already looked at (or waiting for its link)
    property var seen: ({})
    property var waiting: []
    // Process ids of the game windows (Hyprland's view, refreshed before each look)
    property var gamePids: []

    // Called by Core so the singleton runs from the start
    function start() {
        scan();
    }

    onStreamsChanged: scan()
    onActiveChanged: {
        seen = {};
        waiting = [];
        scan();
    }

    // The app as the memory keys it: its program, else its name
    function appKey(node) {
        const props = node.properties ?? {};
        return String(props["application.process.binary"] || props["application.name"] || node.name || "");
    }

    // "teamspeak*" → /^teamspeak.*$/i
    function patternMatches(pattern, text) {
        if (text === "")
            return false;
        const parts = String(pattern).trim().split("*").map(p => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&"));
        return new RegExp("^" + parts.join(".*") + "$", "i").test(text);
    }

    // The game's own stream: its window's process, a Wine or Proton program, or a name that is
    // the game's window class or title. Only while a game runs.
    function isGameStream(node) {
        if (!Toggles.gameRunning)
            return false;
        const props = node.properties ?? {};
        const pid = Number(props["application.process.id"] ?? 0);
        if (pid > 0 && gamePids.includes(pid))
            return true;
        const binary = String(props["application.process.binary"] ?? "");
        const name = String(props["application.name"] ?? "");
        if (/^(wine|wine64|wine-preloader|wine64-preloader|proton)$|\.exe$/i.test(binary) || /\.exe$/i.test(name))
            return true;
        const lower = name.toLowerCase();
        return lower !== "" && Toggles.games.some(t => String(t.appId ?? "").toLowerCase() === lower || String(t.title ?? "").toLowerCase() === lower);
    }

    function matches(pattern, node) {
        const p = String(pattern ?? "").trim();
        if (p === "")
            return false;
        if (p.toLowerCase() === "@game")
            return isGameStream(node);
        const props = node.properties ?? {};
        return patternMatches(p, String(props["application.name"] ?? ""))
            || patternMatches(p, String(props["application.process.binary"] ?? ""))
            || patternMatches(p, String(node.name ?? ""));
    }

    // The channel the rules give a stream, "" for none (or a channel that is not set up)
    function ruleFor(node) {
        for (const rule of Config.audioRules ?? []) {
            if (!Array.isArray(rule) || rule.length < 2)
                continue;
            const channel = String(rule[1]);
            if (Audio.outputRoutes.includes(channel) && matches(rule[0], node))
                return channel;
        }
        return "";
    }

    // The channel the mixer remembers for this app, "" for none
    function chosenFor(node) {
        const route = String(memory.apps[appKey(node)] ?? "");
        return Audio.outputRoutes.includes(route) ? route : "";
    }

    // The channel that is the default output (System), "" when the default is something else
    readonly property string defaultRoute: Audio.virtualChannels.find(c => c.node === Audio.defaultSink)?.key ?? ""

    function scan() {
        if (!active)
            return;
        const next = Object.assign({}, seen);
        const live = {};
        let added = false;
        for (const n of streams) {
            live[n.id] = true;
            if (next[n.id] === undefined) {
                next[n.id] = 0;
                waiting = waiting.concat([n]);
                added = true;
            }
        }
        // Gone streams leave the list, so it does not grow all day
        for (const id of Object.keys(next))
            if (!live[id])
                delete next[id];
        seen = next;
        if (added) {
            Hyprland.refreshToplevels();
            look.restart();
        }
    }

    function check(node) {
        if (!Audio.playback.includes(node))
            return true;
        const device = Audio.deviceOf(node);
        // No link yet: look again, a few times
        if (!device)
            return (seen[node.id] ?? 0) >= 6;
        const chosen = chosenFor(node);
        const target = chosen !== "" ? chosen : ruleFor(node);
        const current = Audio.routeOf(node);
        if (target === "" || target === current)
            return true;
        // A rule only takes apps from the default channel (or from no channel); a choice in
        // the mixer also brings an app back that something else moved
        if (chosen !== "" || current === "" || current === defaultRoute)
            Audio.moveTo(node, Audio.routeDevice(target, false));
        return true;
    }

    Timer {
        id: look
        interval: 700
        onTriggered: {
            root.gamePids = Hyprland.toplevels.values
                .map(t => t.lastIpcObject ?? {})
                .filter(o => Toggles.isGame(o.class, o.title))
                .map(o => Number(o.pid ?? 0))
                .filter(p => p > 0);
            const again = [];
            const tries = Object.assign({}, root.seen);
            for (const n of root.waiting) {
                if (!root.check(n)) {
                    tries[n.id] = (tries[n.id] ?? 0) + 1;
                    again.push(n);
                }
            }
            root.seen = tries;
            root.waiting = again;
            if (again.length > 0)
                look.restart();
        }
    }

    // A game started: every stream is looked at again (games often open their sound first)
    Connections {
        target: Toggles

        function onGameRunningChanged() {
            if (Toggles.gameRunning && root.active)
                gameLook.restart();
        }
    }

    Timer {
        id: gameLook
        interval: 3000
        onTriggered: {
            root.seen = {};
            root.waiting = [];
            root.scan();
        }
    }

    // ── What you chose in the mixer ──────────────────────────

    Connections {
        target: Audio

        function onRouteChosen(node, route) {
            if (!Audio.virtualActive)
                return;
            const key = root.appKey(node);
            if (key === "")
                return;
            const next = Object.assign({}, memory.apps);
            next[key] = route;
            memory.apps = next;
            memoryView.writeAdapter();
        }
    }

    // Forget every choice (settings: "forget"), the rules decide again
    function forgetChoices() {
        memory.apps = {};
        memoryView.writeAdapter();
    }

    readonly property var choices: memory.apps

    FileView {
        id: memoryView
        path: `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/frameshell/audio-routes.json`
        printErrors: false
        JsonAdapter {
            id: memory
            property var apps: ({})
        }
    }
}
