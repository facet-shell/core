pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Google and iCloud calendars through facet-calendar (~/.local/bin, standard-library Python).
// Accounts are set up once, in the settings app (Calendars, through connectIcloud() and
// connectGoogle() here) or in a terminal (facet-calendar setup icloud | google <client.json>);
// the passwords and tokens stay in the keyring, this only asks for a range of days and adds
// events. Nothing runs on its own: the dashboard calls load() for the weeks it shows.
Singleton {
    id: root

    // Hyprland starts qs with the system PATH only, so the helper goes by its full path
    readonly property string helper: `${Quickshell.env("HOME")}/.local/bin/facet-calendar`

    // -1 not asked yet, otherwise how many accounts are set up
    property int accounts: -1
    // [{ id, name, color, account, writable }]
    property var calendars: []
    readonly property var writable: calendars.filter(c => c.writable)
    // [{ id, title, start, end, allDay, calendar, color, location }]; start/end are local
    // "YYYY-MM-DDTHH:MM" or, all day, "YYYY-MM-DD" with the end day not included
    property var events: []
    // One line per account that failed (wrong password, offline)
    property var errors: []
    readonly property bool loading: fetch.running
    readonly property bool adding: addCall.running
    property string addError: ""
    // The range asked last ("from|to") and when, so reopening does not ask again
    property string range: ""
    property real fetchedAt: 0

    // from/to: "YYYY-MM-DD", to not included. force: also when asked less than five minutes ago
    function load(from, to, force) {
        const key = `${from}|${to}`;
        if (fetch.running || (!force && key === range && Date.now() - fetchedAt < 300000))
            return;
        range = key;
        fetch.command = [helper, "events", from, to];
        fetch.running = true;
    }

    function reload() {
        if (range !== "") {
            const [from, to] = range.split("|");
            load(from, to, true);
        }
    }

    // calendar: an id from calendars; start/end as the events have them, end may be ""
    function add(calendar, title, start, end) {
        if (addCall.running)
            return;
        addError = "";
        addCall.command = [helper, "add", calendar, title, start].concat(end ? [end] : []);
        addCall.running = true;
    }

    // ── Accounts (the settings app) ──

    // [{ key, kind, name, calendars, ok, error }] from `facet-calendar accounts --json`
    property var accountList: []
    readonly property bool checking: accountsCall.running
    // "" or the kind being connected ("icloud", "google"); the setup runs here, not in the
    // page, so leaving the page does not end a Google login waiting in the browser
    property string connecting: ""
    // The helper's last line while it works, the login address (Google), the error, the result
    property string connectStatus: ""
    property string connectUrl: ""
    property string connectError: ""
    property string connected: ""
    // The kind of the last setup, so each page shows only its own result
    property string lastKind: ""
    readonly property bool removing: removeCall.running
    property string removeError: ""

    // offline: only the list from the config, without asking each server
    function checkAccounts(offline) {
        if (accountsCall.running) {
            // A live check asked during an offline one runs after it
            if (!offline)
                accountsCall.again = true;
            return;
        }
        accountsCall.command = [helper, "accounts", "--json"].concat(offline ? ["--offline"] : []);
        accountsCall.running = true;
    }

    // The password goes over stdin, never on the command line
    function connectIcloud(appleId, password) {
        if (setupCall.running)
            return;
        startSetup("icloud", [helper, "setup", "icloud", "--apple-id", appleId.trim(), "--password-stdin"], password);
    }

    // client: the path of the client_secret JSON; the helper opens the browser itself
    function connectGoogle(client) {
        if (setupCall.running)
            return;
        startSetup("google", [helper, "setup", "google", client.trim().replace(/^~(?=\/)/, Quickshell.env("HOME"))], "");
    }

    function cancelConnect() {
        if (setupCall.running) {
            setupCall.cancelled = true;
            setupCall.running = false;
        }
    }

    function startSetup(kind, args, secret) {
        connecting = kind;
        lastKind = kind;
        connectStatus = "";
        connectUrl = "";
        connectError = "";
        connected = "";
        setupCall.errorText = "";
        setupCall.cancelled = false;
        setupCall.secret = secret;
        setupCall.stdinEnabled = secret !== "";
        setupCall.command = args;
        setupCall.running = true;
    }

    function removeAccount(key) {
        if (removeCall.running)
            return;
        removeError = "";
        removeCall.command = [helper, "remove", key];
        removeCall.running = true;
    }

    // After an account came or went: the list, and the dashboard's events
    function refreshAccounts() {
        checkAccounts(false);
        fetchedAt = 0;
        reload();
    }

    // The events touching one day ("YYYY-MM-DD"), all-day ones first
    function on(day) {
        return events.filter(e => {
            const s = e.start.slice(0, 10), en = e.end.slice(0, 10);
            return e.allDay ? s <= day && day < en : s <= day && (day < en || (day === en && e.end.slice(11) !== "00:00") || s === day);
        });
    }

    Process {
        id: fetch

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const out = JSON.parse(text);
                    root.accounts = out.accounts ?? 0;
                    root.calendars = out.calendars ?? [];
                    root.events = out.events ?? [];
                    root.errors = out.errors ?? [];
                    root.fetchedAt = Date.now();
                } catch (e) {
                    root.errors = [text.trim() === "" ? "facet-calendar gave no answer" : String(e)];
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "")
                    console.warn(`calendar: ${text.trim()}`);
            }
        }
        onExited: code => {
            if (code === 127)
                root.errors = ["facet-calendar is missing in ~/.local/bin"];
        }
    }

    Process {
        id: accountsCall

        property bool again: false

        onExited: {
            if (again) {
                again = false;
                Qt.callLater(() => root.checkAccounts(false));
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.accountList = JSON.parse(text);
                } catch (e) {
                    root.accountList = [];
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "")
                    console.warn(`calendar: ${text.trim()}`);
            }
        }
    }

    Process {
        id: setupCall

        property string secret: ""
        property string errorText: ""
        property bool cancelled: false

        // One line on stdin, then it is closed and forgotten
        onStarted: {
            if (stdinEnabled) {
                write(secret + "\n");
                secret = "";
                stdinEnabled = false;
            }
        }
        stdout: SplitParser {
            onRead: line => {
                if (/^https?:\/\//.test(line))
                    root.connectUrl = line.trim();
                else if (line.trim() !== "")
                    root.connectStatus = line.trim();
            }
        }
        stderr: SplitParser {
            onRead: line => {
                if (line.trim() !== "")
                    setupCall.errorText = line.trim().replace(/^facet-calendar: /, "");
            }
        }
        onExited: (code, status) => {
            secret = "";
            if (code === 0) {
                root.connected = root.connectStatus;
                root.refreshAccounts();
            } else if (cancelled) {
                root.connectError = "cancelled";
            } else {
                root.connectError = errorText || (code === 127 ? "facet-calendar is missing in ~/.local/bin" : `facet-calendar exited with ${code}`);
            }
            root.connecting = "";
            root.connectStatus = "";
            root.connectUrl = "";
        }
    }

    Process {
        id: removeCall

        stderr: StdioCollector {
            onStreamFinished: root.removeError = text.trim().replace(/^facet-calendar: /, "")
        }
        onExited: code => root.refreshAccounts()
    }

    Process {
        id: addCall

        stderr: StdioCollector {
            onStreamFinished: root.addError = text.trim().replace(/^facet-calendar: /, "")
        }
        onExited: code => {
            if (code === 0)
                root.reload();
            else if (root.addError === "")
                root.addError = `facet-calendar exited with ${code}`;
        }
    }
}
