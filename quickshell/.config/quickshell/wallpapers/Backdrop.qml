import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.config

// Still wallpapers and the plain background, drawn by the shell on the background layer
// (swaybg did this before). frame-wallpaper still owns the state and runs the moving ones,
// mpvpaper and linux-wallpaperengine; a screen showing one of those gets no window from
// here, so the video is never covered.
//
// State: ~/.local/state/frameshell/wallpaper.json
//   { backend: "both" | "mpv" | "image", scaling: "fill" | "fit",
//     screens: { "<monitor>" | "*": { path, kind: "image" | "video" | "scene" | … } } }
Scope {
    id: root

    property var state: ({ backend: "both", scaling: "fill", screens: {} })
    // After the first read: only a change made while the shell runs holds the old picture
    property bool ready: false

    // frame-wallpaper ended a switch: "up" (the new backend draws), "died" or "timeout"
    signal switched(string outcome)

    // Workshop items are folders, files have an extension
    function isFolder(path) {
        return !/\.[A-Za-z0-9]{2,5}$/.test(path);
    }

    // What the backend runs itself (mirrors allowed() in frame-wallpaper)
    function moving(entry) {
        const backend = state.backend ?? "both";
        if (entry.kind === "image")
            return false;
        if (backend === "both")
            return entry.kind === "scene" || entry.kind === "video";
        if (backend === "mpv")
            return entry.kind === "video" && !isFolder(entry.path);
        return false;
    }

    // The picture for a screen ("" = just the background color), or null when a backend
    // draws that screen
    function shownOn(name) {
        const screens = state.screens ?? {};
        const entry = screens[name] ?? screens["*"] ?? null;
        if (!entry || !entry.path)
            return "";
        if (moving(entry))
            return null;
        return entry.kind === "image" ? entry.path : "";
    }

    FileView {
        path: `${Quickshell.env("HOME")}/.local/state/frameshell/wallpaper.json`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.state = Object.assign({ backend: "both", scaling: "fill", screens: {} }, JSON.parse(text()));
                root.ready = true;
            } catch (e) {
                // Half written; the next change brings a whole file
            }
        }
    }

    // "<ticket> <outcome>", written by frame-wallpaper once a switch has ended
    FileView {
        path: `${Quickshell.env("HOME")}/.local/state/frameshell/wallpaper.shown`
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.switched(text().trim().split(" ")[1] ?? "")
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: backdrop

            required property ShellScreen modelData
            readonly property var picture: root.shownOn(modelData.name)
            // A scene or video that replaces the picture needs seconds for its first frame;
            // the picture stays up until then (the backend's layer is newer, so it comes on
            // top of this one), and for good when the backend fails. Without this the screen
            // showed the bare compositor background while the scene loaded. Set only from the
            // handlers, not bound: a binding would drop the picture before it is held.
            property string last: ""
            property bool shown: false
            property bool holding: false

            Component.onCompleted: {
                last = picture ?? "";
                shown = picture !== null;
            }

            onPictureChanged: {
                if (picture !== null) {
                    last = picture;
                    holding = false;
                } else {
                    holding = shown && root.ready;
                    if (holding)
                        holdEnd.restart();
                }
                shown = picture !== null;
            }

            visible: picture !== null || holding
            screen: modelData
            color: Theme.bg
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "qs-wallpaper"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            Connections {
                target: root
                function onSwitched(outcome) {
                    if (backdrop.holding && outcome === "up")
                        backdrop.holding = false;
                    else if (backdrop.holding)
                        holdEnd.stop();
                }
            }

            // In case the end of the switch is never reported (frame-wallpaper waits 30 s at most)
            Timer {
                id: holdEnd
                interval: 32000
                onTriggered: backdrop.holding = false
            }

            Image {
                anchors.fill: parent
                source: backdrop.last !== "" ? "file://" + backdrop.last.split("/").map(encodeURIComponent).join("/") : ""
                fillMode: root.state.scaling === "fit" ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                // Decoded at screen size: an 8K picture would otherwise sit in memory whole
                sourceSize.width: backdrop.width * (backdrop.modelData.devicePixelRatio || 1)
                sourceSize.height: backdrop.height * (backdrop.modelData.devicePixelRatio || 1)
                asynchronous: true
                cache: false
                smooth: true
                // A new picture fades in over the background color
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.anim.normal } }
            }
        }
    }
}
