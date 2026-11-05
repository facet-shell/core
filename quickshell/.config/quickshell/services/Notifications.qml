pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import Quickshell.Wayland
import qs.config

// Every notification: desktop ones over D-Bus (this shell is the notification daemon)
// and Discord/Steam events from the Vencord and Millennium bridges. Popups are shown by notifications/Popups.qml,
// everything also lands in `history` for the bell in the bar.
//
// Entry: { uid, app, title, body, image, glyph, kind ("normal" | "voice" | "call" | "alarm" | "mini"),
//   rule (which of Config.notifyRules decides, e.g. "dc.call"; none: the shell's own notices, always shown),
//   critical, timeout (ms, 0 = stays until handled), time, actions: [{ id, label, style }],
//   notification (D-Bus object or null), onAction(id), callChannel,
//   logged (false = popup only, e.g. a missed-call notice whose call is already in the history),
//   preview (true = a test from the settings: shows past the rules and the bell, not logged) }
Singleton {
    id: root

    property var popups: []
    property var history: []
    // Arrived while "silent" was on and not seen yet
    property int missed: 0
    property int nextUid: 1
    // Starts the Discord socket together with the notifications
    readonly property bool discordConnected: DiscordBridge.connected
    // Same for the Steam socket (Millennium plugin)
    readonly property bool steamConnected: SteamBridge.connected

    function toArray(list) {
        const out = [];
        for (let i = 0; i < (list?.length ?? 0); i++)
            out.push(list[i]);
        return out;
    }

    NotificationServer {
        keepOnReload: false
        actionsSupported: true
        imageSupported: true
        persistenceSupported: true
        bodyMarkupSupported: false

        onNotification: n => {
            // Vesktop's own desktop notifications would double the ones ShellBridge sends
            if (root.discordConnected && /vesktop|discord/i.test(`${n.appName} ${n.desktopEntry}`)) {
                n.dismiss();
                return;
            }
            // Same for Steam while its plugin forwards everything
            if (root.steamConnected && /^steam$/i.test(n.appName || n.desktopEntry)) {
                n.dismiss();
                return;
            }
            n.tracked = true;
            const critical = n.urgency === NotificationUrgency.Critical;
            root.push({
                app: (n.appName || "app").toLowerCase(),
                rule: "sys.apps",
                title: n.summary,
                body: n.body,
                image: n.image || n.appIcon || "",
                critical,
                timeout: critical ? 0 : n.expireTimeout > 0 ? n.expireTimeout : Config.notificationTimeout,
                actions: root.toArray(n.actions)
                    .filter(a => a.identifier !== "default")
                    .map(a => ({ id: a.identifier, label: a.text.toLowerCase(), style: "" })),
                notification: n,
                onAction: id => {
                    const action = root.toArray(n.actions).find(a => a.identifier === id);
                    if (action)
                        action.invoke();
                }
            });
        }
    }

    // Ringing calls and alarms (launcher t/a) get through silent and stay on screen
    function urgent(entry) {
        return entry.kind === "call" || entry.kind === "alarm";
    }

    // "always", "game" or "never" for a kind of notification
    function ruleFor(kind) {
        return kind ? (Config.notifyRules[kind] ?? "always") : "always";
    }

    // Whether the rule lets it on screen right now (game mode, the bell); for popups that
    // are not notifications, like the Spotify song popup
    function allows(kind, urgent) {
        const rule = ruleFor(kind);
        if (rule === "never")
            return false;
        if (rule === "game" && Toggles.gameMode && Config.gameModeSilent)
            return false;
        return !Toggles.silent || urgent === true;
    }

    // A message from an app that may be open (Config.discordMessagesWhen and steamMessagesWhen):
    // false when you are looking at it already
    function messageShows(when, appId) {
        const active = (ToplevelManager.activeToplevel?.appId ?? "").toLowerCase() === appId;
        return when === "always" || (when === "unfocused" ? !active : !active && !onScreen(appId));
    }

    // The app has a window on a workspace some screen shows right now (Discord on the second
    // screen counts, Discord on another workspace does not)
    function onScreen(appId) {
        const id = appId.toLowerCase();
        // Qt's JS engine has no flatMap
        const shown = [].concat(...Hyprland.monitors.values.map(m => [m.activeWorkspace?.id, m.specialWorkspace?.id]))
            .filter(w => w !== undefined && w !== 0);
        return Hyprland.toplevels.values.some(t => shown.includes(t.workspace?.id)
            && String(t.wayland?.appId ?? t.lastIpcObject?.class ?? "").toLowerCase() === id);
    }

    function push(entry) {
        const full = Object.assign({
            uid: nextUid++,
            time: new Date(),
            app: "app",
            title: "",
            body: "",
            image: "",
            kind: "normal",
            critical: false,
            timeout: Config.notificationTimeout,
            actions: [],
            notification: null,
            onAction: null,
            callChannel: "",
            logged: true,
            preview: false
        }, entry);
        if (!entry.glyph)
            full.glyph = (full.title || full.app).charAt(0).toUpperCase();

        // A preview (the settings' "Try it") shows no matter what the rules and the bell say
        // and stays out of the history
        if (full.preview) {
            full.logged = false;
            popups = [full].concat(popups).slice(0, Config.notificationsMax);
            return;
        }

        // Turned off under the rules: not even in the bell
        if (!full.critical && ruleFor(full.rule) === "never")
            return;

        if (full.logged)
            history = [full].concat(history).slice(0, 50);

        // "not in game" while playing, and the bell (silent) for everything but calls and
        // alarms, wait in the history; critical ones always show
        if (!full.critical && !allows(full.rule, root.urgent(full))) {
            missed += 1;
            return;
        }

        // At most three on screen; the oldest that is not a call or alarm goes first
        let list = [full].concat(popups);
        while (list.length > Config.notificationsMax) {
            let drop = -1;
            for (let i = list.length - 1; i >= 0; i--)
                if (!root.urgent(list[i])) {
                    drop = i;
                    break;
                }
            list.splice(drop < 0 ? list.length - 1 : drop, 1);
        }
        popups = list;
    }

    // expired: the timer ran out (the app hears "expired" instead of "dismissed")
    function dismiss(uid, expired) {
        const entry = popups.find(p => p.uid === uid);
        popups = popups.filter(p => p.uid !== uid);
        if (!entry?.notification)
            return;
        try {
            if (expired)
                entry.notification.expire();
            else
                entry.notification.dismiss();
        } catch (e) {
            // The app closed it already
        }
    }

    function invoke(uid, actionId) {
        const entry = popups.find(p => p.uid === uid) ?? history.find(h => h.uid === uid);
        if (entry?.onAction)
            entry.onAction(actionId);
        dismiss(uid, false);
        // An action is the answer to it: the row leaves the history too (a deleted
        // screenshot's card stayed, so "delete" looked like it did nothing)
        history = history.filter(h => h.uid !== uid);
    }

    function removeWhere(test) {
        popups = popups.filter(p => !test(p));
    }

    // Rewrites matching history entries, e.g. a ringing call that turned out to be missed
    function updateHistory(test, changes) {
        history = history.map(h => test(h) ? Object.assign({}, h, changes) : h);
    }

    function markSeen() {
        missed = 0;
    }

    function clearHistory() {
        history = [];
        missed = 0;
    }

    // "now", "5m", "2h"
    function ago(date) {
        const minutes = Math.floor((Date.now() - date.getTime()) / 60000);
        return minutes < 1 ? "now" : minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h`;
    }

    // ── Grouping by app (Config.notificationGroupByApp) ──────

    // Popups and history rows of one app fold into a stack; the key is the entry's app name.
    // Ringing calls and alarms keep a group of their own: they must not hide under a stack.
    function groupKey(entry) {
        return urgent(entry) ? `uid:${entry.uid}` : (entry.app || "app").toLowerCase();
    }

    // [{ key, entries: [newest, …] }] in the order of each group's first entry. The lists
    // are newest first, so the first of a group is its newest. With the switch off every
    // entry is a group of its own, so the order is the list's own.
    function groups(list) {
        const out = [];
        const byKey = {};
        for (const entry of list) {
            const key = Config.notificationGroupByApp ? groupKey(entry) : `uid:${entry.uid}`;
            let group = byKey[key];
            if (!group) {
                group = { key, entries: [] };
                byKey[key] = group;
                out.push(group);
            }
            group.entries.push(entry);
        }
        return out;
    }

    // uid → { index (0: the newest, in front), size, key } for every entry of the list
    function places(list) {
        const out = {};
        for (const group of groups(list))
            group.entries.forEach((entry, index) => {
                out[entry.uid] = { index, size: group.entries.length, key: group.key };
            });
        return out;
    }
}
