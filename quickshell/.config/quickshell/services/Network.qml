pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The connection that carries traffic, for the bar and the control center: cable, Wi-Fi or
// none, its name and the Wi-Fi signal. From NetworkManager through nmcli (CachyOS ships both);
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

    function refresh() {
        devices.running = true;
    }

    // "TYPE:STATE:CONNECTION" lines of `nmcli -t`; only the name can hold an (escaped) colon
    function parse(text) {
        const found = { ethernet: "", wifi: "" };
        for (const line of text.split("\n")) {
            const first = line.indexOf(":");
            const second = line.indexOf(":", first + 1);
            if (first < 0 || second < 0)
                continue;
            const kind = line.slice(0, first);
            const state = line.slice(first + 1, second);
            const conn = line.slice(second + 1).replace(/\\:/g, ":");
            if ((kind === "ethernet" || kind === "wifi") && state.startsWith("connected") && found[kind] === "")
                found[kind] = conn || kind;
        }
        // A cable wins: with both up, the traffic goes over it
        type = found.ethernet !== "" ? "ethernet" : found.wifi !== "" ? "wifi" : "";
        name = type === "" ? "" : found[type];
        if (type === "wifi")
            wifiSignal.running = true;
        else
            strength = -1;
    }

    Process {
        id: devices
        running: true
        command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"]
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
        onTriggered: root.refresh()
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
