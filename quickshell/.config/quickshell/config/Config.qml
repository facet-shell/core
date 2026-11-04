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

    // ── Notifications ────────────────────────────────────────

    // What shows when, per kind: "always" (through game mode too), "game" (not while game mode
    // is on: it waits in the bell) or "never". Critical ones always show; the bell (silent)
    // still holds back everything but calls and alarms. shell.json keeps only what you changed.
    readonly property var notifyRuleDefaults: ({
        "sys.apps": "game",
        "sys.gamemode": "always",
        "dc.call": "always",
        "dc.dm": "always",
        "dc.mention": "always",
        "dc.voice": "game",
        "dc.event": "game",
        "dc.self": "always",
        "st.invite": "always",
        "st.request": "always",
        "st.message": "always",
        "st.friends": "game",
        "st.achievement": "game",
        "st.download": "game",
        "sp.song": "game"
    })
    readonly property var notifyRules: Object.assign({}, notifyRuleDefaults, user.notifyRules ?? {})

    function setRule(kind, value) {
        const next = Object.assign({}, user.notifyRules ?? {});
        if (value === notifyRuleDefaults[kind])
            delete next[kind];
        else
            next[kind] = value;
        if (Object.keys(next).length === 0)
            reset("notifyRules");
        else
            set("notifyRules", next);
    }

    // Messages from Discord or Steam while the app is open: "always" (even while you look at
    // it), "unfocused" (not while it is the focused window) or "hidden" (only while it is on
    // no screen, so not with Discord on the second screen either)
    readonly property string discordMessagesWhen: user.discordMessagesWhen ?? "hidden"
    readonly property string steamMessagesWhen: user.steamMessagesWhen ?? "hidden"

    // Where the popups sit: top-left, top, top-right, bottom-left, bottom, bottom-right.
    // The icon goes to the side they sit on; in the middle there is none and the text is centered.
    readonly property string notificationPosition: user.notificationPosition ?? "top-right"
    // card (frame, picture, buttons, time left), line (one line) or minimal (who and what)
    readonly property string notificationStyle: user.notificationStyle ?? "card"
    readonly property int notificationWidth: user.notificationWidth ?? 460

    // The Spotify popup: same positions; wide (cover beside the song), tall (big cover on
    // top) or strip (one thin line); size as a factor; seconds it stays
    readonly property string spotifyPosition: user.spotifyPosition ?? "top-left"
    readonly property string spotifyFormat: user.spotifyFormat ?? "wide"
    readonly property real spotifySize: user.spotifySize ?? 1
    readonly property int spotifySeconds: user.spotifySeconds ?? 6

    // The Discord voice overlay while you are in a voice channel: when it shows ("always",
    // "hidden": Discord on no screen, "game": while game mode is on, "never"); list, compact
    // (faces, names while talking) or talking (only who talks, and you); where joins, leaves
    // and your mute go ("overlay", "notify" or "both"); size as a factor; whether the quiet
    // ones are dimmed. No title, frame or background, just faces and names with a thin dark
    // outline so they read over any game. voiceOverlayPos keeps the spot per screen,
    // { "DP-1": [x, y] }, set by moving it (Super+Shift+V); without one: left, under the bar.
    readonly property string voiceOverlayWhen: user.voiceOverlayWhen ?? "hidden"
    readonly property string voiceOverlayLook: user.voiceOverlayLook ?? "list"
    readonly property string voiceOverlayFeed: user.voiceOverlayFeed ?? "overlay"
    readonly property real voiceOverlaySize: user.voiceOverlaySize ?? 1
    readonly property bool voiceOverlayDim: user.voiceOverlayDim ?? true
    readonly property var voiceOverlayPos: user.voiceOverlayPos ?? ({})

    // "left", "right" or "center" of a position, and whether it is at the top
    function side(position) {
        return position.endsWith("left") ? "left" : position.endsWith("right") ? "right" : "center";
    }

    function atTop(position) {
        return !position.startsWith("bottom");
    }

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
    // spicetify/.config/spicetify/Extensions/frameshell.js, then run `facet update spicetify`.
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
    // Other games and game apps (Sober, GeForce NOW, ...): window classes as `hyprctl clients`
    // shows them, any case; * matches anything ("*geforce*"), and "title:" matches the
    // window title instead ("title:*GeForce NOW*" also catches it in a browser tab)
    readonly property var gameClasses: user.gameClasses ?? []
    // While playing, the notification rules hold back what is set to "not in game";
    // false: everything shows as if no game ran
    readonly property bool gameModeSilent: user.gameModeSilent ?? true
    // GoXLR profile to load while playing, the one before comes back after; empty: none
    readonly property string goxlrGameProfile: user.goxlrGameProfile ?? ""
    // Over a fullscreen window (a game's menu, the mouse free) the bar comes down while the
    // mouse rests on the top edge of the screen, and goes up again once it leaves the bar
    readonly property bool barOverFullscreen: user.barOverFullscreen ?? true

    // ── Keyboard (AULA F75, Super+K) ─────────────────────────

    // false: the keyboard app only shows what it would send (frame-keyboard dry run).
    // Set it to true once frame-keyboard works on your board (docs/keyboard.md); the switch
    // in the app changes it until the shell restarts. true also lights the Super keys while
    // the hotkey overlay is open, and `facet theme set` puts the theme colors on the keys.
    readonly property bool keyboardLive: user.keyboardLive ?? true
}
