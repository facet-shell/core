pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Wayland
import qs.config

// State behind the control center toggles, and the game mode that switches itself on
// while a game runs (Config.gameModeAuto).
Singleton {
    id: root

    property bool wifi: true
    readonly property bool bluetoothAvailable: Bluetooth.defaultAdapter !== null
    readonly property bool bluetooth: Bluetooth.defaultAdapter?.enabled ?? false
    // Hides popups while true (calls, alarms and critical ones still show)
    property bool silent: false
    // Blocks idle lock and screen-off; the IdleInhibitor lives in the bar
    property bool stayAwake: false
    property bool gameMode: false

    // ── Game detection ───────────────────────────────────────

    // Steam starts games with the window class steam_app_<id> (Proton and native alike);
    // gamescope wraps them in its own window; Config.gameClasses adds the rest (the list in
    // the settings: Sober, GeForce NOW, ...)
    function isGame(appId, title) {
        const id = String(appId ?? "");
        return /^steam_app_\d+$/.test(id) || id === "gamescope"
            || Config.gameClasses.some(entry => matchesGame(String(entry).trim(), id, String(title ?? "")));
    }

    // A list entry: a window class, any case, where * matches anything; "title:" checks the
    // window title instead (GeForce NOW in a browser tab)
    function matchesGame(entry, appId, title) {
        if (entry === "")
            return false;
        const byTitle = entry.toLowerCase().startsWith("title:");
        const pattern = byTitle ? entry.slice(6).trim() : entry;
        const parts = pattern.split("*").map(part => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"));
        const regex = new RegExp("^" + parts.join(".*") + "$", "i");
        return regex.test(byTitle ? title : appId);
    }

    readonly property var games: ToplevelManager.toplevels.values.filter(t => root.isGame(t.appId, t.title))
    readonly property bool gameRunning: games.length > 0
    readonly property string gameTitle: games.length > 0 ? (games[0].title || games[0].appId) : ""

    // Set while a game turned game mode on, so its end turns it off again (and not one you
    // switched on by hand); what it changed comes back afterwards
    property bool autoGame: false
    property string profileBefore: ""

    // A short wait, so a launcher window that flashes past or a game restarting itself
    // does not flip everything twice
    onGameRunningChanged: gameSettle.restart()

    Timer {
        id: gameSettle
        interval: 2500
        onTriggered: {
            if (!Config.gameModeAuto)
                return;
            if (root.gameRunning && !root.autoGame && !root.gameMode)
                root.startGame();
            else if (!root.gameRunning && root.autoGame)
                root.endGame();
        }
    }

    function startGame() {
        autoGame = true;
        // What still shows while playing is up to the notification rules (Config.notifyRules),
        // so the bell stays as it was
        setGameMode(true);
        if (Config.goxlrGameProfile !== "" && GoXLR.available) {
            profileBefore = GoXLR.profile;
            GoXLR.loadProfile(Config.goxlrGameProfile);
        }
        // Nothing of the wallpaper shows behind a fullscreen game
        wallpapers("pause");
        Notifications.push({
            app: "game mode",
            rule: "sys.gamemode",
            kind: "mini",
            logged: false,
            timeout: 3000,
            glyph: "▶",
            title: "game mode on",
            body: gameTitle
        });
    }

    function endGame() {
        autoGame = false;
        setGameMode(false);
        if (profileBefore !== "") {
            GoXLR.loadProfile(profileBefore);
            profileBefore = "";
        }
        wallpapers("resume");
        Notifications.push({
            app: "game mode",
            rule: "sys.gamemode",
            kind: "mini",
            logged: false,
            timeout: 2500,
            glyph: "■",
            title: "game mode off",
            body: ""
        });
    }

    // frame-wallpaper pause|resume (wallpaper package); nothing happens without it
    function wallpapers(action) {
        Quickshell.execDetached(["sh", "-c", 'w="$HOME/.local/bin/frame-wallpaper"; [ -x "$w" ] && "$w" "$1"', "frame-game", action]);
    }

    // ── Toggles ──────────────────────────────────────────────

    function setWifi(on) {
        wifi = on;
        Quickshell.execDetached(["nmcli", "radio", "wifi", on ? "on" : "off"]);
    }

    function setBluetooth(on) {
        if (Bluetooth.defaultAdapter)
            Bluetooth.defaultAdapter.enabled = on;
    }

    // Animations and blur off, performance power profile; reload brings the config back
    function setGameMode(on) {
        gameMode = on;
        if (on)
            Quickshell.execDetached(["sh", "-c", "hyprctl eval 'hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false } } })'; powerprofilesctl set performance"]);
        else
            Quickshell.execDetached(["sh", "-c", "hyprctl reload; powerprofilesctl set balanced"]);
    }

    Process {
        running: true
        command: ["nmcli", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: root.wifi = this.text.trim() === "enabled"
        }
    }
}
