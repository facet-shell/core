import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.components
import qs.config
import qs.services

// The media app's content: every screenshot and recording (plus folders dropped on it) as a
// grid, newest first. Click picks one, Ctrl+click more, Shift+click a run; double click opens
// it in the editor. "delete" moves the picked ones into the trash together with what belongs
// to them (a recording's .tracks folder, an .edit.json). Files: quickshell/.local/bin/frame-media.
FocusScope {
    id: root

    signal closeRequested()

    readonly property string tool: `${Quickshell.env("HOME")}/.local/bin/frame-media`
    property string picturesDir: `${Quickshell.env("HOME")}/Pictures`
    readonly property string shotsDir: `${picturesDir}/screenshots`
    // Paint's pages (Editor.newPicture)
    readonly property string paintDir: `${picturesDir}/paintings`
    readonly property var folders: [shotsDir, paintDir, Recorder.folder].concat(extraFolders)
    // "new picture" asks for the paper in place
    property bool choosePaper: false
    // Folders dropped on the app, kept in media.json
    property var extraFolders: []
    readonly property string thumbDir: `${Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache"}/frameshell/media`

    // Everything found: [{ path, name, kind, mtime, size, edited, tracks, duration, thumb }]
    property var all: []
    property string filter: "all"
    // path → true
    property var picked: ({})
    readonly property var pickedPaths: Object.keys(picked)
    property int anchorIndex: -1
    property bool confirmDelete: false
    property string status: ""
    // .edit.json files and .tracks folders whose picture or video is gone (frame-media leftovers)
    property var leftovers: []

    readonly property int columns: Math.max(2, Math.floor(grid.width / 300))

    function fileUrl(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    function fmtSize(bytes) {
        if (bytes >= 1e9)
            return `${(bytes / 1e9).toFixed(1)} GB`;
        if (bytes >= 1e6)
            return `${(bytes / 1e6).toFixed(1)} MB`;
        return `${Math.max(1, Math.round(bytes / 1e3))} KB`;
    }

    function fmtLength(s) {
        s = Math.round(s);
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    function matches(it) {
        return filter === "all" || (filter === "pictures" && it.kind === "image")
            || (filter === "videos" && it.kind === "video") || (filter === "edited" && it.edited);
    }

    function count(f) {
        return all.filter(it => f === "all" || (f === "pictures" && it.kind === "image") || (f === "videos" && it.kind === "video") || (f === "edited" && it.edited)).length;
    }

    function refresh() {
        if (listProc.running)
            return;
        listProc.command = [tool, "list"].concat(folders);
        listProc.running = true;
    }

    function rebuild() {
        shown.clear();
        for (const it of all)
            if (matches(it))
                shown.append(it);
        const keep = {};
        for (const p of pickedPaths)
            if (all.some(it => it.path === p))
                keep[p] = true;
        picked = keep;
        anchorIndex = -1;
    }

    onFilterChanged: rebuild()

    // ── Picking ──────────────────────────────────────────────

    function click(index, modifiers) {
        const path = shown.get(index).path;
        if (modifiers & Qt.ControlModifier) {
            const next = Object.assign({}, picked);
            if (next[path])
                delete next[path];
            else
                next[path] = true;
            picked = next;
            anchorIndex = index;
        } else if ((modifiers & Qt.ShiftModifier) && anchorIndex >= 0) {
            const next = {};
            for (let i = Math.min(anchorIndex, index); i <= Math.max(anchorIndex, index); i++)
                next[shown.get(i).path] = true;
            picked = next;
        } else {
            picked = { [path]: true };
            anchorIndex = index;
        }
        confirmDelete = false;
    }

    function pickAll() {
        const next = {};
        for (let i = 0; i < shown.count; i++)
            next[shown.get(i).path] = true;
        picked = next;
    }

    function pickedSize() {
        let s = 0;
        for (const it of all)
            if (picked[it.path])
                s += it.size;
        return s;
    }

    // ── Actions ──────────────────────────────────────────────

    function openPicked() {
        if (pickedPaths.length > 0)
            Editor.open(pickedPaths[0]);
    }

    // One picture goes in as the picture, anything else as files (chats take both)
    function copyPicked() {
        const paths = pickedPaths;
        if (paths.length === 0)
            return;
        if (paths.length === 1 && Editor.isImage(paths[0]))
            Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"', "frame-media", paths[0]]);
        else
            Quickshell.execDetached(["sh", "-c", 'for f in "$@"; do printf "file://%s\\n" "$f"; done | wl-copy --type text/uri-list', "frame-media"].concat(paths));
        status = paths.length === 1 ? "copied" : `${paths.length} files copied`;
    }

    function deletePicked() {
        if (pickedPaths.length === 0 || trashProc.running)
            return;
        trashProc.count = pickedPaths.length;
        trashProc.command = [tool, "trash"].concat(pickedPaths);
        trashProc.running = true;
        confirmDelete = false;
    }

    function addFolder(path) {
        const dir = path.replace(/\/+$/, "");
        if (dir === "" || folders.includes(dir))
            return;
        extraFolders = extraFolders.concat([dir]);
        store.setText(JSON.stringify({ folders: extraFolders }));
        refresh();
    }

    function removeFolder(dir) {
        extraFolders = extraFolders.filter(d => d !== dir);
        store.setText(JSON.stringify({ folders: extraFolders }));
        refresh();
    }

    Keys.onPressed: event => {
        const ctrl = event.modifiers & Qt.ControlModifier;
        if (event.key === Qt.Key_A && ctrl)
            pickAll();
        else if (event.key === Qt.Key_Delete)
            confirmDelete = pickedPaths.length > 0;
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            openPicked();
        else if (event.key === Qt.Key_C && ctrl)
            copyPicked();
        else if (event.key === Qt.Key_F5)
            refresh();
        else if (event.key === Qt.Key_Escape) {
            if (confirmDelete)
                confirmDelete = false;
            else if (pickedPaths.length > 0)
                picked = {};
            else
                root.closeRequested();
        } else
            return;
        event.accepted = true;
    }

    ListModel {
        id: shown
    }

    // ── Files ────────────────────────────────────────────────

    Process {
        id: listProc

        stdout: StdioCollector {
            onStreamFinished: {
                const old = {};
                for (const it of root.all)
                    old[it.path] = it;
                const next = [];
                for (const line of this.text.split("\n")) {
                    const f = line.split("\t");
                    if (f.length < 6)
                        continue;
                    const path = f[3];
                    const mtime = Number(f[0]);
                    const before = old[path];
                    next.push({
                        path,
                        name: path.slice(path.lastIndexOf("/") + 1),
                        kind: f[2],
                        mtime,
                        size: Number(f[1]),
                        edited: f[4] === "1",
                        tracks: f[5] === "1",
                        duration: before && before.mtime === mtime ? before.duration : 0,
                        thumb: before && before.mtime === mtime ? before.thumb : ""
                    });
                }
                root.all = next;
                root.rebuild();
                thumbs.queue = next.filter(it => it.kind === "video" && it.thumb === "").map(it => it.path);
                thumbs.next();
                leftoverProc.command = [root.tool, "leftovers"].concat(root.folders);
                leftoverProc.running = true;
            }
        }
    }

    // Video thumbnails (ffmpeg, cached by path and time) and lengths, one after another
    Process {
        id: thumbs

        property var queue: []
        property string path: ""
        property string file: ""

        function next() {
            if (running || queue.length === 0)
                return;
            path = queue[0];
            queue = queue.slice(1);
            const it = root.all.find(x => x.path === path);
            if (!it) {
                next();
                return;
            }
            file = `${root.thumbDir}/${Qt.md5(path + ":" + it.mtime)}.jpg`;
            command = [root.tool, "thumb", path, file];
            running = true;
        }

        stdout: StdioCollector {
            id: thumbOut
        }
        onExited: {
            const duration = Number(thumbOut.text.trim()) || 0;
            const it = root.all.find(x => x.path === path);
            if (it) {
                it.thumb = file;
                it.duration = duration;
                for (let i = 0; i < shown.count; i++) {
                    if (shown.get(i).path === path) {
                        shown.setProperty(i, "thumb", file);
                        shown.setProperty(i, "duration", duration);
                        break;
                    }
                }
            }
            next();
        }
    }

    Process {
        id: leftoverProc

        stdout: StdioCollector {
            onStreamFinished: root.leftovers = this.text.split("\n").filter(l => l !== "")
        }
    }

    Process {
        id: trashProc

        property int count: 0

        stderr: StdioCollector {
            id: trashErrors
        }
        onExited: code => {
            root.status = code === 0 ? `${count} moved to the trash` : (trashErrors.text.trim().split("\n").pop() || "could not delete");
            root.picked = {};
            root.refresh();
        }
    }

    Process {
        command: ["xdg-user-dir", "PICTURES"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const dir = this.text.trim();
                if (dir !== "")
                    root.picturesDir = dir;
            }
        }
    }

    FileView {
        id: store
        path: Quickshell.statePath("media.json")
        printErrors: false
        onLoaded: {
            try {
                root.extraFolders = (JSON.parse(text()).folders ?? []).filter(d => typeof d === "string");
            } catch (e) {
                root.extraFolders = [];
            }
        }
    }

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 13
        elide: Text.ElideRight
    }

    component Action: TuiButton {
        id: act

        property string text: ""
        property color tint: Theme.secondary

        implicitWidth: actText.implicitWidth + 24
        implicitHeight: 28
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

    // ── Layout ───────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.topMargin: 26
        spacing: 16

        // Filters
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: ["all", "pictures", "videos", "edited"]
                delegate: Action {
                    required property string modelData
                    text: `${modelData} ${root.count(modelData)}`
                    active: root.filter === modelData
                    tint: Theme.primary
                    onClicked: root.filter = modelData
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Label {
                text: listProc.running ? "looking…" : `${root.all.length} files · ${root.fmtSize(root.all.reduce((s, it) => s + it.size, 0))}`
                color: Theme.muted
            }

            // Edits and tracks of files deleted elsewhere (Dolphin): into the trash with one click
            Action {
                visible: root.leftovers.length > 0
                text: `clean up ${root.leftovers.length} leftover${root.leftovers.length === 1 ? "" : "s"}`
                tint: Theme.warn
                onClicked: {
                    if (trashProc.running)
                        return;
                    trashProc.count = root.leftovers.length;
                    trashProc.command = [root.tool, "trash"].concat(root.leftovers);
                    trashProc.running = true;
                }
            }

            // Paint: an empty page in the picture editor, the paper asked in place
            Action {
                visible: !root.choosePaper
                text: "new picture"
                tint: Theme.primary
                onClicked: root.choosePaper = true
            }
            Label {
                visible: root.choosePaper
                text: "paper:"
                color: Theme.muted
            }
            Repeater {
                model: root.choosePaper ? Editor.papers : []
                delegate: Action {
                    required property string modelData
                    text: modelData
                    tint: Theme.primary
                    onClicked: {
                        root.choosePaper = false;
                        Editor.newPicture(modelData);
                    }
                }
            }
            Action {
                visible: root.choosePaper
                text: "no"
                onClicked: root.choosePaper = false
            }

            Action {
                text: "refresh"
                onClicked: root.refresh()
            }
        }

        // What is picked and what to do with it
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: 8

            Label {
                visible: root.pickedPaths.length === 0
                Layout.fillWidth: true
                color: root.status !== "" ? Theme.ok : Theme.muted
                text: root.status !== "" ? root.status
                    : "click picks · ctrl+click more · shift+click a run · double click opens in the editor · drop a folder to add it"
            }

            Label {
                visible: root.pickedPaths.length > 0
                text: `${root.pickedPaths.length} picked · ${root.fmtSize(root.pickedSize())}`
                color: Theme.text
            }

            Item {
                visible: root.pickedPaths.length > 0
                Layout.fillWidth: true
            }

            Action {
                visible: root.pickedPaths.length > 0 && !root.confirmDelete
                text: root.pickedPaths.length === 1 ? "edit" : "edit first"
                tint: Theme.primary
                onClicked: root.openPicked()
            }
            Action {
                visible: root.pickedPaths.length === 1 && !root.confirmDelete
                text: "open"
                onClicked: Quickshell.execDetached(["xdg-open", root.pickedPaths[0]])
            }
            Action {
                visible: root.pickedPaths.length > 0 && !root.confirmDelete
                text: "copy"
                onClicked: root.copyPicked()
            }
            Action {
                visible: root.pickedPaths.length > 0 && !root.confirmDelete
                text: "folder"
                onClicked: Quickshell.execDetached(["xdg-open", root.pickedPaths[0].slice(0, root.pickedPaths[0].lastIndexOf("/"))])
            }
            Action {
                visible: root.pickedPaths.length > 0 && !root.confirmDelete
                text: `delete ${root.pickedPaths.length}`
                tint: Theme.danger
                onClicked: root.confirmDelete = true
            }

            // Asked in place: no dialog
            Label {
                visible: root.confirmDelete
                text: `move ${root.pickedPaths.length} into the trash?`
                color: Theme.warn
            }
            Action {
                visible: root.confirmDelete
                text: "yes, delete"
                tint: Theme.danger
                onClicked: root.deletePicked()
            }
            Action {
                visible: root.confirmDelete
                text: "no"
                onClicked: root.confirmDelete = false
            }
        }

        Frame {
            Layout.fillWidth: true
            Layout.fillHeight: true
            label: root.filter === "all" ? "screenshots and recordings" : root.filter
            padding: 10

            Label {
                anchors.centerIn: parent
                visible: shown.count === 0 && !listProc.running
                color: Theme.muted
                text: root.all.length === 0 ? "nothing yet · Print takes a screenshot, Super+Shift+R records" : "nothing matches"
            }

            GridView {
                id: grid

                anchors.fill: parent
                clip: true
                cellWidth: width / root.columns
                cellHeight: cellWidth * 0.5625 + 58
                model: shown
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    id: tile

                    required property int index
                    required property string path
                    required property string name
                    required property string kind
                    required property real mtime
                    required property real size
                    required property bool edited
                    required property bool tracks
                    required property real duration
                    required property string thumb
                    readonly property bool isPicked: root.picked[path] === true

                    width: grid.cellWidth
                    height: grid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 7
                        color: tile.isPicked ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1) : "transparent"
                        border.width: 1
                        border.color: tile.isPicked ? Theme.primary : hover.containsMouse ? Theme.frame : Theme.border

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 1
                            spacing: 6

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                color: Theme.surface
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: tile.kind === "image" ? root.fileUrl(tile.path) : tile.thumb !== "" ? root.fileUrl(tile.thumb) : ""
                                    sourceSize: Qt.size(400, 225)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: false
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: tile.kind === "video" && tile.thumb === ""
                                    text: "▶"
                                    color: Theme.muted
                                    font.family: Theme.font
                                    font.pixelSize: 22
                                }

                                // Badges: length bottom right, edited / tracks top left
                                Rectangle {
                                    visible: tile.kind === "video"
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 6
                                    width: lengthText.implicitWidth + 10
                                    height: lengthText.implicitHeight + 4
                                    color: Theme.bg

                                    Text {
                                        id: lengthText
                                        anchors.centerIn: parent
                                        text: tile.duration > 0 ? `▶ ${root.fmtLength(tile.duration)}` : "▶"
                                        color: Theme.text
                                        font.family: Theme.font
                                        font.pixelSize: 11
                                    }
                                }

                                Row {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.margins: 6
                                    spacing: 4

                                    Repeater {
                                        model: [tile.edited ? "edited" : "", tile.tracks ? "tracks" : ""].filter(b => b !== "")
                                        delegate: Rectangle {
                                            required property string modelData
                                            width: badge.implicitWidth + 10
                                            height: badge.implicitHeight + 4
                                            color: modelData === "edited" ? Theme.accent : Theme.secondary

                                            Text {
                                                id: badge
                                                anchors.centerIn: parent
                                                text: parent.modelData
                                                color: Theme.bg
                                                font.family: Theme.font
                                                font.pixelSize: 11
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: tile.isPicked
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: 6
                                    width: 20
                                    height: 20
                                    color: Theme.primary

                                    Text {
                                        anchors.centerIn: parent
                                        text: "✓"
                                        color: Theme.bg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                Layout.leftMargin: 8
                                Layout.rightMargin: 8
                                text: tile.name
                                color: Theme.text
                                elide: Text.ElideMiddle
                            }

                            Label {
                                Layout.fillWidth: true
                                Layout.leftMargin: 8
                                Layout.rightMargin: 8
                                Layout.bottomMargin: 8
                                text: `${Qt.formatDateTime(new Date(tile.mtime * 1000), "dd.MM.yyyy HH:mm")} · ${root.fmtSize(tile.size)}`
                                color: Theme.muted
                                font.pixelSize: 12
                            }
                        }

                        MouseArea {
                            id: hover

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mouse => {
                                root.forceActiveFocus();
                                root.status = "";
                                root.click(tile.index, mouse.modifiers);
                            }
                            onDoubleClicked: Editor.open(tile.path)
                        }
                    }
                }
            }

            // Files open in the editor; a folder becomes part of the grid
            DropArea {
                anchors.fill: parent
                onEntered: drag => drag.accepted = drag.hasUrls
                onDropped: drop => {
                    for (const url of drop.urls) {
                        const path = decodeURIComponent(url.toString().replace(/^file:\/\//, ""));
                        if (Editor.isVideo(path) || Editor.isImage(path)) {
                            Editor.open(path);
                            break;
                        }
                        if (!/\.[A-Za-z0-9]{1,5}$/.test(path))
                            root.addFolder(path);
                    }
                    drop.accept();
                }
            }
        }

        // The folders the grid shows; dropped ones can go again
        Flow {
            Layout.fillWidth: true
            spacing: 14

            Repeater {
                model: root.folders
                delegate: Row {
                    required property string modelData
                    required property int index
                    spacing: 6

                    Label {
                        text: parent.modelData.replace(Quickshell.env("HOME"), "~")
                        color: Theme.muted
                        font.pixelSize: 12
                    }

                    Text {
                        visible: parent.index >= 2
                        text: "×"
                        color: removeArea.containsMouse ? Theme.danger : Theme.muted
                        font.family: Theme.font
                        font.pixelSize: 12

                        MouseArea {
                            id: removeArea
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeFolder(parent.parent.modelData)
                        }
                    }
                }
            }
        }
    }
}
