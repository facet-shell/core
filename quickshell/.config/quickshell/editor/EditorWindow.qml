import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.services

// The editor as its own window, for a video (EditorView: cuts, blur boxes, pictures, levels per
// channel) or a picture (ImageEditorView: blur boxes, pictures, drawing, crop). Opened through
// the Editor service: "edit" on a notification, the media app, or `qs ipc call editor open <file>`;
// `qs ipc call editor paint` (or paintOn white|clear) opens an empty page.
// The views come in through a Loader, so without Qt Multimedia (qt6-multimedia-ffmpeg) only
// the video editor is missing and it says so.
Scope {
    id: root

    property bool open: false
    property string file: ""
    readonly property string view: Editor.isVideo(file) ? "EditorView.qml" : "ImageEditorView.qml"

    function openFile(path) {
        if (path === "")
            return;
        if (loader.item)
            loader.item.project.writeNow();
        file = path;
        open = true;
        // The same kind of view takes the new file; the other kind loads with it
        if (loader.item && loader.source.toString().endsWith(view))
            loader.item.openFile(path);
    }

    function hide() {
        if (loader.item) {
            loader.item.pause();
            loader.item.project.writeNow();
        }
        open = false;
    }

    Connections {
        target: Editor

        function onOpenRequested(file) {
            root.openFile(file);
        }
    }

    FloatingWindow {
        id: window

        visible: root.open
        title: Editor.isVideo(root.file) ? "frameshell · video editor"
            : root.file.includes("/paintings/") ? "frameshell · paint" : "frameshell · picture editor"
        implicitWidth: 1480
        implicitHeight: 940
        color: Theme.bg

        // Closed from Hyprland (Super+Q) instead of the close button
        onVisibleChanged: {
            if (!visible && root.open)
                root.hide();
        }

        Loader {
            id: loader

            anchors.fill: parent
            active: root.open
            source: root.view
            onLoaded: {
                item.closeRequested.connect(root.hide);
                item.openFile(root.file);
            }
            onStatusChanged: {
                if (status !== Loader.Error)
                    return;
                root.open = false;
                Notifications.push({
                    app: "editor",
                    glyph: "✗",
                    title: "the editor did not start",
                    body: Editor.isVideo(root.file)
                        ? "videos need Qt Multimedia: sudo pacman -S qt6-multimedia-ffmpeg"
                        : "see qs log for the error"
                });
            }
        }
    }

    IpcHandler {
        target: "editor"

        function open(path: string): void {
            Editor.open(path);
        }

        // Paint: an empty page in the theme's background (`new` is a word JavaScript keeps)
        function paint(): void {
            Editor.newPicture("theme");
        }

        // paper: theme, white or clear
        function paintOn(paper: string): void {
            Editor.newPicture(paper);
        }

        function close(): void {
            root.hide();
        }
    }
}
