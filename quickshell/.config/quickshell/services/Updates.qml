pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Package updates for the bar: repository ones the way checkupdates finds them (it
// syncs into a temporary database, so nothing changes on the system) and AUR ones from
// paru or yay. Checked a minute after start and then every 30 minutes; a click on the
// number opens Ghostty with the update and `facet update`, and checks again when it closes.
// facet itself (the CLI and the module clones) is checked on the same schedule,
// unless Config.frameUpdates is off.
//
// list: [{ name, from, to, aur }]
// frameList: [{ name, from, to }], short hashes of the repos that are behind
Singleton {
    id: root

    property var list: []
    readonly property int total: list.length
    readonly property int aurCount: list.filter(p => p.aur).length
    property var frameList: []
    readonly property int frameCount: frameList.length
    readonly property bool checking: checker.running || frameChecker.running
    property bool updating: false
    // Only facet is behind: the click skips the package manager (and its sudo)
    property bool frameOnly: false

    function check() {
        if (updating)
            return;
        if (!checker.running)
            checker.running = true;
        checkFrame();
    }

    function checkFrame() {
        if (Config.frameUpdates && !frameChecker.running && !updating)
            frameChecker.running = true;
    }

    // "name 1.0-1 -> 1.1-1", one per line; the AUR helpers print the same
    function parse(text) {
        const out = [];
        for (const line of text.split("\n")) {
            const aur = line.startsWith("aur ");
            const m = /^(\S+) (\S+) -> (\S+)/.exec(aur ? line.slice(4) : line);
            if (m)
                out.push({ name: m[1], from: m[2], to: m[3], aur });
        }
        return out;
    }

    // "name local remote", one per repo that is behind; sorted, the checks finish in any order
    function parseFrame(text) {
        const out = [];
        for (const line of text.split("\n")) {
            const m = /^(\S+) (\S+) (\S+)$/.exec(line);
            if (m)
                out.push({ name: m[1], from: m[2], to: m[3] });
        }
        return out.sort((a, b) => a.name.localeCompare(b.name));
    }

    function update() {
        if (updating)
            return;
        frameOnly = total === 0 && frameCount > 0;
        updating = true;
        updater.running = true;
    }

    Process {
        id: checker
        // Like checkupdates, without pacman-contrib: a copy of the sync databases in /tmp
        // (memory, not disk), refreshed there, then compared with what is installed; the
        // system's own databases stay untouched. AUR lines get an "aur " prefix.
        command: ["sh", "-c", 'db="${TMPDIR:-/tmp}/facet-updates-$(id -u)"; mkdir -p "$db"; ln -sfn /var/lib/pacman/local "$db/local"; '
            + 'if command -v fakeroot >/dev/null && fakeroot -- pacman -Sy --dbpath "$db" --logfile /dev/null >/dev/null 2>&1; then '
            + 'pacman -Qu --dbpath "$db" 2>/dev/null; fi; '
            + 'if command -v paru >/dev/null; then paru -Qua 2>/dev/null; elif command -v yay >/dev/null; then yay -Qua 2>/dev/null; fi | sed "s/^/aur /"; true']
        stdout: StdioCollector {
            onStreamFinished: root.list = root.parse(this.text)
        }
    }

    Process {
        id: frameChecker
        // The CLI (wherever ~/.local/bin/frame points, else its usual clone) and every
        // module clone: git ls-remote only asks the remote for its branch tip, so nothing
        // is fetched or changed. All repos at once, each with a timeout and no credential
        // prompt, so a slow or missing network cannot hold the check up. A remote tip that
        // HEAD already contains is not an update (local commits on top of it).
        command: ["sh", "-c", 'd="${XDG_DATA_HOME:-$HOME/.local/share}/facet"; '
            + 'f=$(readlink -f "$HOME/.local/bin/frame" 2>/dev/null) && cli=${f%/*}; [ -d "$cli/.git" ] || cli="$d/cli"; '
            + 'behind() { b=$(git -C "$2" symbolic-ref -q --short HEAD) || b=main; '
            + 'l=$(git -C "$2" rev-parse -q --verify HEAD) || return; '
            + 'o=$(GIT_TERMINAL_PROMPT=0 timeout 20 git -C "$2" ls-remote origin "refs/heads/$b" 2>/dev/null | cut -f1); '
            + '[ -n "$o" ] || return; '
            + 'git -C "$2" merge-base --is-ancestor "$o" HEAD 2>/dev/null && return; '
            + 'printf "%s %.7s %.7s\\n" "$1" "$l" "$o"; }; '
            + '[ -d "$cli/.git" ] && behind cli "$cli" & '
            + 'for m in "$d"/modules/*/; do m=${m%/}; [ -d "$m/.git" ] && behind "${m##*/}" "$m" & done; '
            + 'wait; true']
        stdout: StdioCollector {
            // Turned off while it ran: drop what it found
            onStreamFinished: root.frameList = Config.frameUpdates ? root.parseFrame(this.text) : []
        }
    }

    // Its own Ghostty process (not the single-instance one), so closing the window ends it
    Process {
        id: updater
        command: ["ghostty", "--gtk-single-instance=false", "--title=facet update", "-e", "sh", "-c",
            (root.frameOnly ? '' : 'if command -v paru >/dev/null; then paru -Syu; elif command -v yay >/dev/null; then yay -Syu; else sudo pacman -Syu; fi; ')
            + '[ -x "$HOME/.local/bin/frame" ] && "$HOME/.local/bin/frame" update; '
            + 'printf "\\nDone. Enter closes this window."; read _']
        onExited: {
            root.updating = false;
            root.check();
        }
    }

    // Switched on in the settings: look right away instead of at the next round
    Connections {
        target: Config
        function onFrameUpdatesChanged() {
            if (Config.frameUpdates)
                root.checkFrame();
            else
                root.frameList = [];
        }
    }

    Timer {
        interval: 60 * 1000
        running: true
        onTriggered: root.check()
    }

    Timer {
        interval: 30 * 60 * 1000
        running: true
        repeat: true
        onTriggered: root.check()
    }
}
