import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.components
import qs.config
import qs.services

// The settings app's content: sections on the left, their settings on the right.
// Shell settings go through Config (kept in ~/.config/frameshell/shell.json, "default" puts
// one back); theme and layout through the frame command; installing, boot and login, which
// need sudo, open in a terminal of their own.
FocusScope {
    id: root

    signal closeRequested()
    signal wallpapersRequested()
    signal keyboardRequested()

    property string section: "look"
    readonly property var sections: [
        ["look", "look", "theme, layout, wallpaper"],
        ["shell", "shell", "lock, weather"],
        ["notifications", "notifications", "what shows when, look, Spotify, voice"],
        ["launcher", "launcher", "search, Claude, files, timers"],
        ["games", "games", "game mode, which apps are games"],
        ["sound", "sound", "output and input"],
        ["apps", "apps", "modules and their apps"],
        ["system", "system", "updates, boot, login, about"]
    ]

    readonly property string home: Quickshell.env("HOME")
    readonly property string frameBin: `${home}/.local/bin/frame`
    readonly property string stateDir: `${Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"}/frameshell`
    readonly property string modulesDir: `${Quickshell.env("XDG_DATA_HOME") || home + "/.local/share"}/frameshell/modules`

    // [{ id, name, colors }] from the frame command's themes
    property var themes: []
    property var installed: []
    property string about: ""
    property string status: ""

    readonly property var modules: [
        ["shell", "the desktop: bar, launcher, lockscreen, Hyprland, login and boot screens"],
        ["terminal", "Ghostty, fish, Starship, fastfetch"],
        ["spotify", "Spotify themed, search and controls in the launcher"],
        ["discord", "Vesktop themed, calls and DMs in the shell"],
        ["steam", "Steam themed through Millennium, its popups in the shell"],
        ["keyboard", "keyboard lighting and keys (AULA F75)"],
        ["zed", "Zed themed"],
        ["zen", "Zen themed, with the start page"],
        ["dolphin", "Dolphin and Qt apps themed"]
    ]

    function refresh() {
        themesProc.running = true;
        modulesProc.running = true;
        aboutProc.running = true;
        themeState.reload();
        layoutState.reload();
    }

    // frame commands that need sudo or show output: their own Ghostty, open until Enter
    function inTerminal(title, args) {
        Quickshell.execDetached(["ghostty", "--gtk-single-instance=false", `--title=${title}`, "-e", "sh", "-c",
            '"$@"; printf "\\nDone. Enter closes this window."; read _', "frame-settings"].concat(args));
    }

    // frame commands without questions: in the background, the last line as the status
    function runFrame(args, label) {
        if (frameProc.running)
            return;
        status = `${label}…`;
        frameProc.label = label;
        frameProc.command = [frameBin].concat(args);
        frameProc.running = true;
    }

    Keys.onEscapePressed: root.closeRequested()

    // ── Files and commands ───────────────────────────────────

    Process {
        id: themesProc
        command: ["sh", "-c", 'd="${XDG_DATA_HOME:-$HOME/.local/share}/frameshell/cli/themes"; jq -c -n \'[inputs | { id: (input_filename | split("/") | last | rtrimstr(".json")), name, colors }]\' "$d"/*.json']
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.themes = JSON.parse(this.text);
                } catch (e) {
                    root.themes = [];
                }
            }
        }
    }

    Process {
        id: modulesProc
        command: ["sh", "-c", 'for d in "$1"/*/; do [ -d "$d.git" ] && basename "$d"; done', "frame-settings", root.modulesDir]
        stdout: StdioCollector {
            onStreamFinished: root.installed = this.text.split("\n").filter(l => l !== "")
        }
    }

    Process {
        id: aboutProc
        command: ["sh", "-c", 'hyprctl version 2>/dev/null | head -1; qs --version 2>/dev/null | head -1; printf "kernel %s\\n" "$(uname -r)"; '
            + 'for d in "$1"/*/; do [ -d "$d.git" ] && printf "%s %s\\n" "$(basename "$d")" "$(git -C "$d" log -1 --format="%h · %cr" 2>/dev/null)"; done', "frame-settings", root.modulesDir]
        stdout: StdioCollector {
            onStreamFinished: root.about = this.text.trim()
        }
    }

    Process {
        id: frameProc

        property string label: ""

        stderr: StdioCollector {
            id: frameErr
        }
        onExited: code => {
            root.status = code === 0 ? `${label}: done` : `${label}: ${frameErr.text.trim().split("\n").pop() || "failed"}`;
            themeState.reload();
            layoutState.reload();
        }
    }

    FileView {
        id: themeState
        path: `${root.stateDir}/theme`
        printErrors: false
    }

    FileView {
        id: layoutState
        path: `${root.stateDir}/layout`
        printErrors: false
    }

    readonly property string currentTheme: themeState.text().trim() || "periwinkle"
    readonly property string currentLayout: layoutState.text().trim() === "canvas" ? "canvas" : "tiling"

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 14
        elide: Text.ElideRight
    }

    component Action: TuiButton {
        id: act

        property string text: ""
        property color tint: Theme.secondary

        implicitWidth: actText.implicitWidth + 24
        implicitHeight: 30
        accent: tint

        Text {
            id: actText
            anchors.centerIn: parent
            text: act.text
            color: !act.available ? Theme.muted : act.active ? Theme.text : act.tint
            font.family: Theme.font
            font.pixelSize: 13
        }
    }

    // One setting: its name and what it does on the left, the control on the right, and
    // "default" while it differs from the shell's own value
    component Setting: RowLayout {
        id: row

        property string key: ""
        property string title: ""
        property string hint: ""
        default property alias control: slot.data

        Layout.fillWidth: true
        spacing: 16

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: row.title
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 14
            }
            Text {
                Layout.fillWidth: true
                visible: row.hint !== ""
                text: row.hint
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            id: slot
            spacing: 8
        }

        Text {
            Layout.preferredWidth: 60
            text: row.key !== "" && Config.isSet(row.key) ? "default" : ""
            color: resetArea.containsMouse ? Theme.text : Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
            horizontalAlignment: Text.AlignRight

            MouseArea {
                id: resetArea
                anchors.fill: parent
                enabled: parent.text !== ""
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Config.reset(row.key)
            }
        }
    }

    // A number with − and +; factor turns the stored value into the shown one (ms → s)
    component NumberSetting: Setting {
        id: num

        property real min: 0
        property real max: 100
        property real step: 1
        property real factor: 1
        property string unit: ""
        property string zero: ""
        readonly property real shown: Number(Config[key] ?? 0) / factor

        function change(d) {
            const v = Math.max(min, Math.min(max, Math.round((shown + d) / step) * step));
            Config.set(key, Number((v * factor).toFixed(3)));
        }

        Action {
            text: "−"
            implicitWidth: 30
            onClicked: num.change(-num.step)
        }
        Text {
            Layout.preferredWidth: 90
            horizontalAlignment: Text.AlignHCenter
            text: num.shown === 0 && num.zero !== "" ? num.zero : `${Number(num.shown.toFixed(2))}${num.unit}`
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 14
        }
        Action {
            text: "+"
            implicitWidth: 30
            onClicked: num.change(num.step)
        }
    }

    component BoolSetting: Setting {
        id: flag

        readonly property bool on: Config[key] === true

        Action {
            text: "on"
            active: flag.on
            tint: Theme.ok
            onClicked: Config.set(flag.key, true)
        }
        Action {
            text: "off"
            active: !flag.on
            tint: Theme.danger
            onClicked: Config.set(flag.key, false)
        }
    }

    // One of a few values; options: [[value, label], …]
    component ChoiceSetting: Setting {
        id: choice

        property var options: []

        Repeater {
            model: choice.options
            delegate: Action {
                required property var modelData
                text: modelData[1]
                active: Config[choice.key] === modelData[0]
                onClicked: Config.set(choice.key, modelData[0])
            }
        }
    }

    // A notification rule (Config.notifyRules): always, not while playing, never
    component RuleSetting: Setting {
        id: ruleRow

        property string kind: ""
        readonly property string value: Config.notifyRules[kind] ?? "always"

        Action {
            text: "always"
            active: ruleRow.value === "always"
            tint: Theme.ok
            onClicked: Config.setRule(ruleRow.kind, "always")
        }
        Action {
            text: "not in game"
            active: ruleRow.value === "game"
            tint: Theme.warn
            onClicked: Config.setRule(ruleRow.kind, "game")
        }
        Action {
            text: "never"
            active: ruleRow.value === "never"
            tint: Theme.danger
            onClicked: Config.setRule(ruleRow.kind, "never")
        }
    }

    // Where a popup sits: six corners and edges as arrows, like the screen they stand for
    component PositionSetting: Setting {
        id: place

        readonly property var spots: [["top-left", "↖"], ["top", "↑"], ["top-right", "↗"], ["bottom-left", "↙"], ["bottom", "↓"], ["bottom-right", "↘"]]

        hint: String(Config[key] ?? "").replace("-", " ")

        GridLayout {
            columns: 3
            columnSpacing: 4
            rowSpacing: 4

            Repeater {
                model: place.spots
                delegate: Action {
                    required property var modelData
                    implicitWidth: 34
                    implicitHeight: 26
                    text: modelData[1]
                    active: Config[place.key] === modelData[0]
                    onClicked: Config.set(place.key, modelData[0])
                }
            }
        }
    }

    // Text, saved when Enter is pressed or the field loses focus; list: comma separated
    component TextSetting: Setting {
        id: txt

        property string placeholder: ""
        property bool list: false
        readonly property string current: list ? (Config[key] ?? []).join(", ") : String(Config[key] ?? "")

        function commit() {
            const v = field.text.trim();
            if (v === current)
                return;
            Config.set(key, list ? v.split(",").map(s => s.trim()).filter(s => s !== "") : v);
        }

        Rectangle {
            Layout.preferredWidth: 280
            Layout.preferredHeight: 30
            color: "transparent"
            border.width: 1
            border.color: field.activeFocus ? Theme.primary : Theme.border

            TextInput {
                id: field
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: txt.current
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 14
                clip: true
                selectByMouse: true
                onEditingFinished: txt.commit()
                onAccepted: txt.commit()

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.text === "" && !field.activeFocus
                    text: txt.placeholder
                    color: Theme.muted
                    font: field.font
                }
            }
        }
    }

    // Apps that count as games (Config.gameClasses): what is on the list (✕ takes it off), and
    // three ways to add one: typed in (a class, *patterns*, or title:…), picked from the
    // windows open right now, or one of the suggestions
    component GameListSetting: ColumnLayout {
        id: games

        readonly property var list: Config.gameClasses
        property bool picking: false

        // Already on it, any case
        function has(entry) {
            return list.some(x => String(x).toLowerCase() === String(entry).toLowerCase());
        }

        function add(entry) {
            const e = String(entry).trim();
            if (e !== "" && !has(e))
                Config.set("gameClasses", list.concat([e]));
        }

        function remove(entry) {
            const next = list.filter(x => x !== entry);
            if (next.length === 0)
                Config.reset("gameClasses");
            else
                Config.set("gameClasses", next);
        }

        // The window classes are guesses until checked with hyprctl clients; the GeForce NOW
        // and Minecraft ones are patterns for that reason
        readonly property var suggestions: [
            ["org.vinegarhq.Sober", "Sober (Roblox)"],
            ["*geforce*", "GeForce NOW app"],
            ["title:*GeForce NOW*", "GeForce NOW in the browser"],
            ["Minecraft*", "Minecraft"],
            ["osu!", "osu!"],
            ["retroarch", "RetroArch"]
        ].filter(s => !has(s[0]))

        // One entry per class of the windows open now, without the shell and what already counts
        readonly property var openWindows: {
            const seen = new Set();
            const out = [];
            for (const t of ToplevelManager.toplevels.values) {
                const id = String(t.appId ?? "");
                if (id === "" || seen.has(id.toLowerCase()) || id.startsWith("org.quickshell") || Toggles.isGame(id, t.title))
                    continue;
                seen.add(id.toLowerCase());
                out.push([id, t.title ?? ""]);
            }
            return out;
        }

        Layout.fillWidth: true
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: "games for game mode"
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 14
        }
        Text {
            Layout.fillWidth: true
            text: "Steam games and gamescope count by themselves; add the rest here. A window class (any case, * matches anything) or title:… for the window title"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            Text {
                visible: games.list.length === 0
                text: "nothing on the list yet"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 13
            }
            Repeater {
                model: games.list
                delegate: Action {
                    required property var modelData
                    text: `${modelData}  ✕`
                    tint: Theme.text
                    onClicked: games.remove(modelData)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                Layout.preferredWidth: 300
                Layout.preferredHeight: 30
                color: "transparent"
                border.width: 1
                border.color: entry.activeFocus ? Theme.primary : Theme.border

                TextInput {
                    id: entry
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 14
                    clip: true
                    selectByMouse: true
                    onAccepted: {
                        games.add(text);
                        text = "";
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: entry.text === "" && !entry.activeFocus
                        text: "class, *pattern* or title:…"
                        color: Theme.muted
                        font: entry.font
                    }
                }
            }
            Action {
                text: "add"
                available: entry.text.trim() !== ""
                onClicked: {
                    games.add(entry.text);
                    entry.text = "";
                }
            }
            Action {
                text: "from open windows"
                active: games.picking
                onClicked: games.picking = !games.picking
            }
        }

        // The open windows: a click puts the class on the list
        Flow {
            Layout.fillWidth: true
            visible: games.picking
            spacing: 6

            Text {
                visible: games.openWindows.length === 0
                text: "no other windows open; start the game, then look here again"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 13
            }
            Repeater {
                model: games.picking ? games.openWindows : []
                delegate: Action {
                    required property var modelData
                    text: modelData[1] !== "" ? `+ ${modelData[0]} · ${modelData[1].slice(0, 28)}` : `+ ${modelData[0]}`
                    onClicked: {
                        games.add(modelData[0]);
                        games.picking = false;
                    }
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            visible: games.suggestions.length > 0
            spacing: 6

            Text {
                height: 30
                verticalAlignment: Text.AlignVCenter
                text: "suggestions"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: 12
            }
            Repeater {
                model: games.suggestions
                delegate: Action {
                    required property var modelData
                    text: `+ ${modelData[1]}`
                    onClicked: games.add(modelData[0])
                }
            }
        }
    }

    component Heading: Text {
        Layout.fillWidth: true
        Layout.topMargin: 10
        color: Theme.primary
        font.family: Theme.font
        font.pixelSize: 13
    }

    // ── Layout ───────────────────────────────────────────────

    RowLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.topMargin: 26
        spacing: 22

        // Sections
        Frame {
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            label: "settings"
            padding: 14

            ColumnLayout {
                anchors.fill: parent
                spacing: 6

                Repeater {
                    model: root.sections
                    delegate: TuiButton {
                        id: nav

                        required property var modelData

                        Layout.fillWidth: true
                        implicitHeight: 52
                        active: root.section === modelData[0]
                        onClicked: root.section = modelData[0]

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                text: nav.modelData[1]
                                color: nav.active ? Theme.text : Theme.textDim
                                font.family: Theme.font
                                font.pixelSize: 14
                            }
                            Text {
                                text: nav.modelData[2]
                                color: Theme.muted
                                font.family: Theme.font
                                font.pixelSize: 11
                            }
                        }
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                Text {
                    Layout.fillWidth: true
                    text: root.status
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                Action {
                    Layout.fillWidth: true
                    text: "close"
                    onClicked: root.closeRequested()
                }
            }
        }

        Frame {
            Layout.fillWidth: true
            Layout.fillHeight: true
            label: root.sections.find(s => s[0] === root.section)?.[1] ?? ""
            padding: 22

            Flickable {
                id: page

                anchors.fill: parent
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: content

                    width: page.width
                    spacing: 16

                    // ── look ──
                    ColumnLayout {
                        visible: root.section === "look"
                        Layout.fillWidth: true
                        spacing: 16

                        Heading { text: "theme · colors for every app, the boot screen and the keyboard" }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 3
                            columnSpacing: 10
                            rowSpacing: 10

                            Repeater {
                                model: root.themes
                                delegate: TuiButton {
                                    id: swatch

                                    required property var modelData

                                    Layout.fillWidth: true
                                    implicitHeight: 64
                                    active: root.currentTheme === modelData.id
                                    accent: modelData.colors?.primary ?? Theme.primary
                                    onClicked: root.runFrame(["theme", "set", modelData.id], `theme ${modelData.id}`)

                                    Column {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 8

                                        Text {
                                            text: swatch.modelData.name ?? swatch.modelData.id
                                            color: swatch.active ? Theme.text : Theme.textDim
                                            font.family: Theme.font
                                            font.pixelSize: 14
                                        }
                                        Row {
                                            spacing: 4
                                            Repeater {
                                                model: ["bg", "surface2", "primary", "secondary", "accent", "text"]
                                                delegate: Rectangle {
                                                    required property string modelData
                                                    width: 16
                                                    height: 16
                                                    color: swatch.modelData.colors?.[modelData] ?? "transparent"
                                                    border.width: 1
                                                    border.color: Theme.border
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Setting {
                            title: "window layout"
                            hint: "Hyprland's tiling, or the infinite canvas where windows float on an endless plane"

                            Action {
                                text: "tiling"
                                active: root.currentLayout === "tiling"
                                onClicked: root.runFrame(["layout", "tiling"], "layout tiling")
                            }
                            Action {
                                text: "canvas"
                                active: root.currentLayout === "canvas"
                                onClicked: root.runFrame(["layout", "canvas"], "layout canvas")
                            }
                        }

                        Setting {
                            title: "wallpaper"
                            hint: "pictures, videos and Wallpaper Engine scenes (Super+W)"

                            Action {
                                text: "open ›"
                                onClicked: root.wallpapersRequested()
                            }
                        }

                        NumberSetting {
                            key: "lockBlur"
                            title: "lockscreen blur"
                            hint: "how blurred the desktop is behind the lockscreen"
                            min: 0
                            max: 1
                            step: 0.1
                        }
                    }

                    // ── shell ──
                    ColumnLayout {
                        visible: root.section === "shell"
                        Layout.fillWidth: true
                        spacing: 16

                        Heading { text: "lock and screens" }

                        NumberSetting {
                            key: "idleLockMinutes"
                            title: "lock when idle"
                            hint: "minutes without input before the lockscreen comes up"
                            max: 120
                            unit: " min"
                            zero: "never"
                        }
                        NumberSetting {
                            key: "idleScreenOffMinutes"
                            title: "screens off when idle"
                            hint: "minutes without input before the screens go dark"
                            max: 240
                            unit: " min"
                            zero: "never"
                        }

                        Heading { text: "weather" }

                        TextSetting {
                            key: "weatherLocation"
                            title: "city"
                            hint: "empty: guessed from your connection"
                            placeholder: "e.g. Berlin"
                        }
                        NumberSetting {
                            key: "weatherInterval"
                            title: "update every"
                            min: 5
                            max: 120
                            step: 5
                            unit: " min"
                        }
                    }

                    // ── notifications ──
                    ColumnLayout {
                        visible: root.section === "notifications"
                        Layout.fillWidth: true
                        spacing: 14

                        Heading { text: "what shows when · always gets through game mode, not in game waits in the bell" }

                        Heading { text: "system"; color: Theme.secondary }
                        RuleSetting {
                            kind: "sys.apps"
                            title: "apps"
                            hint: "downloads, mail, anything that sends one over D-Bus"
                        }
                        Setting {
                            title: "critical ones"
                            hint: "battery low, or the app says it is urgent"

                            Text {
                                text: "always · can't be turned off"
                                color: Theme.muted
                                font.family: Theme.font
                                font.pixelSize: 13
                            }
                        }
                        RuleSetting {
                            kind: "sys.gamemode"
                            title: "game mode on and off"
                        }

                        Heading { text: "discord"; color: Theme.secondary }
                        RuleSetting {
                            kind: "dc.call"
                            title: "calls"
                            hint: "someone rings you"
                        }
                        RuleSetting {
                            kind: "dc.dm"
                            title: "direct and group messages"
                        }
                        RuleSetting {
                            kind: "dc.mention"
                            title: "server mentions"
                            hint: "@you or a reply in a server"
                        }
                        ChoiceSetting {
                            key: "discordMessagesWhen"
                            title: "messages while Discord is open"
                            hint: "anyway, or not while you look at it: focused, or on any screen"
                            options: [["always", "anyway"], ["unfocused", "not focused"], ["hidden", "on no screen"]]
                        }
                        RuleSetting {
                            kind: "dc.voice"
                            title: "voice channels"
                            hint: "people join or leave yours or one you watch"
                        }
                        RuleSetting {
                            kind: "dc.event"
                            title: "server events"
                            hint: "a stage or event starts"
                        }
                        RuleSetting {
                            kind: "dc.self"
                            title: "mute and deafen"
                            hint: "your own keys, and DMs sent from the launcher"
                        }

                        Heading { text: "steam"; color: Theme.secondary }
                        RuleSetting {
                            kind: "st.invite"
                            title: "game invites"
                            hint: "a friend invites you, with join"
                        }
                        RuleSetting {
                            kind: "st.request"
                            title: "friend requests"
                        }
                        RuleSetting {
                            kind: "st.message"
                            title: "messages"
                        }
                        ChoiceSetting {
                            key: "steamMessagesWhen"
                            title: "messages while Steam is open"
                            hint: "anyway, or not while you look at it: focused, or on any screen"
                            options: [["always", "anyway"], ["unfocused", "not focused"], ["hidden", "on no screen"]]
                        }
                        RuleSetting {
                            kind: "st.friends"
                            title: "friends online or playing"
                        }
                        RuleSetting {
                            kind: "st.achievement"
                            title: "achievements"
                            hint: "Steam shows its own in the game"
                        }
                        RuleSetting {
                            kind: "st.download"
                            title: "downloads ready"
                        }

                        Heading { text: "spotify"; color: Theme.secondary }
                        RuleSetting {
                            kind: "sp.song"
                            title: "next song popup"
                            hint: "not when you skipped from the card under the bar"
                        }

                        Setting {
                            title: "all rules"
                            hint: "the bell in the bar still holds back everything but calls and alarms"

                            Action {
                                text: "back to default"
                                available: Config.isSet("notifyRules")
                                onClicked: Config.reset("notifyRules")
                            }
                        }

                        Heading { text: "popups · look and place" }

                        PositionSetting {
                            key: "notificationPosition"
                            title: "where"
                        }
                        ChoiceSetting {
                            key: "notificationStyle"
                            title: "style"
                            hint: "card: frame, picture, buttons · line: one line · minimal: who and what"
                            options: [["card", "card"], ["line", "line"], ["minimal", "minimal"]]
                        }
                        NumberSetting {
                            key: "notificationWidth"
                            title: "width"
                            min: 340
                            max: 680
                            step: 20
                            unit: " px"
                        }
                        NumberSetting {
                            key: "notificationTimeout"
                            title: "stay on screen"
                            hint: "when the app does not say how long"
                            min: 1
                            max: 30
                            factor: 1000
                            unit: " s"
                        }
                        NumberSetting {
                            key: "notificationsMax"
                            title: "at once"
                            hint: "popups on screen at the same time"
                            min: 1
                            max: 6
                        }

                        Heading { text: "Spotify popup" }

                        PositionSetting {
                            key: "spotifyPosition"
                            title: "where"
                        }
                        ChoiceSetting {
                            key: "spotifyFormat"
                            title: "format"
                            hint: "wide: cover beside the song · tall: big cover on top · strip: one thin line"
                            options: [["wide", "wide"], ["tall", "tall"], ["strip", "strip"]]
                        }
                        NumberSetting {
                            key: "spotifySize"
                            title: "size"
                            min: 0.6
                            max: 1.6
                            step: 0.1
                            unit: "×"
                        }
                        NumberSetting {
                            key: "spotifySeconds"
                            title: "stays"
                            hint: "longer while the mouse is on it"
                            min: 2
                            max: 20
                            unit: " s"
                        }

                        Heading { text: "Discord voice overlay · faces and names, no frame or background" }
                        ChoiceSetting {
                            key: "voiceOverlayWhen"
                            title: "shows"
                            hint: "only while you are in a voice channel"
                            options: [["always", "always"], ["hidden", "Discord on no screen"], ["game", "in game"], ["never", "never"]]
                        }
                        ChoiceSetting {
                            key: "voiceOverlayLook"
                            title: "look"
                            hint: "compact: faces in a row, names only while talking"
                            options: [["list", "list"], ["compact", "compact"], ["talking", "only who talks"]]
                        }
                        ChoiceSetting {
                            key: "voiceOverlayFeed"
                            title: "joins, leaves, your mute"
                            hint: "your own channel; watched channels stay notifications"
                            options: [["overlay", "in the overlay"], ["notify", "notification"], ["both", "both"]]
                        }
                        NumberSetting {
                            key: "voiceOverlaySize"
                            title: "size"
                            min: 0.6
                            max: 1.6
                            step: 0.1
                            unit: "×"
                        }
                        BoolSetting {
                            key: "voiceOverlayDim"
                            title: "dim the quiet ones"
                            hint: "list look: who talks stays bright"
                        }
                        Setting {
                            key: "voiceOverlayPos"
                            title: "place"
                            hint: "Super+Shift+V, then drag it; Esc keeps the spot (per screen). default: left, under the bar"

                            Action {
                                text: "move"
                                onClicked: Quickshell.execDetached(["qs", "ipc", "call", "voice", "move"])
                            }
                        }
                    }

                    // ── launcher ──
                    ColumnLayout {
                        visible: root.section === "launcher"
                        Layout.fillWidth: true
                        spacing: 16

                        Heading { text: "web search (?)" }

                        Setting {
                            key: "searchDefault"
                            title: "search with"
                            hint: "without a shortcut; with one: ? g, ? yt, ? aw …"

                            Repeater {
                                model: Object.keys(Config.searchEngines)
                                delegate: Action {
                                    required property string modelData
                                    text: modelData
                                    active: Config.searchDefault === modelData
                                    onClicked: Config.set("searchDefault", modelData)
                                }
                            }
                        }

                        Heading { text: "Claude (c)" }

                        BoolSetting {
                            key: "claudeEnabled"
                            title: "ask Claude in the launcher"
                            hint: "only there when the claude command is installed"
                        }
                        TextSetting {
                            key: "claudeModel"
                            title: "model"
                            hint: "passed as --model; empty: your CLI's default"
                            placeholder: "haiku"
                        }

                        Heading { text: "files (/) and timers (t, a)" }

                        TextSetting {
                            key: "fileSearchRoot"
                            title: "search files in"
                            hint: "empty: your home folder"
                            placeholder: "~"
                        }
                        NumberSetting {
                            key: "snoozeMinutes"
                            title: "snooze"
                            min: 1
                            max: 60
                            unit: " min"
                        }
                    }

                    // ── games ──
                    ColumnLayout {
                        visible: root.section === "games"
                        Layout.fillWidth: true
                        spacing: 16

                        BoolSetting {
                            key: "gameModeAuto"
                            title: "game mode by itself"
                            hint: "on while a Steam game, gamescope or one from the list below runs, off again after"
                        }
                        BoolSetting {
                            key: "gameModeSilent"
                            title: "quiet while playing"
                            hint: "what is set to \"not in game\" under notifications waits; off: everything shows"
                        }
                        BoolSetting {
                            key: "barOverFullscreen"
                            title: "bar at the top edge over fullscreen"
                            hint: "rest the mouse on the top edge in a game's menu, the bar comes down over it"
                        }
                        GameListSetting {}
                        TextSetting {
                            key: "goxlrGameProfile"
                            title: "GoXLR profile while playing"
                            hint: "the one before comes back after; empty: none"
                        }
                    }

                    // ── sound ──
                    ColumnLayout {
                        visible: root.section === "sound"
                        Layout.fillWidth: true
                        spacing: 12

                        Heading { text: "output · where the sound goes" }

                        Repeater {
                            model: Audio.sinks
                            delegate: TuiButton {
                                id: sinkButton

                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 34
                                active: Pipewire.defaultAudioSink?.id === modelData.id
                                onClicked: Pipewire.preferredDefaultAudioSink = modelData

                                Label {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 24
                                    text: sinkButton.modelData.description || sinkButton.modelData.nickname || sinkButton.modelData.name
                                    color: sinkButton.active ? Theme.text : Theme.textDim
                                }
                            }
                        }

                        Heading { text: "input · the microphone apps get" }

                        Repeater {
                            model: Audio.sources.filter(n => !Audio.isMonitor(n))
                            delegate: TuiButton {
                                id: sourceButton

                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 34
                                active: Pipewire.defaultAudioSource?.id === modelData.id
                                onClicked: Pipewire.preferredDefaultAudioSource = modelData

                                Label {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 24
                                    text: sourceButton.modelData.description || sourceButton.modelData.nickname || sourceButton.modelData.name
                                    color: sourceButton.active ? Theme.text : Theme.textDim
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            wrapMode: Text.Wrap
                            color: Theme.muted
                            font.pixelSize: 12
                            text: "Levels per app and the GoXLR's channels are in the control center's mixer."
                        }
                    }

                    // ── apps ──
                    ColumnLayout {
                        visible: root.section === "apps"
                        Layout.fillWidth: true
                        spacing: 14

                        Heading { text: "modules · only what is installed is downloaded" }

                        Repeater {
                            model: root.modules
                            delegate: Setting {
                                id: mod

                                required property var modelData
                                readonly property bool isInstalled: root.installed.includes(modelData[0])

                                title: isInstalled ? modelData[0] : `${modelData[0]} · not installed`
                                hint: modelData[1]

                                Action {
                                    visible: mod.isInstalled
                                    text: "update"
                                    onClicked: root.inTerminal(`frame update ${mod.modelData[0]}`, [root.frameBin, "update", mod.modelData[0]])
                                }
                                Action {
                                    visible: !mod.isInstalled
                                    text: "add"
                                    tint: Theme.primary
                                    onClicked: root.inTerminal(`frame add ${mod.modelData[0]}`, [root.frameBin, "add", mod.modelData[0]])
                                }
                            }
                        }

                        Heading { text: "app settings" }

                        Setting {
                            title: "Spotify Web API"
                            hint: "search and control from the launcher (s) without the app in front"

                            Action {
                                text: "connect"
                                onClicked: root.inTerminal("frame spotify login", [root.frameBin, "spotify", "login"])
                            }
                        }
                        Setting {
                            title: "keyboard"
                            hint: "lighting, Fn keys and key colors (Super+K)"

                            Action {
                                text: "open ›"
                                onClicked: root.keyboardRequested()
                            }
                        }
                        BoolSetting {
                            key: "keyboardLive"
                            title: "keyboard live"
                            hint: "off: the keyboard app only shows what it would send"
                        }
                        Setting {
                            title: "GoXLR lights"
                            hint: "faders, buttons and the animation in the theme's colors"

                            Action {
                                text: "apply"
                                onClicked: root.runFrame(["goxlr"], "GoXLR lights")
                            }
                        }
                    }

                    // ── system ──
                    ColumnLayout {
                        visible: root.section === "system"
                        Layout.fillWidth: true
                        spacing: 14

                        Setting {
                            title: "updates"
                            hint: {
                                const parts = [];
                                if (Updates.total > 0)
                                    parts.push(`${Updates.total} packages waiting (${Updates.aurCount} from the AUR)`);
                                if (Updates.frameCount > 0)
                                    parts.push(`frameshell: ${Updates.frameList.map(r => `${r.name} ${r.from} → ${r.to}`).join(", ")}`);
                                return parts.length > 0 ? `${parts.join("; ")}, then frame update` : "everything is up to date";
                            }

                            Action {
                                text: Updates.updating ? "updating…" : "update"
                                tint: Theme.primary
                                available: !Updates.updating
                                onClicked: Updates.update()
                            }
                        }
                        BoolSetting {
                            key: "frameUpdates"
                            title: "frameshell updates"
                            hint: "show frameshell updates in the bar: the CLI and modules behind GitHub"
                        }

                        Setting {
                            title: "boot splash and console colors"
                            hint: "Plymouth and the text consoles in the theme (needs sudo)"

                            Action {
                                text: "install"
                                onClicked: root.inTerminal("frame boot install", [root.frameBin, "boot", "install"])
                            }
                            Action {
                                text: "remove"
                                onClicked: root.inTerminal("frame boot remove", [root.frameBin, "boot", "remove"])
                            }
                        }

                        Setting {
                            title: "login screen"
                            hint: "the lockscreen look at boot, or straight into the locked desktop (greetd, needs sudo)"

                            Action {
                                text: "login screen"
                                onClicked: root.inTerminal("frame login install", [root.frameBin, "login", "install"])
                            }
                            Action {
                                text: "auto"
                                onClicked: root.inTerminal("frame login auto", [root.frameBin, "login", "auto"])
                            }
                            Action {
                                text: "distro's"
                                onClicked: root.inTerminal("frame login remove", [root.frameBin, "login", "remove"])
                            }
                        }

                        Setting {
                            title: "check and clean"
                            hint: "what is installed and missing; caches and leftovers frame can remove"

                            Action {
                                text: "status"
                                onClicked: root.inTerminal("frame status", [root.frameBin, "status"])
                            }
                            Action {
                                text: "clean"
                                onClicked: root.inTerminal("frame clean", [root.frameBin, "clean"])
                            }
                        }

                        Heading { text: "about" }

                        Label {
                            Layout.fillWidth: true
                            text: root.about
                            wrapMode: Text.Wrap
                            color: Theme.muted
                            font.pixelSize: 13
                        }

                        Setting {
                            title: "settings file"
                            hint: Config.file.replace(root.home, "~")

                            Action {
                                text: "open"
                                onClicked: Quickshell.execDetached(["xdg-open", Config.file])
                            }
                        }
                    }
                }
            }
        }
    }
}
