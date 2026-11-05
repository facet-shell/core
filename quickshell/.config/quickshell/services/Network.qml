pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The connection that carries traffic, for the bar and the control center: cable, Wi-Fi or
// none, its name and the Wi-Fi signal; and the Wi-Fi networks around, for the control
// center's Wi-Fi page. From NetworkManager through nmcli (CachyOS ships both);
// `nmcli monitor` says when something changed, so only the Wi-Fi signal is polled.
Singleton {
    id: root

    // false: no nmcli (or NetworkManager is not running); type stays "" then
    property bool available: true
    // "ethernet", "wifi" or "" (offline)
    property string type: ""
    // The connection's name, e.g. "Wired connection 1" or the Wi-Fi network
    property string name: ""
    // Wi-Fi signal 0..100, -1 on a cable or offline
    property int strength: -1
    readonly property bool online: type !== ""

    // ── Wi-Fi networks ───────────────────────────────────────

    // The Wi-Fi interface ("wlan0"), "" on a machine without one (a desktop on a cable);
    // known even while the radio is off
    property string wifiDevice: ""
    readonly property bool wifiAvailable: wifiDevice !== ""
    // [{ ssid, strength, security, secured, inUse }]: the connected one first, then by
    // signal; one entry per SSID (a network with several access points shows once).
    // Filled by scan(), empty until then.
    property var networks: []
    // The names of the saved Wi-Fi connections (NetworkManager names them after the SSID)
    property var knownNetworks: []
    // True while the list is being read
    property bool scanning: false
    // The SSID a connect runs for, "" otherwise
    property string connecting: ""
    // nmcli's message when the last connect failed and the network it was for; both ""
    // once a new attempt starts
    property string connectError: ""
    property string connectErrorSsid: ""
    // True while the Wi-Fi page is open: NetworkManager's events refresh the list too
    property bool wifiWatched: false

    function refresh() {
        devices.running = true;
    }

    // The networks around; rescan is "no" (NetworkManager's cache), "auto" (it decides) or
    // "yes" (the page's rescan button). Nothing without NetworkManager or a Wi-Fi device.
    function scan(rescan = "auto") {
        if (!available || !wifiAvailable || wifiList.running)
            return;
        wifiList.command = ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE", "device", "wifi", "list", "--rescan", rescan];
        wifiList.running = true;
        saved.running = true;
    }

    function isKnown(ssid) {
        return knownNetworks.includes(ssid);
    }

    // Connect to a network; a saved one needs no password, a new secured one does. The
    // result comes back through connecting / connectError, and the list refreshes.
    function connectWifi(ssid, password = "") {
        if (ssid === "" || wifiConnect.running)
            return;
        connecting = ssid;
        connectError = "";
        connectErrorSsid = "";
        wifiConnect.command = ["nmcli", "device", "wifi", "connect", ssid].concat(password !== "" ? ["password", password] : []);
        wifiConnect.running = true;
    }

    // Takes the Wi-Fi device down from its network; NetworkManager leaves it alone until
    // the next connect
    function disconnectWifi() {
        if (wifiDevice !== "")
            Quickshell.execDetached(["nmcli", "device", "disconnect", wifiDevice]);
    }

    // The fields of one `nmcli -t` line: values are split by ":", a colon inside a value
    // comes escaped as "\:" (and a backslash as "\\")
    function fields(line) {
        const out = [];
        let value = "";
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (c === "\\" && i + 1 < line.length)
                value += line[++i];
            else if (c === ":") {
                out.push(value);
                value = "";
            } else
                value += c;
        }
        out.push(value);
        return out;
    }

    // "DEVICE:TYPE:STATE:CONNECTION" lines; only the name can hold a colon
    function parse(text) {
        const found = { ethernet: "", wifi: "" };
        let iface = "";
        for (const line of text.split("\n")) {
            const f = fields(line);
            if (f.length < 4)
                continue;
            const dev = f[0], kind = f[1], state = f[2], conn = f[3];
            if (kind === "wifi" && iface === "")
                iface = dev;
            if ((kind === "ethernet" || kind === "wifi") && state.startsWith("connected") && found[kind] === "")
                found[kind] = conn || kind;
        }
        wifiDevice = iface;
        // A cable wins: with both up, the traffic goes over it
        type = found.ethernet !== "" ? "ethernet" : found.wifi !== "" ? "wifi" : "";
        name = type === "" ? "" : found[type];
        if (type === "wifi")
            wifiSignal.running = true;
        else
            strength = -1;
    }

    // "SSID:SIGNAL:SECURITY:IN-USE" lines; the in-use one has "*". Hidden networks (no SSID)
    // are left out; of several access points with one SSID the in-use or strongest stays.
    function parseNetworks(text) {
        const bySsid = {};
        for (const line of text.split("\n")) {
            const f = fields(line);
            if (f.length < 4 || f[0] === "")
                continue;
            const security = f[2].trim();
            const entry = {
                ssid: f[0],
                strength: Number(f[1]) || 0,
                security,
                secured: security !== "" && security !== "--",
                inUse: f[3].trim() === "*"
            };
            const seen = bySsid[entry.ssid];
            if (!seen || entry.inUse || (!seen.inUse && entry.strength > seen.strength))
                bySsid[entry.ssid] = entry;
        }
        const list = Object.values(bySsid);
        list.sort((a, b) => (b.inUse ? 1 : 0) - (a.inUse ? 1 : 0) || b.strength - a.strength);
        networks = list;
    }

    Process {
        id: devices
        running: true
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
        onExited: code => root.available = code === 0
    }

    // The active Wi-Fi network's line starts with "*"
    Process {
        id: wifiSignal
        command: ["nmcli", "-t", "-f", "IN-USE,SIGNAL", "device", "wifi", "list", "--rescan", "no"]
        stdout: StdioCollector {
            onStreamFinished: {
                const line = this.text.split("\n").find(l => l.startsWith("*:"));
                root.strength = line ? Number(line.slice(2)) || 0 : -1;
            }
        }
    }

    Process {
        id: wifiList
        stdout: StdioCollector {
            onStreamFinished: root.parseNetworks(this.text)
        }
        onRunningChanged: root.scanning = running
    }

    // "NAME:TYPE" of every saved connection; the Wi-Fi ones are 802-11-wireless
    Process {
        id: saved
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: root.knownNetworks = this.text.split("\n").map(l => root.fields(l)).filter(f => f.length >= 2 && f[1] === "802-11-wireless").map(f => f[0])
        }
    }

    // nmcli says why on stderr ("Error: Connection activation failed: (7) Secrets were
    // required, but not provided."); the Wi-Fi page reads that
    Process {
        id: wifiConnect
        stderr: StdioCollector {
            id: connectErrors
        }
        onExited: code => {
            const ssid = root.connecting;
            root.connecting = "";
            if (code !== 0) {
                root.connectErrorSsid = ssid;
                root.connectError = connectErrors.text.trim().replace(/^Error:\s*/, "") || `nmcli failed (${code})`;
            }
            root.refresh();
            root.scan("no");
        }
    }

    // Every change NetworkManager reports; a burst of lines is one refresh
    Process {
        id: monitor
        running: root.available
        command: ["nmcli", "monitor"]
        stdout: SplitParser {
            onRead: settle.restart()
        }
        // NetworkManager restarted: listen again a little later
        onExited: if (root.available) again.restart()
    }

    Timer {
        id: settle
        interval: 300
        onTriggered: {
            root.refresh();
            // The cached list only: a scan here would report new access points, and that
            // would scan again
            if (root.wifiWatched)
                root.scan("no");
        }
    }

    Timer {
        id: again
        interval: 10000
        onTriggered: {
            monitor.running = true;
            root.refresh();
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.type === "wifi"
        onTriggered: wifiSignal.running = true
    }
}
