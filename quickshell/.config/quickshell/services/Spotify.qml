pragma Singleton

import QtQuick
import QtWebSockets
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.config

// Spotify for the launcher (s mode): search, play, queue and the player controls.
//
// Three ways to reach Spotify, tried in this order:
//   1. the Spicetify extension (spicetify/.config/spicetify/Extensions/frameshell.js),
//      which connects to the WebSocket below; search and play happen inside the client
//   2. frame-spotify, the Web API helper with your own developer app (docs/spotify.md)
//   3. MPRIS: controls and playing a spotify: link work without either of the above
// Non-Spotify players (browser, mpv) are controlled over MPRIS when Spotify is not running.
//
// The extension proves itself with the token `facet install spicetify` writes to
// ~/.local/state/frameshell/spotify-bridge.token, so a web page that connects to the
// port cannot pose as Spotify and read what you search.
//
// results: [{ kind: "track" | "artist" | "album" | "playlist", uri, title, subtitle, image, length }]
Singleton {
    id: root

    readonly property string stateDir: `${Quickshell.env("HOME")}/.local/state/frameshell`
    readonly property string helper: `${Quickshell.env("HOME")}/.local/bin/frame-spotify`

    // The extension's socket after a valid hello, otherwise null
    property var socket: null
    readonly property bool bridged: socket !== null
    // frame-spotify is logged in
    property bool apiReady: false
    property string token: ""

    property string query: ""
    property var results: []
    property bool searching: false
    property string error: ""
    // Where the results came from (searchModalResults, web api, …), for the info pane
    property string source: ""

    property int nextId: 1
    property var pending: ({})

    readonly property MprisPlayer spotifyPlayer: Mpris.players.values.find(p => p.identity === "Spotify") ?? null
    // True while the media card under the bar is open: song changes made there need no popup
    property bool cardOpen: false
    // Spotify's own window has the focus: the song is right there, so no popup either
    readonly property bool windowFocused: (ToplevelManager.activeToplevel?.appId ?? "").toLowerCase() === "spotify"
    // What the controls act on when Spotify is not there
    readonly property MprisPlayer otherPlayer: {
        const list = Mpris.players.values;
        return list.find(p => p.isPlaying) ?? list[0] ?? null;
    }
    readonly property bool canSearch: bridged || apiReady

    // How Spotify is reached right now, for the launcher
    readonly property string via: bridged ? "spotify client" : apiReady ? "web api" : spotifyPlayer ? "mpris" : "not connected"

    // ── Search ───────────────────────────────────────────────

    function search(text) {
        const q = text.trim();
        if (q === query)
            return;
        query = q;
        error = "";
        if (q === "") {
            results = [];
            searching = false;
            debounce.stop();
            return;
        }
        searching = true;
        debounce.restart();
    }

    function runSearch(q) {
        const done = (ok, data, how) => {
            if (q !== query)
                return;
            searching = false;
            if (ok) {
                results = data;
                source = how;
                error = "";
            } else {
                results = [];
                error = data;
            }
        };
        const viaHelper = () => helperCall(["search", q], (ok, out) => {
            if (!ok)
                return done(false, out || "search failed");
            try {
                done(true, JSON.parse(out), "web api");
            } catch (e) {
                done(false, "frame-spotify sent something odd");
            }
        });
        if (bridged)
            request({ cmd: "search", query: q }, (ok, data) => {
                if (ok && data?.debug)
                    console.warn(`spotify: the client found nothing for "${q}": ${JSON.stringify(data.debug)}`);
                if (ok)
                    done(true, data.items ?? [], data.source ?? "spotify client");
                else if (apiReady)
                    viaHelper();
                else
                    done(false, data);
            });
        else if (apiReady)
            viaHelper();
        else if (spotifyPlayer && !waitedForBridge) {
            // Spotify runs but its extension has not (re)connected yet; it retries every
            // few seconds, so give it one moment before giving up
            waitedForBridge = true;
            bridgeWait.restart();
        } else
            done(false, spotifyPlayer
                ? "Spotify runs, but the Spicetify extension is not connected (facet install spicetify, then restart Spotify)"
                : "Spotify is not running");
    }

    property bool waitedForBridge: false
    Timer {
        id: bridgeWait
        interval: 3500
        onTriggered: {
            if (root.query !== "")
                root.runSearch(root.query);
        }
    }
    onBridgedChanged: if (bridged) waitedForBridge = false

    // ── Playback ─────────────────────────────────────────────

    function play(uri, queue) {
        if (bridged)
            return request({ cmd: "play", uri, queue: !!queue }, (ok, data) => ok || fail(data));
        if (apiReady)
            return helperCall([queue ? "queue" : "play", uri], (ok, out) => ok || fail(out));
        if (!queue && spotifyPlayer)
            return spotifyPlayer.openUri(uri);
        fail(queue ? "queueing needs the Spicetify extension or the Web API" : "Spotify is not running");
    }

    // action: play pause toggle next prev forward back jump shuffle repeat like
    function control(action, seconds) {
        if (bridged)
            return request({ cmd: "control", action, seconds: seconds ?? 0 }, (ok, data) => ok || fail(data));
        if (spotifyPlayer && action !== "like")
            return mpris(spotifyPlayer, action, seconds ?? 0);
        if (apiReady)
            return helperCall(["control", action, String(Math.round(seconds ?? 0))], (ok, out) => ok || fail(out));
        if (otherPlayer && action !== "like")
            return mpris(otherPlayer, action, seconds ?? 0);
        fail(action === "like" ? "liking needs the Spicetify extension or the Web API" : "no player found");
    }

    function mpris(player, action, seconds) {
        switch (action) {
        case "play": player.play(); break;
        case "pause": player.pause(); break;
        case "toggle": player.togglePlaying(); break;
        case "next": player.next(); break;
        case "prev": player.previous(); break;
        case "forward": player.seek(seconds); break;
        case "back": player.seek(-seconds); break;
        case "jump":
            if (player.canSeek && player.positionSupported)
                player.position = Math.min(seconds, player.length);
            break;
        case "shuffle":
            if (player.shuffleSupported)
                player.shuffle = !player.shuffle;
            break;
        case "repeat":
            if (player.loopSupported)
                player.loopState = player.loopState === MprisLoopState.None ? MprisLoopState.Playlist
                    : player.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None;
            break;
        }
    }

    function fail(message) {
        Notifications.push({
            app: "spotify",
            kind: "mini",
            logged: false,
            timeout: 4000,
            glyph: "✕",
            title: "spotify",
            body: String(message)
        });
        return false;
    }

    // Whether frame-spotify is logged in; checked again whenever the launcher asks
    function refresh() {
        statusCheck.running = true;
    }

    // ── Extension connection ─────────────────────────────────

    function request(payload, callback) {
        const id = nextId++;
        pending[id] = { callback, at: Date.now() };
        socket.sendTextMessage(JSON.stringify(Object.assign({ id }, payload)));
    }

    function receive(ws, message) {
        let msg;
        try {
            msg = JSON.parse(message);
        } catch (e) {
            return;
        }
        if (msg.hello === "frameshell") {
            if (token === "" || msg.token !== token) {
                console.warn("spotify: extension sent a wrong token, run `facet install spicetify` again");
                ws.active = false;
                return;
            }
            if (socket && socket !== ws)
                socket.active = false;
            socket = ws;
            return;
        }
        if (ws !== socket || msg.id === undefined)
            return;
        const entry = pending[msg.id];
        delete pending[msg.id];
        if (entry)
            entry.callback(msg.ok, msg.ok ? msg.data : msg.error);
    }

    WebSocketServer {
        host: "127.0.0.1"
        port: Config.spotifyPort
        listen: true
        accept: true

        onClientConnected: ws => {
            ws.textMessageReceived.connect(message => root.receive(ws, message));
            ws.statusChanged.connect(() => {
                if (ws.status !== WebSocket.Open && root.socket === ws)
                    root.socket = null;
            });
        }
        onErrorStringChanged: if (errorString !== "") console.warn(`spotify: ${errorString}`)
    }

    FileView {
        path: `${root.stateDir}/spotify-bridge.token`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.token = text().trim()
    }

    // Requests the client never answered (closed mid-way, extension broken)
    Timer {
        interval: 1000
        repeat: true
        running: root.bridged
        onTriggered: {
            const now = Date.now();
            for (const id of Object.keys(root.pending)) {
                const entry = root.pending[id];
                if (now - entry.at > 5000) {
                    delete root.pending[id];
                    entry.callback(false, "the Spotify client did not answer");
                }
            }
        }
    }

    Timer {
        id: debounce
        interval: 250
        onTriggered: root.runSearch(root.query)
    }

    // ── frame-spotify ────────────────────────────────────────

    // callback(ok, output): stdout on success, the error message otherwise
    function helperCall(args, callback) {
        helperProcess.createObject(root, { args, callback });
    }

    Component {
        id: helperProcess

        Process {
            id: proc
            property var args: []
            property var callback: null

            // First line: exit code; the rest: what the helper printed
            command: ["sh", "-c", 'out=$("$0" "$@" 2>&1); printf "%s\\n%s" "$?" "$out"', root.helper].concat(args)
            running: true
            stdout: StdioCollector {
                onStreamFinished: {
                    const newline = text.indexOf("\n");
                    const code = newline < 0 ? text : text.slice(0, newline);
                    const out = newline < 0 ? "" : text.slice(newline + 1).trim();
                    if (proc.callback)
                        proc.callback(code === "0", code === "0" ? out : out.replace(/^frame-spotify: /, ""));
                    proc.destroy();
                }
            }
        }
    }

    Process {
        id: statusCheck
        command: ["sh", "-c", 'test -x "$0" && "$0" status --quiet', root.helper]
        running: true
        onExited: code => root.apiReady = code === 0
    }
}
