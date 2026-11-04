import QtQuick
import Quickshell
import qs.config
import qs.services

// What the launcher does with a query: which mode a prefix picks, the result rows and what
// Enter does with them. LauncherView draws them.
//
// Prefixes: none apps · = calc · > run · : power · s spotify · d discord · t timer · a alarm
//           # emoji · / files · ssh hosts · ; clipboard · ? web · c claude (when installed)
// Letters need a space after them ("s " is spotify, "s" alone still searches apps).
//
// Every row has: kind, title, desc, category, glyph, tint, icon, rows ([label, value] for
// the info pane), optional markup (highlighted title), body (longer text) and keys (hint).
Item {
    id: root

    visible: false

    readonly property var symbolModes: ["=", ">", ":", "#", "/", ";", "?"]
    // "ssh" before "s", otherwise "ssh foo" would be a Spotify search
    readonly property var wordModes: Claude.available ? ["ssh", "s", "d", "t", "a", "c"] : ["ssh", "s", "d", "t", "a"]
    readonly property var names: ({
        "": "apps", "=": "calc", ">": "run", ":": "power", s: "spotify", d: "discord", t: "timer", a: "alarm",
        "#": "emoji", "/": "files", ssh: "ssh", ";": "clipboard", "?": "web", c: "claude"
    })
    readonly property var order: ["", "=", ">", ":", "s", "d", "t", "a", "#", "/", "ssh", ";", "?"].concat(Claude.available ? ["c"] : [])

    readonly property var powerActions: [
        { name: "lock", desc: "Lock the screen", glyph: "L", tint: Theme.primary,
          // Short delay so the snapshot does not catch the closing launcher
          command: ["sh", "-c", "sleep 0.3; qs ipc call lock lock"] },
        { name: "logout", desc: "End the Hyprland session", glyph: "O", tint: Theme.frame, command: ["hyprctl", "dispatch", "hl.dsp.exit()"] },
        { name: "suspend", desc: "Sleep, locks first", glyph: "S", tint: Theme.accent, command: ["systemctl", "suspend"] },
        { name: "reboot", desc: "Restart the computer", glyph: "R", tint: Theme.warn, command: ["systemctl", "reboot"] },
        { name: "shutdown", desc: "Power off", glyph: "P", tint: Theme.danger, command: ["systemctl", "poweroff"] }
    ]

    function parse(query) {
        const c = query.charAt(0);
        if (symbolModes.includes(c))
            return { mode: c, rest: query.slice(1).trim() };
        for (const w of wordModes)
            if (query.startsWith(`${w} `))
                return { mode: w, rest: query.slice(w.length + 1).trim() };
        return { mode: "", rest: query.trim() };
    }

    function prefix(mode) {
        return mode === "" || symbolModes.includes(mode) ? mode : `${mode} `;
    }

    // ── Helpers ──────────────────────────────────────────────

    function escapeHtml(text) {
        return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Name with the matched letters highlighted (StyledText)
    function markup(text, idx) {
        let out = "";
        for (let i = 0; i < text.length; i++) {
            const c = escapeHtml(text[i]);
            out += idx.includes(i) ? `<font color="${Theme.secondary}"><b>${c}</b></font>` : c;
        }
        return out;
    }

    function calculate(expr) {
        const plain = expr.replace(/,/g, ".");
        if (plain === "" || !/^[\d\s+\-*\/().%^]+$/.test(plain))
            return null;
        try {
            const value = Function(`"use strict"; return (${plain.replace(/\^/g, "**")});`)();
            return typeof value === "number" && isFinite(value) ? Math.round(value * 1e10) / 1e10 : null;
        } catch (e) {
            return null;
        }
    }

    // "1m 10s", "1h30m", "90s", "1:10", "1:02:03"; a bare number counts in bareUnit seconds
    function parseDuration(text, bareUnit) {
        const t = text.trim().toLowerCase();
        if (t === "")
            return null;
        let m;
        if ((m = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/.exec(t)))
            return m[3] !== undefined ? +m[1] * 3600 + +m[2] * 60 + +m[3] : +m[1] * 60 + +m[2];
        if (/^\d+([.,]\d+)?$/.test(t))
            return Math.round(parseFloat(t.replace(",", ".")) * bareUnit);
        let total = 0, rest = t;
        while (rest !== "") {
            m = /^(\d+(?:[.,]\d+)?)\s*(hours?|hrs?|h|std|minutes?|mins?|m|seconds?|secs?|sek|s)\s*/.exec(rest);
            if (!m)
                return null;
            const n = parseFloat(m[1].replace(",", "."));
            const unit = m[2].charAt(0);
            total += n * (unit === "h" ? 3600 : unit === "m" ? 60 : 1);
            rest = rest.slice(m[0].length);
        }
        return total > 0 ? Math.round(total) : null;
    }

    function info(title, desc) {
        return { kind: "info", title, desc: desc ?? "", category: "", glyph: "·", tint: Theme.frame, icon: "", rows: [] };
    }

    function run(command) {
        Quickshell.execDetached(command);
    }

    function copy(text) {
        run(["wl-copy", "--", String(text)]);
    }

    // ── Results ──────────────────────────────────────────────

    function compute(mode, rest) {
        switch (mode) {
        case "=": return calcRows(rest);
        case ">": return runRows(rest);
        case ":": return powerRows(rest);
        case "s": return spotifyRows(rest);
        case "d": return discordRows(rest);
        case "t": return timerRows(rest);
        case "a": return alarmRows(rest);
        case "#": return emojiRows(rest);
        case "/": return fileRows(rest);
        case "ssh": return sshRows(rest);
        case ";": return clipRows(rest);
        case "?": return webRows(rest);
        case "c": return claudeRows(rest);
        default: return appRows(rest);
        }
    }

    function appRows(rest) {
        const tints = [Theme.primary, Theme.accent, Theme.secondary, Theme.shadow, Theme.ok];
        return Apps.search(rest).map(({ entry, idx }) => {
            const win = Apps.windowOf(entry);
            return {
                kind: "app", entry,
                title: entry.name, markup: markup(entry.name, idx),
                desc: win ? `running · ${win.title}` : (entry.comment || entry.genericName || ""),
                category: Apps.categoryOf(entry),
                glyph: entry.name.charAt(0).toUpperCase(),
                tint: tints[entry.name.length % tints.length],
                icon: entry.icon,
                rows: [["category", Apps.categoryOf(entry)], ["runs", entry.execString], ["used", `${Apps.uses(entry)} times`],
                    ["window", win ? win.title : "none open"]],
                keys: win ? "↑↓ select · enter bring window here · shift+enter new one · esc close" : undefined
            };
        });
    }

    function calcRows(rest) {
        const value = calculate(rest);
        return [{
            kind: "calc", value,
            title: rest === "" ? "type a calculation" : value === null ? "not a calculation" : `${rest} = ${value}`,
            category: "calc", glyph: "=", tint: Theme.primary, icon: "",
            rows: [["input", rest || "–"], ["enter", "copies the result"]]
        }];
    }

    function runRows(rest) {
        return [{
            kind: "run", command: rest,
            title: rest === "" ? "type a command" : rest,
            desc: "opens in Ghostty and stays open",
            category: "run", glyph: ">", tint: Theme.frame, icon: "",
            rows: [["command", rest || "–"], ["shell", "fish"]]
        }];
    }

    function powerRows(rest) {
        return powerActions
            .map(p => ({ action: p, match: rest === "" ? { score: 0, idx: [] } : Apps.fuzzy(p.name, rest) }))
            .filter(x => x.match)
            .sort((a, b) => b.match.score - a.match.score)
            .map(({ action, match }) => ({
                kind: "power", name: action.name, command: action.command,
                title: action.name, markup: markup(action.name, match.idx),
                desc: action.desc, category: "power", glyph: action.glyph, tint: action.tint, icon: "",
                rows: [["runs", action.command.join(" ")], ["confirm", action.name === "lock" ? "no" : "press enter twice"]]
            }));
    }

    // ── s: Spotify ───────────────────────────────────────────

    readonly property var spotifyWords: ({
        play: "play", resume: "play", pause: "pause", stop: "pause", toggle: "toggle",
        next: "next", n: "next", skip: "next", prev: "prev", previous: "prev", p: "prev",
        forward: "forward", fw: "forward", f: "forward", ff: "forward",
        back: "back", b: "back", rewind: "back", rw: "back",
        shuffle: "shuffle", repeat: "repeat", loop: "repeat", like: "like", heart: "like"
    })
    // One icon per control (Nerd Font: Font Awesome and Material Design), so the rows differ
    readonly property var spotifyGlyphs: ({
        play: "\uf04b", pause: "\uf04c", toggle: String.fromCodePoint(0xF040E), next: "\uf051", prev: "\uf048",
        forward: "\uf04e", back: "\uf04a", jump: "\uf017", shuffle: "\uf074", repeat: "\uf01e", like: "\uf004"
    })
    readonly property var spotifyLabels: ({
        play: "play", pause: "pause", toggle: "play / pause", next: "next track", prev: "previous track",
        forward: "forward", back: "back", jump: "jump to", shuffle: "shuffle on / off", repeat: "repeat: off → all → track", like: "like / unlike"
    })

    // { action, seconds } when the query is a control word (with a time for forward/back) or a bare time
    function spotifyCommand(rest) {
        const words = rest.split(/\s+/);
        const action = spotifyWords[words[0].toLowerCase()];
        const args = words.slice(1).join(" ");
        if (action === "forward" || action === "back") {
            const seconds = args === "" ? 10 : parseDuration(args, 1);
            return seconds === null ? null : { action, seconds };
        }
        if (action && args === "")
            return { action, seconds: 0 };
        const at = /\d/.test(rest) ? parseDuration(rest, 1) : null;
        return at === null ? null : { action: "jump", seconds: at };
    }

    // "s play daft punk" searches "daft punk"; a seek with a time ("f 30", "1:10") searches
    // nothing; everything else searches the whole query, so "s next" also finds songs called next
    function spotifySearchText(rest) {
        const command = spotifyCommand(rest);
        if (command && (command.action === "jump" || ((command.action === "forward" || command.action === "back") && /\s/.test(rest))))
            return "";
        const m = /^(play|p)\s+(.+)$/i.exec(rest);
        return m && command === null ? m[2] : rest;
    }

    function nowPlaying() {
        const p = Spotify.spotifyPlayer ?? Spotify.otherPlayer;
        return p && p.trackTitle ? `${p.trackTitle} · ${p.trackArtist}` : "nothing";
    }

    function controlRow(action, seconds) {
        const time = seconds > 0 ? ` ${Timers.formatSeconds(seconds)}` : "";
        return {
            kind: "spotify-control", action, seconds,
            title: `${spotifyLabels[action]}${time}`,
            desc: `now: ${nowPlaying()}`,
            category: "control", glyph: spotifyGlyphs[action] ?? "\uf04b", glyphFont: Theme.iconFont,
            tint: Theme.primary, icon: "",
            rows: [["via", Spotify.via], ["playing", nowPlaying()]]
        };
    }

    function spotifyRows(rest) {
        if (rest === "")
            return [["toggle", 0], ["next", 0], ["prev", 0], ["forward", 10], ["back", 10], ["shuffle", 0], ["repeat", 0], ["like", 0]]
                .map(([a, s]) => controlRow(a, s))
                .concat([info(`via ${Spotify.via}`, "type to search tracks, artists, albums and playlists")]);

        const out = [];
        const command = spotifyCommand(rest);
        if (command)
            out.push(controlRow(command.action, command.seconds));

        const text = spotifySearchText(rest);
        if (text === "")
            return out;
        if (!Spotify.canSearch)
            return out.concat([info("search needs Spotify connected", "Spicetify extension or Web API, see docs/spotify.md")]);
        if (Spotify.query !== text || Spotify.searching)
            return out.concat([info("searching …")]);
        if (Spotify.error !== "")
            return out.concat([info("search failed", Spotify.error)]);
        const glyphs = { track: "♪", artist: "@", album: "◉", playlist: "≡" };
        return out.concat(Spotify.results.map(item => ({
            kind: "spotify-item", item,
            title: item.title, desc: item.subtitle,
            category: item.kind, glyph: glyphs[item.kind] ?? "♪", tint: Theme.accent, icon: item.image,
            rows: [["type", item.kind], ["length", item.length > 0 ? Timers.formatSeconds(item.length) : "–"], ["found by", Spotify.source]],
            keys: item.kind === "track" ? "enter play · shift+enter queue" : "enter play"
        })));
    }

    // ── d: Discord ───────────────────────────────────────────

    // "now", "5m", "2h", "3d" for the DM list
    function when(ms) {
        if (!ms)
            return "";
        const minutes = Math.floor((Date.now() - ms) / 60000);
        return minutes < 1 ? "now" : minutes < 60 ? `${minutes}m` : minutes < 1440 ? `${Math.floor(minutes / 60)}h` : `${Math.floor(minutes / 1440)}d`;
    }

    function findContacts(name) {
        const list = DiscordBridge.contacts;
        // Plain "d": the chats that moved last (you wrote or someone wrote you), newest first
        if (name === "")
            return list.filter(c => c.channelId && (c.time ?? 0) > 0).slice(0, 20);
        return list
            .map(c => ({ c, match: Apps.fuzzy(c.name, name) ?? Apps.fuzzy(c.username, name) }))
            .filter(x => x.match)
            .sort((a, b) => b.match.score - a.match.score)
            .map(x => x.c);
    }

    function contactRow(c, kind, title, content) {
        const last = c.last ?? null;
        const who = last ? (last.mine ? "you" : c.group ? last.author : "") : "";
        const line = last ? `${who ? `${who}: ` : ""}${last.content}` : "";
        const pings = c.mentions ?? 0;
        const status = pings > 0 ? `${pings} ping${pings === 1 ? "" : "s"}` : c.unread ? "new" : "";
        const activity = c.time ? [["last", line || "–"], ["when", `${when(c.time)}${status ? ` · ${status}` : ""}`]] : [];
        return {
            kind, contact: c, content: content ?? "",
            title,
            desc: content ? `“${content}”` : line ? `${status ? `${status} · ` : ""}${line}` : c.username !== "" ? `@${c.username}` : "",
            body: content ? "" : line,
            // The chip on the right tells a group DM from a person, both look alike otherwise
            category: c.group ? "group" : "dm", glyph: c.name.charAt(0).toUpperCase(), tint: Theme.accent, icon: c.avatar,
            rows: (c.group ? [["group", c.username], ["dm", "open"]]
                : [["user", c.username !== "" ? `@${c.username}` : c.name], ["dm", c.channelId ? "open" : "none yet"]]).concat(activity),
            keys: kind === "discord-open" ? (c.group ? "enter open group · shift+enter call" : "enter open dm · shift+enter call")
                : kind === "discord-call" ? "enter call" : "enter send"
        };
    }

    function discordRows(rest) {
        if (!DiscordBridge.connected)
            return [info("Discord is not connected", "start Vesktop with the ShellBridge plugin (facet install vencord)")];
        const words = rest.split(/\s+/);
        const first = words[0].toLowerCase();

        if (first === "reply") {
            const content = rest.slice(5).trim();
            const to = DiscordBridge.lastDm;
            if (!to)
                return [info("no DM to reply to yet", "write someone a DM in Discord first")];
            return [{
                kind: "discord-reply", content,
                title: `reply to ${to.name}`,
                desc: content === "" ? "type the message" : `“${content}”`,
                category: "discord", glyph: "↩", tint: Theme.accent, icon: "",
                rows: [["to", to.name], ["why", to.guessed ? "most recent DM (you have not written since Discord started)" : "the last DM you wrote"]],
                keys: "enter send"
            }];
        }
        if (first === "msg" && words.length >= 2) {
            const content = words.slice(2).join(" ");
            const found = findContacts(words[1]).slice(0, 9);
            return found.length === 0 ? [info(`nobody called ${words[1]}`)]
                : found.map(c => contactRow(c, "discord-send", `message ${c.group ? "group " : ""}${c.name}`, content));
        }
        if (first === "call" && words.length >= 2) {
            const found = findContacts(words.slice(1).join(" ")).slice(0, 9);
            return found.length === 0 ? [info("nobody by that name")] : found.map(c => contactRow(c, "discord-call", `call ${c.group ? "group " : ""}${c.name}`));
        }
        const found = findContacts(rest);
        if (found.length === 0)
            return [info(DiscordBridge.contacts.length === 0 ? "loading contacts …" : "nobody by that name",
                "d name · d call name · d msg name text · d reply text")];
        return found.map(c => contactRow(c, "discord-open", c.name));
    }

    // ── t: timers ────────────────────────────────────────────

    // "5m tea", "tea 5m", "1:30", "25" (minutes) → { seconds, label }
    function parseTimer(rest) {
        const words = rest.split(/\s+/);
        for (let k = words.length; k >= 1; k--) {
            const front = parseDuration(words.slice(0, k).join(" "), 60);
            if (front !== null)
                return { seconds: front, label: words.slice(k).join(" ") };
            const back = parseDuration(words.slice(words.length - k).join(" "), 60);
            if (back !== null)
                return { seconds: back, label: words.slice(0, words.length - k).join(" ") };
        }
        return null;
    }

    function runningTimers() {
        return Timers.timers.map(t => ({
            kind: "timer-running", timer: t,
            title: `${Timers.formatSeconds(Timers.left(t))} · ${t.label || "timer"}`,
            desc: `of ${Timers.formatSeconds(t.total)}`,
            category: "running", glyph: "◷", tint: Theme.secondary, icon: "",
            rows: [["ends", Timers.whenText(t.ends)], ["enter", "stops it"]],
            keys: "enter stop timer"
        }));
    }

    function timerRows(rest) {
        if (rest === "") {
            const running = runningTimers();
            return running.length > 0 ? running : [info("type a time", "t 5m tea · t 1:30 · t 25 (minutes) · t 1h 30m")];
        }
        const parsed = parseTimer(rest);
        if (!parsed)
            return [info("not a time", "t 5m tea · t 1:30 · t 25 (minutes)")].concat(runningTimers());
        return [{
            kind: "timer-start", seconds: parsed.seconds, label: parsed.label,
            title: `start ${Timers.formatSeconds(parsed.seconds)}${parsed.label !== "" ? ` · ${parsed.label}` : ""}`,
            desc: `rings at ${Timers.whenText(Date.now() + parsed.seconds * 1000)}, stays until snooze or done`,
            category: "timer", glyph: "◷", tint: Theme.primary, icon: "",
            rows: [["length", Timers.formatSeconds(parsed.seconds)], ["label", parsed.label || "–"], ["snooze", `${Config.snoozeMinutes} min`]]
        }].concat(runningTimers());
    }

    // ── a: alarms ────────────────────────────────────────────

    readonly property var dayAliases: ({
        su: 0, sun: 0, sunday: 0, so: 0, sonntag: 0,
        m: 1, mo: 1, mon: 1, monday: 1, montag: 1,
        tu: 2, tue: 2, tues: 2, tuesday: 2, di: 2, dienstag: 2,
        w: 3, we: 3, wed: 3, wednesday: 3, mi: 3, mittwoch: 3,
        th: 4, thu: 4, thr: 4, thur: 4, thurs: 4, thursday: 4, do: 4, donnerstag: 4,
        f: 5, fr: 5, fri: 5, friday: 5, freitag: 5,
        sa: 6, sat: 6, saturday: 6, samstag: 6
    })
    readonly property var dayGroups: ({
        daily: [0, 1, 2, 3, 4, 5, 6], everyday: [0, 1, 2, 3, 4, 5, 6], täglich: [0, 1, 2, 3, 4, 5, 6],
        weekdays: [1, 2, 3, 4, 5], werktags: [1, 2, 3, 4, 5], weekend: [6, 0], wochenende: [6, 0]
    })

    // "m-f", "m,w,f", "tu,th", "sa-su", "daily" → day numbers, or { error }
    function parseDays(word) {
        const w = word.toLowerCase();
        if (dayGroups[w])
            return dayGroups[w];
        const out = [];
        for (const part of w.split(",").filter(p => p !== "")) {
            const ends = part.split("-");
            for (const e of ends) {
                if (e === "t")
                    return { error: "t could be tuesday or thursday: write tu or th" };
                if (e === "s")
                    return { error: "s could be saturday or sunday: write sa or su" };
                if (dayAliases[e] === undefined)
                    return null;
            }
            if (ends.length === 1)
                out.push(dayAliases[ends[0]]);
            else if (ends.length === 2)
                for (let d = dayAliases[ends[0]]; ; d = (d + 1) % 7) {
                    out.push(d);
                    if (d === dayAliases[ends[1]])
                        break;
                }
            else
                return null;
        }
        return out.length > 0 ? out.filter((d, i) => out.indexOf(d) === i) : null;
    }

    // "10:00", "7:30", "7.30", "7pm", "19" → { hour, minute }
    function parseClock(word) {
        const m = /^(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?$/i.exec(word);
        if (!m || (m[2] === undefined && m[3] === undefined && word.length > 2))
            return null;
        let hour = +m[1];
        const minute = m[2] !== undefined ? +m[2] : 0;
        if (m[3]) {
            if (hour < 1 || hour > 12)
                return null;
            hour = hour % 12 + (m[3].toLowerCase() === "pm" ? 12 : 0);
        }
        return hour < 24 && minute < 60 ? { hour, minute } : null;
    }

    // "laundry 10:00 m-f", "7:30 tu,th gym", "call mom 18:00" → { hour, minute, days, label } or { error }
    function parseAlarm(rest) {
        const words = rest.split(/\s+/);
        // A time with ":" wins over a bare number, so "gym 2 7:30" reads 7:30
        let at = words.findIndex(w => /[:.]|am$|pm$/i.test(w) && parseClock(w));
        if (at < 0)
            at = words.findIndex(w => parseClock(w));
        if (at < 0)
            return { error: "no time yet: a laundry 10:00 m-f" };
        const time = parseClock(words[at]);
        let days = [], i = at + 1;
        for (; i < words.length; i++) {
            const d = parseDays(words[i]);
            if (d === null)
                break;
            if (d.error)
                return d;
            days = days.concat(d.filter(x => !days.includes(x)));
        }
        const label = words.slice(0, at).concat(words.slice(i)).join(" ");
        return { hour: time.hour, minute: time.minute, days, label };
    }

    function alarmList() {
        return Timers.alarms.map(a => ({
            kind: "alarm", alarm: a,
            title: `${Timers.clock(a.hour, a.minute)}${a.label !== "" ? ` · ${a.label}` : ""}`,
            desc: a.enabled ? `${Timers.daysText(a.days)} · next ${Timers.whenText(a.next)}` : `${Timers.daysText(a.days)} · off`,
            category: a.enabled ? "on" : "off", glyph: "⏰", tint: a.enabled ? Theme.primary : Theme.frame, icon: "",
            rows: [["days", Timers.daysText(a.days)], ["next", a.enabled ? Timers.whenText(a.next) : "off"]],
            keys: "enter on / off · shift+enter delete"
        }));
    }

    function alarmRows(rest) {
        if (rest === "") {
            const list = alarmList();
            return list.length > 0 ? list : [info("no alarms yet", "a laundry 10:00 m-f · a gym 7:30 m,w,f · a call 18:00 tu,th")];
        }
        const parsed = parseAlarm(rest);
        if (parsed.error)
            return [info(parsed.error, "days: m tu w th f sa su, ranges m-f, lists m,w,f, daily, weekdays, weekend")].concat(alarmList());
        const next = Timers.nextOccurrence(parsed.hour, parsed.minute, parsed.days, Date.now());
        return [{
            kind: "alarm-new", parsed,
            title: `alarm ${Timers.clock(parsed.hour, parsed.minute)}${parsed.label !== "" ? ` · ${parsed.label}` : ""}`,
            desc: `${Timers.daysText(parsed.days)} · first ${Timers.whenText(next)}`,
            category: "alarm", glyph: "⏰", tint: Theme.primary, icon: "",
            rows: [["time", Timers.clock(parsed.hour, parsed.minute)], ["days", Timers.daysText(parsed.days)], ["label", parsed.label || "–"],
                ["snooze", `${Config.snoozeMinutes} min`]]
        }].concat(alarmList());
    }

    // ── # emoji ──────────────────────────────────────────────

    function emojiRows(rest) {
        if (!Emoji.available)
            return [info("no emoji list", "data/emoji.tsv is missing from the shell folder (facet update quickshell)")];
        const list = Emoji.search(rest);
        if (list.length === 0)
            return [info(rest === "" ? "type to search emoji" : "no emoji found", "# heart · # thumbs up · # cat")];
        return list.map(e => ({
            kind: "emoji", char: e.char,
            title: e.name, desc: e.group.replace(/-/g, " "),
            category: e.char, glyph: e.char, tint: Theme.surface2, icon: "",
            rows: [["emoji", e.char], ["group", e.group]],
            keys: "enter copy · shift+enter type it"
        }));
    }

    // ── / files ──────────────────────────────────────────────

    function fileIcon(name, isDir) {
        if (isDir)
            return "folder";
        const ext = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1).toLowerCase() : "";
        const groups = [
            [["png", "jpg", "jpeg", "webp", "gif", "svg", "avif"], "image-x-generic"],
            [["mp4", "mkv", "webm", "mov", "avi"], "video-x-generic"],
            [["mp3", "flac", "ogg", "opus", "wav", "m4a"], "audio-x-generic"],
            [["pdf"], "application-pdf"],
            [["zip", "tar", "gz", "xz", "zst", "7z", "rar"], "package-x-generic"],
            [["sh", "fish", "py", "js", "ts", "qml", "lua", "rs", "go", "c", "cpp"], "text-x-script"]
        ];
        for (const [exts, icon] of groups)
            if (exts.includes(ext))
                return icon;
        return "text-x-generic";
    }

    function fileRows(rest) {
        if (rest === "")
            return [info("type a file or folder name", "/ notes · / dev notes (only under a path with dev)")];
        if (Files.query !== rest || (Files.searching && Files.results.length === 0))
            return [info("searching …")];
        if (Files.results.length === 0)
            return [info("nothing found", "hidden and git-ignored files are skipped")];
        return Files.results.map(f => {
            const ext = f.isDir || !f.name.includes(".") ? "" : f.name.slice(f.name.lastIndexOf(".") + 1).toLowerCase();
            // Pictures show themselves, text files their first lines (in the info pane)
            const picture = ["png", "jpg", "jpeg", "webp", "gif", "svg", "avif", "bmp"].includes(ext);
            const text = !f.isDir && (ext === "" || ["txt", "md", "json", "toml", "yaml", "yml", "conf", "ini", "cfg", "log", "csv",
                "sh", "fish", "py", "js", "ts", "qml", "lua", "rs", "go", "c", "h", "cpp", "css", "html", "xml", "nix", "env"].includes(ext));
            // Videos and PDFs get a thumbnail made when selected (ffmpegthumbnailer, pdftoppm)
            const video = ["mp4", "mkv", "webm", "mov", "avi", "m4v"].includes(ext);
            const pdf = ext === "pdf";
            return {
                kind: "file", file: f,
                title: f.name, desc: Files.pretty(f.dir),
                category: f.isDir ? "folder" : "file", glyph: f.isDir ? "/" : "·", tint: Theme.secondary,
                icon: picture ? f.path : fileIcon(f.name, f.isDir),
                preview: picture ? f.path : "",
                textPreview: text ? f.path : "",
                thumbSource: video ? f.path : "", pdfSource: pdf ? f.path : "",
                rows: [["path", Files.pretty(f.path)]],
                keys: "enter open · shift+enter terminal here"
            };
        });
    }

    // ── ssh ──────────────────────────────────────────────────

    function sshRows(rest) {
        const found = SshHosts.hosts
            .map(h => ({ h, match: rest === "" ? { score: 0, idx: [] } : Apps.fuzzy(h.name, rest) }))
            .filter(x => x.match)
            .sort((a, b) => b.match.score - a.match.score)
            .map(({ h, match }) => ({
                kind: "ssh", host: h.name,
                title: h.name, markup: markup(h.name, match.idx),
                desc: [h.user !== "" ? `${h.user}@` : "", h.hostname || h.name, h.port !== "" ? `:${h.port}` : ""].join(""),
                category: "ssh", glyph: ">", tint: Theme.ok, icon: "",
                rows: [["host", h.hostname || h.name], ["user", h.user || "–"], ["port", h.port || "22"]],
                keys: "enter connect in ghostty · shift+enter copy command"
            }));
        if (rest !== "" && !SshHosts.hosts.some(h => h.name === rest))
            found.push({
                kind: "ssh", host: rest, title: `ssh ${rest}`, desc: "not in ~/.ssh/config",
                category: "ssh", glyph: ">", tint: Theme.frame, icon: "", rows: [["runs", `ssh ${rest}`]],
                keys: "enter connect in ghostty · shift+enter copy command"
            });
        return found.length > 0 ? found : [info("no hosts in ~/.ssh/config", "type user@host to connect anyway")];
    }

    // ── ; clipboard ──────────────────────────────────────────

    function clipRows(rest) {
        if (!Clipboard.loaded)
            return [info("reading clipboard history …", "from frame-clip")];
        const q = rest.toLowerCase();
        const list = Clipboard.entries.filter(e => q === "" || e.text.toLowerCase().includes(q)).slice(0, 60);
        if (list.length === 0)
            return [info(Clipboard.entries.length === 0 ? "clipboard history is empty" : "no match")];
        return list.map(e => {
            const lines = e.text.split("\n");
            return {
                kind: "clip", entry: e,
                title: e.image ? `image · ${e.text}` : lines[0].trim() || "(blank)",
                desc: e.image ? "picture" : lines.length > 1 ? `${lines.length} lines` : `${e.text.length} characters`,
                category: e.image ? "image" : "text", glyph: e.image ? "▣" : "¶", tint: Theme.secondary, icon: e.preview,
                body: e.image ? "" : e.text.slice(0, 700),
                preview: e.preview,
                rows: [],
                keys: "enter copy · shift+enter delete from history"
            };
        });
    }

    // ── ? web ────────────────────────────────────────────────

    function webRow(key, text) {
        const [name, template] = Config.searchEngines[key];
        const url = template.replace("%s", encodeURIComponent(text));
        return {
            kind: "web", url,
            title: `${name}: ${text}`, desc: url,
            category: key, glyph: name.charAt(0), tint: key === Config.searchDefault ? Theme.primary : Theme.frame, icon: "",
            rows: [["engine", name], ["shortcut", `? ${key} …`]],
            keys: "enter open in the browser"
        };
    }

    function webRows(rest) {
        const keys = Object.keys(Config.searchEngines);
        const words = rest.split(/\s+/);
        if (rest === "" || (words.length === 1 && keys.includes(words[0])))
            return keys.map(k => ({
                kind: "web-engine", key: k,
                title: `${k} · ${Config.searchEngines[k][0]}`, desc: k === Config.searchDefault ? "used without a shortcut" : "",
                category: "web", glyph: Config.searchEngines[k][0].charAt(0), tint: Theme.frame, icon: "", rows: [],
                keys: "enter pick this engine"
            })).sort((a, b) => (b.key === words[0]) - (a.key === words[0]));
        if (keys.includes(words[0]))
            return [webRow(words[0], words.slice(1).join(" "))];
        const fallback = keys.includes(Config.searchDefault) ? Config.searchDefault : keys[0];
        return [webRow(fallback, rest)].concat(keys.filter(k => k !== fallback).map(k => webRow(k, rest)));
    }

    // ── c: Claude ────────────────────────────────────────────

    function claudeRows(rest) {
        if (rest === "")
            return [info("ask Claude something", "a short answer from claude -p; nothing is sent before Enter")];
        const asked = Claude.question === rest;
        const answered = asked && Claude.answer !== "";
        return [{
            kind: "claude", question: rest, answered,
            title: rest,
            desc: !asked ? "enter asks Claude" : Claude.busy ? "thinking …" : Claude.error !== "" ? Claude.error : "",
            category: "claude", glyph: "c", tint: Theme.accent, icon: "",
            body: answered ? Claude.answer : "",
            rows: [["model", Config.claudeModel || "cli default"]],
            keys: answered ? "ctrl+c copy · enter copy & close · ↑↓ scroll · esc close" : asked && Claude.busy ? "esc close · the answer waits here" : "enter ask"
        }];
    }

    // ── Enter ────────────────────────────────────────────────

    // Returns what the launcher should do next: { close }, { arm: name } or { query: text }
    function activate(r, shift, armed) {
        const close = { close: true }, stay = { close: false };
        switch (r.kind) {
        case "app":
            // A running app comes to the current view; shift starts another
            Apps.launch(r.entry, shift);
            return close;
        case "calc":
            if (r.value === null)
                return stay;
            copy(r.value);
            return close;
        case "run":
            if (r.command === "")
                return stay;
            run(["ghostty", "-e", "fish", "-c", `${r.command}; exec fish`]);
            return close;
        case "power":
            if (r.name !== "lock" && armed !== r.name)
                return { close: false, arm: r.name };
            run(r.command);
            return close;
        case "spotify-control":
            Spotify.control(r.action, r.seconds);
            return close;
        case "spotify-item":
            Spotify.play(r.item.uri, shift && r.item.kind === "track");
            return close;
        case "discord-open":
            // Groups have no user, the channel is what gets opened or called
            DiscordBridge.send({ cmd: shift ? "call_user" : "open_dm", userId: r.contact.userId, channelId: r.contact.channelId });
            DiscordBridge.focusWindow();
            return close;
        case "discord-call":
            DiscordBridge.send({ cmd: "call_user", userId: r.contact.userId, channelId: r.contact.channelId });
            DiscordBridge.focusWindow();
            return close;
        case "discord-send":
            if (r.content === "")
                return stay;
            DiscordBridge.send({ cmd: "send_dm", userId: r.contact.userId, content: r.content, channelId: r.contact.channelId });
            return close;
        case "discord-reply":
            if (r.content === "")
                return stay;
            DiscordBridge.send({ cmd: "reply_last", content: r.content });
            return close;
        case "timer-start":
            Timers.addTimer(r.seconds, r.label);
            return close;
        case "timer-running":
            Timers.cancelTimer(r.timer.id);
            return stay;
        case "alarm-new":
            Timers.addAlarm(r.parsed.hour, r.parsed.minute, r.parsed.days, r.parsed.label);
            return close;
        case "alarm":
            if (shift)
                Timers.removeAlarm(r.alarm.id);
            else
                Timers.toggleAlarm(r.alarm.id);
            return stay;
        case "emoji":
            Emoji.used(r.char);
            if (shift)
                // Pasted into the window that gets focus back once the launcher is gone: into
                // the clipboard, then Hyprland presses Ctrl+V there (Ctrl+Shift+V in terminals)
                run(["sh", "-c", 'printf "%s" "$0" | wl-copy; sleep 0.25; '
                    + 'case "$(hyprctl activewindow | sed -n "s/^[[:space:]]*class: //p")" in '
                    + '*ghostty*|*kitty*|*foot*|*Alacritty*|*wezterm*|*konsole*) mods="CTRL SHIFT" ;; *) mods="CTRL" ;; esac; '
                    + 'hyprctl dispatch "hl.dsp.exec_raw(\\"sendshortcut\\", \\"$mods, V, activewindow\\")"', r.char]);
            else
                copy(r.char);
            return close;
        case "file":
            if (shift)
                run(["ghostty", `--working-directory=${r.file.isDir ? r.file.path : r.file.dir}`]);
            else
                run(["xdg-open", r.file.path]);
            return close;
        case "ssh":
            if (shift)
                copy(`ssh ${r.host}`);
            else
                run(["ghostty", "-e", "ssh", r.host]);
            return close;
        case "clip":
            if (shift) {
                Clipboard.remove(r.entry);
                return stay;
            }
            Clipboard.copy(r.entry);
            return close;
        case "web":
            run(["xdg-open", r.url]);
            return close;
        case "web-engine":
            return { close: false, query: `? ${r.key} ` };
        case "claude":
            if (r.answered) {
                copy(Claude.answer);
                return close;
            }
            Claude.ask(r.question);
            return stay;
        default:
            return stay;
        }
    }

    // ── Side effects of typing ───────────────────────────────

    // A new mode was picked: fetch what it lists
    function modeEntered(mode) {
        if (mode === "s")
            Spotify.refresh();
        else if (mode === "d")
            DiscordBridge.refreshContacts();
        else if (mode === ";")
            Clipboard.refresh();
    }

    // The query changed inside a mode that searches in the background
    function queryChanged(mode, rest) {
        if (mode === "s")
            Spotify.search(spotifySearchText(rest));
        else if (mode === "/")
            Files.search(rest);
    }
}
