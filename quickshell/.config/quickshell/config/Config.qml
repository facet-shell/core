pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Personal settings. The values here are the defaults; the settings app (settings/, Super+,
// or "settings" in the control center) keeps your changes in ~/.config/frameshell/shell.json,
// which wins over them and survives updates. Editing that file by hand works too, the shell
// picks it up right away.
Singleton {
    id: root

    // ── Your changes ─────────────────────────────────────────

    readonly property string file: `${Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"}/frameshell/shell.json`
    // key → value, only what differs from the defaults below
    property var user: ({})

    function set(key, value) {
        const next = Object.assign({}, user);
        next[key] = value;
        user = next;
        store.setText(JSON.stringify(user, null, 1));
    }

    // Back to the default
    function reset(key) {
        const next = Object.assign({}, user);
        delete next[key];
        user = next;
        store.setText(JSON.stringify(user, null, 1));
    }

    function isSet(key) {
        return user[key] !== undefined;
    }

    FileView {
        id: store
        path: root.file
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                root.user = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
            } catch (e) {
                console.warn(`config: ${root.file} is not valid JSON, using the defaults (${e})`);
                root.user = {};
            }
        }
        onLoadFailed: root.user = {}
    }

    // The folder has to be there before the first change is written
    Process {
        command: ["mkdir", "-p", root.file.slice(0, root.file.lastIndexOf("/"))]
        running: true
    }

    // ── Settings ─────────────────────────────────────────────

    // City for the weather panel, e.g. "Berlin". Empty: wttr.in guesses from your IP.
    readonly property string weatherLocation: user.weatherLocation ?? ""
    // Minutes between weather updates
    readonly property int weatherInterval: user.weatherInterval ?? 15
    // Blur strength of the desktop snapshot behind the lockscreen, 0 to 1
    readonly property real lockBlur: user.lockBlur ?? 1.0
    // Lock after this many minutes without input, screens off after that many; 0: never
    readonly property int idleLockMinutes: user.idleLockMinutes ?? 0
    readonly property int idleScreenOffMinutes: user.idleScreenOffMinutes ?? 0

    // How long a notification stays when the app does not say (ms), and how many show at once
    readonly property int notificationTimeout: user.notificationTimeout ?? 5000
    readonly property int notificationsMax: user.notificationsMax ?? 3

    // The bar's update count also covers frameshell (the CLI and the modules, compared with
    // their GitHub repos). false: neither checked nor shown; packages still are.
    readonly property bool frameUpdates: user.frameUpdates ?? true

    // goxlr-utility HTTP API (fader levels and mutes)
    readonly property string goxlrApi: user.goxlrApi ?? "http://localhost:14564"
    // App mixer routes → PipeWire device description, as shown by `wpctl status`.
    // "GoXLR Music" also matches the Mini's "GoXLRMini Music"; rename the right side
    // if your devices are called differently.
    readonly property var goxlrOutputs: user.goxlrOutputs ?? ({
        system: "GoXLR System",
        game: "GoXLR Game",
        chat: "GoXLR Chat",
        music: "GoXLR Music"
    })
    readonly property var goxlrInputs: user.goxlrInputs ?? ({
        "chat mic": "GoXLR Chat Mic",
        sampler: "GoXLR Sampler"
    })

    // ── Launcher ─────────────────────────────────────────────

    // Port the Spicetify extension connects to (s mode). Change it here and as PORT in
    // spicetify/.config/spicetify/Extensions/frameshell.js, then run `frame update spicetify`.
    readonly property int spotifyPort: user.spotifyPort ?? 48931

    // Web search (?): engine without a shortcut, and the shortcuts. %s is the search text.
    readonly property string searchDefault: user.searchDefault ?? "ddg"
    readonly property var searchEngines: user.searchEngines ?? ({
        g: ["Google", "https://www.google.com/search?q=%s"],
        ddg: ["DuckDuckGo", "https://duckduckgo.com/?q=%s"],
        yt: ["YouTube", "https://www.youtube.com/results?search_query=%s"],
        gh: ["GitHub", "https://github.com/search?q=%s"],
        aw: ["Arch Wiki", "https://wiki.archlinux.org/index.php?search=%s"],
        aur: ["AUR", "https://aur.archlinux.org/packages?K=%s"],
        w: ["Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s"],
        r: ["Reddit", "https://www.reddit.com/search/?q=%s"]
    })

    // Claude (c): there when the claude CLI is installed; false hides it. The model is
    // passed as --model (haiku answers fastest); empty uses your CLI default.
    readonly property bool claudeEnabled: user.claudeEnabled ?? true
    readonly property string claudeModel: user.claudeModel ?? "haiku"

    // File search (/): folder to search in; empty is your home folder
    readonly property string fileSearchRoot: user.fileSearchRoot ?? ""

    // Timers and alarms (t, a): how long snooze waits, in minutes
    readonly property int snoozeMinutes: user.snoozeMinutes ?? 10

    // ── Game mode ────────────────────────────────────────────

    // On by itself while a game runs (Steam games: window class steam_app_<id>; gamescope;
    // the classes below), off again when the last one closes. The toggle in the control
    // center still works by hand.
    readonly property bool gameModeAuto: user.gameModeAuto ?? true
    // Other games, by window class as `hyprctl clients` shows it (exact names, no patterns)
    readonly property var gameClasses: user.gameClasses ?? []
    // Popups stay quiet while playing (calls and alarms still get through)
    readonly property bool gameModeSilent: user.gameModeSilent ?? true
    // GoXLR profile to load while playing, the one before comes back after; empty: none
    readonly property string goxlrGameProfile: user.goxlrGameProfile ?? ""

    // ── Keyboard (AULA F75, Super+K) ─────────────────────────

    // false: the keyboard app only shows what it would send (frame-keyboard dry run).
    // Set it to true once frame-keyboard works on your board (docs/keyboard.md); the switch
    // in the app changes it until the shell restarts. true also lights the Super keys while
    // the hotkey overlay is open, and `frame theme set` puts the theme colors on the keys.
    readonly property bool keyboardLive: user.keyboardLive ?? true
}
