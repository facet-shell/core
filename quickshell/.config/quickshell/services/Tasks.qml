pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.services

// Running apps for the task manager in the control center: every process tree folded into
// the app it belongs to, with CPU and memory, so a hung game can be closed or killed with
// one click. Polls /proc every two seconds while `active` (the panel is open).
//
// apps: [{ key, pid, name, detail, icon, glyph, windowed, windows: [address], pids: [all of
// the tree], cpu (percent of one core), mem (bytes), count }]
// A process belongs to the nearest ancestor that owns a window (the game, not Steam that
// started it); what has no window at all is grouped under its topmost process below
// systemd or Hyprland (so a terminal's shells and their programs stay with the terminal).
Singleton {
    id: root

    property bool active: false
    property var apps: []
    readonly property var windowed: apps.filter(a => a.windowed)
    readonly property var background: apps.filter(a => !a.windowed)
    property bool loaded: false

    // Never offered to kill: the session itself, this shell and the daemons the desktop
    // runs on (comm as /proc spells it, 15 characters at most)
    readonly property var keep: ["systemd", "Hyprland", "qs", "init", "greetd", "Xwayland", "pipewire", "pipewire-pulse",
        "wireplumber", "xdg-desktop-por", "dbus-broker", "dbus-daemon", "hyprland-share-", "hypridle", "xwaylandsatelli",
        "start-hyprland", "systemd-journal", "uwsm", "gnome-keyring-d", "polkit-kde-auth", "at-spi-bus-laun", "at-spi2-registr"]
    readonly property var wrappers: ["sh", "bash", "zsh", "fish", "dash", "env", "python3", "python", "uwsm", "steam-runtime-l", "pv-adverb",
        "pressure-vessel", "pv-wrap", "bwrap", "reaper", "proton", "wine", "wine64", "wineserver", "start.sh", "timeout"]
    readonly property int clockTicks: 100

    property var lastTicks: ({})
    property real lastTime: 0

    function refresh() {
        Hyprland.refreshToplevels();
        proc.running = true;
    }

    Timer {
        interval: 2000
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Leaves after a while so the next opening does not show stale numbers for two seconds
    onActiveChanged: if (!active) { lastTicks = {}; lastTime = 0; loaded = false; }

    // The desktop entry of a window class: the id, its last reverse-domain segment or the
    // StartupWMClass (dev.zed.Zed is "zed", org.kde.dolphin is "dolphin")
    function entryFor(cls) {
        const c = cls.toLowerCase();
        const short = c.slice(c.lastIndexOf(".") + 1);
        let best = null;
        for (const e of Apps.entries) {
            const id = String(e.id ?? "").toLowerCase();
            const idShort = id.slice(id.lastIndexOf(".") + 1);
            const startup = String(e.startupClass ?? "").toLowerCase();
            if (id === c || startup === c)
                return e;
            if (!best && (idShort === short || startup === short))
                best = e;
        }
        return best;
    }

    function prettyClass(cls) {
        const short = cls.slice(cls.lastIndexOf(".") + 1).replace(/[-_]+/g, " ");
        return short.charAt(0).toUpperCase() + short.slice(1);
    }

    function formatMem(bytes) {
        if (bytes >= 1024 * 1024 * 1024)
            return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
        return `${Math.round(bytes / (1024 * 1024))} MiB`;
    }

    function parse(text) {
        const now = Date.now();
        const elapsed = lastTime > 0 ? (now - lastTime) / 1000 : 0;
        const procs = {};
        for (const line of text.split("\n")) {
            // pid (comm) state ppid … utime stime … rss; comm may hold spaces and parens
            const open = line.indexOf("("), close = line.lastIndexOf(")");
            if (open < 0 || close < 0)
                continue;
            const pid = Number(line.slice(0, open).trim());
            const comm = line.slice(open + 1, close);
            const r = line.slice(close + 2).split(" ");
            const ppid = Number(r[1]);
            if (pid === 2 || ppid === 2)
                continue;
            procs[pid] = { pid, ppid, comm, ticks: Number(r[11]) + Number(r[12]), rss: Number(r[21]) * 4096 };
        }

        // Windows by the pid that owns them
        const windows = {};
        for (const t of Hyprland.toplevels.values) {
            const o = t.lastIpcObject ?? {};
            const pid = Number(o.pid ?? 0);
            if (!(pid in procs) || o.mapped === false)
                continue;
            (windows[pid] = windows[pid] ?? []).push({
                address: String(o.address ?? t.address ?? ""), title: String(o.title ?? ""),
                cls: String(o.class ?? t.wayland?.appId ?? ""), order: Number(o.focusHistoryID ?? 1e9)
            });
        }

        // Which app a process belongs to, walking up the tree once per process
        const groupOf = {};
        const resolve = pid => {
            if (pid in groupOf)
                return groupOf[pid];
            const p = procs[pid];
            if (!p)
                return 0;
            let g;
            if (pid in windows)
                g = pid;
            else if (!(p.ppid in procs) || p.ppid <= 1 || keep.includes(procs[p.ppid].comm))
                g = pid;
            else {
                const up = resolve(p.ppid);
                // Under a window owner: that app; under a plain root: the root, unless this
                // process starts an app of its own (it has windows, handled above)
                g = up;
            }
            groupOf[pid] = g;
            return g;
        };

        const groups = {};
        for (const pid in procs) {
            const g = resolve(Number(pid));
            if (!g)
                continue;
            const p = procs[pid];
            const grp = groups[g] = groups[g] ?? { pid: g, pids: [], ticks: 0, rss: 0 };
            grp.pids.push(p.pid);
            grp.ticks += p.ticks;
            grp.rss += p.rss;
        }

        const ticksNow = {};
        const out = [];
        for (const key in groups) {
            const grp = groups[key];
            const head = procs[grp.pid];
            if (keep.includes(head.comm))
                continue;
            ticksNow[grp.pid] = grp.ticks;
            const before = lastTicks[grp.pid];
            const cpu = elapsed > 0 && before !== undefined ? Math.max(0, (grp.ticks - before) / clockTicks / elapsed * 100) : 0;
            const wins = (windows[grp.pid] ?? []).slice().sort((a, b) => a.order - b.order);
            let name = head.comm, detail = "", icon = "";
            if (wins.length > 0) {
                const cls = wins[0].cls;
                const entry = entryFor(cls);
                // A Proton game is steam_app_<id>: its window title says which game
                name = /^steam_app_/.test(cls) && wins[0].title !== "" ? wins[0].title : (entry?.name ?? prettyClass(cls));
                icon = entry?.icon ?? "";
                detail = wins.length > 1 ? `${wins.length} windows · ${wins[0].title}` : wins[0].title;
            } else {
                // Named after the first process that is not a shell or launcher around the
                // real one: the wallpaper engine, not the sh that started it
                const main = grp.pids.slice().sort((a, b) => a - b).map(pid => procs[pid]).find(p => !wrappers.includes(p.comm)) ?? head;
                name = main.comm;
                detail = `${grp.pids.length} process${grp.pids.length === 1 ? "" : "es"}`
                    + (main !== head ? ` · started by ${head.comm}` : "");
            }
            out.push({
                key: String(grp.pid), pid: grp.pid, name, detail, icon,
                glyph: name.charAt(0).toUpperCase(), windowed: wins.length > 0,
                windows: wins.map(w => w.address), pids: grp.pids, cpu, mem: grp.rss, count: grp.pids.length
            });
        }
        // Busy first; among the quiet ones the big ones
        out.sort((a, b) => (b.cpu - a.cpu) || (b.mem - a.mem));
        lastTicks = ticksNow;
        lastTime = now;
        apps = out;
        loaded = true;
    }

    // Asks the windows to close (the app may save and ask back); without a window: SIGTERM.
    // Hyprland's Lua config takes dispatches through eval (Apps.summon does the same)
    function close(app) {
        if (app.windowed) {
            const calls = app.windows.map(a => `hl.dispatch(hl.dsp.exec_raw("closewindow address:${a.replace(/[^0-9a-fx]/gi, "")}"))`);
            Quickshell.execDetached(["hyprctl", "eval", calls.join(" ")]);
        } else {
            Quickshell.execDetached(["kill", "-TERM", "--"].concat(app.pids.map(String)));
        }
        later.restart();
    }

    // The whole tree, no questions asked: for a hung game
    function kill(app) {
        Quickshell.execDetached(["kill", "-KILL", "--"].concat(app.pids.map(String)));
        later.restart();
    }

    Timer {
        id: later
        interval: 600
        onTriggered: root.refresh()
    }

    Process {
        id: proc
        // Only your own processes: root's daemons could not be killed from here anyway
        command: ["sh", "-c", 'for p in /proc/[0-9]*; do [ -O "$p" ] && cat "$p/stat"; done 2>/dev/null']
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
    }
}
