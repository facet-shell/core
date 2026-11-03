import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.config
import qs.draw
import "../draw/DrawEngine.js" as Engine

// The picture editor: blur boxes and pictures on top of a screenshot (or any picture), a
// drawing (the Super+P tools, docked on the left) and a crop, exported as <name>-edit.png.
// Same boxes as the video editor (OverlayBox.qml), no timeline. Paint is this editor with
// an empty page (Editor.newPicture). Loaded by EditorWindow.qml.
FocusScope {
    id: root

    signal closeRequested()

    readonly property alias project: project
    // { kind: "overlay", id } | null
    property var selected: null
    property bool cropping: false
    // "export & delete original" waits for a yes
    property bool confirmRaw: false

    readonly property var selOverlay: selected?.kind === "overlay" ? project.overlay(selected.id) : null

    ImageProject {
        id: project

        // The picture is gone after "export & delete original"; nothing is written back for it
        onOriginalDeleted: {
            dirty = false;
            root.closeRequested();
        }
    }

    function fileUrl(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    // The drawing tools; "" is the pointer (blur boxes and crop). An empty page from paint
    // starts with the pen, a screenshot with the pointer.
    DrawTools {
        id: drawTools
        tool: ""
    }

    function openFile(path) {
        selected = null;
        cropping = false;
        drawTools.tool = path.includes("/paintings/") ? "pen" : "";
        project.load(path);
        picture.source = fileUrl(path);
        forceActiveFocus();
    }

    // Same calls as the video editor, nothing plays here
    function pause() {
    }

    function select(s) {
        selected = s;
    }

    function addBlur() {
        cropping = false;
        drawTools.tool = "";
        select({ kind: "overlay", id: project.addBlur(0.5, 0.5) });
    }

    function toggleCrop() {
        cropping = !cropping;
        if (cropping)
            drawTools.tool = "";
    }

    function removeSelected() {
        if (selected?.kind !== "overlay")
            return;
        project.removeOverlay(selected.id);
        select(null);
    }

    Keys.onPressed: event => {
        const ctrl = event.modifiers & Qt.ControlModifier;
        const shift = event.modifiers & Qt.ShiftModifier;
        if (event.key === Qt.Key_B && !ctrl)
            addBlur();
        else if (event.key === Qt.Key_C && !ctrl)
            toggleCrop();
        else if (event.key === Qt.Key_V && !ctrl)
            drawTools.tool = "";
        else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace)
            removeSelected();
        else if ((event.key === Qt.Key_Z && ctrl && shift) || (event.key === Qt.Key_Y && ctrl)) {
            if (project.redo())
                select(null);
        } else if (event.key === Qt.Key_Z && ctrl) {
            if (project.undo())
                select(null);
        } else if (event.key === Qt.Key_S && ctrl)
            project.startExport(false);
        else if (event.key === Qt.Key_Escape) {
            select(null);
            cropping = false;
            drawTools.tool = "";
        } else if (drawBar.handleKey(event)) {
            // A drawing tool's letter (p h l a r e t x)
            cropping = false;
            select(null);
        } else
            return;
        event.accepted = true;
    }

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

    // The drawing at the picture's full size for the export (ImageProject.drawingNeeded). A
    // Canvas paints only inside the window, so it sits in a clipped 1×1 corner, out of
    // sight, and has the picture's size only while an export waits for it.
    Item {
        width: 1
        height: 1
        clip: true

        Canvas {
            id: exportInk

            property string file: ""

            width: file !== "" ? Math.max(1, project.imageWidth) : 1
            height: file !== "" ? Math.max(1, project.imageHeight) : 1
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.clearRect(0, 0, width, height);
                if (file !== "")
                    Engine.paintShapes(ctx, project.shapes, { ox: 0, oy: 0, k: 1 }, role => Theme[role] ?? Theme.accent, Theme.font);
            }
            onPainted: {
                if (file === "" || width !== project.imageWidth)
                    return;
                const target = file;
                file = "";
                renderTimeout.stop();
                project.drawingReady(save(target));
            }
        }

        Timer {
            id: renderTimeout
            interval: 8000
            onTriggered: {
                exportInk.file = "";
                project.drawingReady(false);
            }
        }

        Connections {
            target: project

            function onDrawingNeeded(file) {
                exportInk.file = file;
                renderTimeout.restart();
                exportInk.requestPaint();
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 22
        anchors.topMargin: 26
        spacing: 22

        DrawToolbar {
            id: drawBar

            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight
            tools: drawTools
            store: project
            vertical: true
            selectTool: true
            title: "tools"

            Connections {
                target: drawTools

                // A drawing tool takes the mouse from the boxes and the crop
                function onToolChanged() {
                    if (drawTools.tool !== "") {
                        root.cropping = false;
                        root.select(null);
                    }
                    root.forceActiveFocus();
                }
            }
        }

        Frame {
            Layout.fillWidth: true
            Layout.fillHeight: true
            label: project.imageWidth > 0 ? `picture · ${project.name} · ${project.imageWidth}×${project.imageHeight}` : `picture · ${project.name}`
            padding: 14

            ColumnLayout {
                anchors.fill: parent
                spacing: 12

                Item {
                    id: stage

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    Image {
                        id: picture

                        anchors.fill: parent
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false
                        onStatusChanged: {
                            if (status === Image.Ready) {
                                project.imageWidth = implicitWidth;
                                project.imageHeight = implicitHeight;
                            }
                        }
                    }

                    // The picture's own rectangle inside the stage; overlays are fractions of it
                    Item {
                        id: frameArea

                        x: (picture.width - picture.paintedWidth) / 2
                        y: (picture.height - picture.paintedHeight) / 2
                        width: picture.paintedWidth
                        height: picture.paintedHeight

                        MouseArea {
                            anchors.fill: parent
                            onPressed: root.select(null)
                        }

                        Repeater {
                            model: project.overlays.length
                            delegate: OverlayBox {
                                required property int index

                                o: project.overlays[index] ?? null
                                store: project
                                frame: frameArea
                                capture: picture
                                nativeWidth: project.imageWidth
                                selected: o !== null && root.selOverlay !== null && root.selOverlay.id === o.id
                                onPicked: {
                                    root.select({ kind: "overlay", id: o.id });
                                    root.cropping = false;
                                    root.forceActiveFocus();
                                }
                            }
                        }

                        // The drawing, above the boxes like in the export; in picture pixels.
                        // With the pointer (no drawing tool) clicks go to the boxes below.
                        DrawCanvas {
                            anchors.fill: parent
                            store: project
                            tools: drawTools
                            scale: project.imageWidth > 0 ? frameArea.width / project.imageWidth : 1
                            active: drawTools.tool !== "" && !root.cropping && project.imageWidth > 0
                            keyTarget: root
                        }

                        // ── Crop: dimmed outside, the kept part framed ──
                        Item {
                            id: cropBox

                            readonly property var c: project.crop

                            anchors.fill: parent
                            visible: root.cropping || project.cropped

                            Rectangle { x: 0; y: 0; width: parent.width; height: cropRect.y; color: Theme.bg; opacity: 0.7 }
                            Rectangle { x: 0; y: cropRect.y + cropRect.height; width: parent.width; height: parent.height - y; color: Theme.bg; opacity: 0.7 }
                            Rectangle { x: 0; y: cropRect.y; width: cropRect.x; height: cropRect.height; color: Theme.bg; opacity: 0.7 }
                            Rectangle { x: cropRect.x + cropRect.width; y: cropRect.y; width: parent.width - x; height: cropRect.height; color: Theme.bg; opacity: 0.7 }

                            Rectangle {
                                id: cropRect

                                x: cropBox.c.x * frameArea.width
                                y: cropBox.c.y * frameArea.height
                                width: cropBox.c.w * frameArea.width
                                height: cropBox.c.h * frameArea.height
                                color: "transparent"
                                border.width: 1
                                border.color: root.cropping ? Theme.primary : Theme.frame

                                MouseArea {
                                    property point start
                                    property var from

                                    anchors.fill: parent
                                    enabled: root.cropping
                                    cursorShape: Qt.SizeAllCursor
                                    onPressed: mouse => {
                                        project.snapshot();
                                        start = mapToItem(frameArea, mouse.x, mouse.y);
                                        from = Object.assign({}, project.crop);
                                    }
                                    onPositionChanged: mouse => {
                                        if (!pressed)
                                            return;
                                        const p = mapToItem(frameArea, mouse.x, mouse.y);
                                        project.setCrop({
                                            x: Math.max(0, Math.min(1 - from.w, from.x + (p.x - start.x) / frameArea.width)),
                                            y: Math.max(0, Math.min(1 - from.h, from.y + (p.y - start.y) / frameArea.height)),
                                            w: from.w,
                                            h: from.h
                                        }, false);
                                    }
                                }

                                // Corners: top left and bottom right
                                Repeater {
                                    model: ["tl", "br"]
                                    delegate: Rectangle {
                                        id: corner

                                        required property string modelData

                                        visible: root.cropping
                                        x: modelData === "tl" ? -6 : cropRect.width - 6
                                        y: modelData === "tl" ? -6 : cropRect.height - 6
                                        width: 12
                                        height: 12
                                        color: Theme.primary

                                        MouseArea {
                                            property point start
                                            property var from

                                            anchors.fill: parent
                                            anchors.margins: -4
                                            cursorShape: Qt.SizeFDiagCursor
                                            onPressed: mouse => {
                                                project.snapshot();
                                                start = mapToItem(frameArea, mouse.x, mouse.y);
                                                from = Object.assign({}, project.crop);
                                            }
                                            onPositionChanged: mouse => {
                                                if (!pressed)
                                                    return;
                                                const p = mapToItem(frameArea, mouse.x, mouse.y);
                                                const dx = (p.x - start.x) / frameArea.width;
                                                const dy = (p.y - start.y) / frameArea.height;
                                                if (corner.modelData === "tl") {
                                                    const x = Math.max(0, Math.min(from.x + from.w - 0.02, from.x + dx));
                                                    const y = Math.max(0, Math.min(from.y + from.h - 0.02, from.y + dy));
                                                    project.setCrop({ x, y, w: from.x + from.w - x, h: from.y + from.h - y }, false);
                                                } else {
                                                    project.setCrop({ x: from.x, y: from.y, w: from.w + dx, h: from.h + dy }, false);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Pictures dragged in from Dolphin land where they are dropped
                    DropArea {
                        anchors.fill: parent
                        onEntered: drag => drag.accepted = drag.hasUrls
                        onDropped: drop => {
                            const p = frameArea.mapFromItem(stage, drop.x, drop.y);
                            for (const url of drop.urls) {
                                const path = decodeURIComponent(url.toString().replace(/^file:\/\//, ""));
                                if (!/\.(png|jpe?g|webp|gif|bmp)$/i.test(path))
                                    continue;
                                const id = project.addPicture(path,
                                    Math.max(0, Math.min(1, p.x / frameArea.width)), Math.max(0, Math.min(1, p.y / frameArea.height)));
                                root.select({ kind: "overlay", id });
                            }
                            drop.accept();
                        }
                    }

                    Label {
                        anchors.centerIn: parent
                        visible: picture.status === Image.Error
                        text: "cannot open this picture"
                        color: Theme.danger
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Action {
                        text: "▦ blur"
                        onClicked: root.addBlur()
                    }

                    Action {
                        text: "⌗ crop"
                        active: root.cropping
                        onClicked: root.toggleCrop()
                    }

                    Action {
                        text: "▣ pictures…"
                        onClicked: Quickshell.execDetached(["xdg-open", `${Quickshell.env("HOME")}/Pictures`])
                    }

                    Label {
                        Layout.fillWidth: true
                        color: Theme.muted
                        font.pixelSize: 12
                        // The drawing toolbar's hover names the button here, where there is room
                        text: drawBar.hint !== "" ? drawBar.hint
                            : "b blur box · c crop · p h l a r e t x draw · v pointer · ctrl+z undo · ctrl+s export · drop a picture on it"
                    }

                    Action {
                        visible: !root.confirmRaw
                        text: project.exporting ? "exporting…" : "export"
                        tint: Theme.primary
                        available: !project.exporting && project.imageWidth > 0
                        onClicked: project.startExport(false)
                    }

                    Action {
                        visible: !project.exporting && !root.confirmRaw
                        text: "export & delete original"
                        tint: Theme.danger
                        available: project.imageWidth > 0
                        onClicked: root.confirmRaw = true
                    }

                    // Asked in place: no dialog
                    Label {
                        visible: root.confirmRaw
                        text: "then the original goes into the trash?"
                        color: Theme.warn
                    }

                    Action {
                        visible: root.confirmRaw
                        text: "yes"
                        tint: Theme.danger
                        onClicked: {
                            root.confirmRaw = false;
                            project.startExport(true);
                        }
                    }

                    Action {
                        visible: root.confirmRaw
                        text: "no"
                        onClicked: root.confirmRaw = false
                    }
                }
            }
        }

        Frame {
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            label: "inspector"
            padding: 18

            ColumnLayout {
                anchors.fill: parent
                spacing: 14

                // Nothing selected: the picture and its crop
                ColumnLayout {
                    visible: root.selOverlay === null
                    Layout.fillWidth: true
                    spacing: 8

                    Label { text: project.name; color: Theme.text; Layout.fillWidth: true }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: Theme.muted
                        text: `${project.overlays.filter(o => o.type === "picture").length} pictures · ${project.overlays.filter(o => o.type === "blur").length} blur boxes · ${project.shapes.length} drawn`
                    }
                    Label {
                        Layout.fillWidth: true
                        color: Theme.muted
                        text: project.cropped && project.imageWidth > 0
                            ? `crop ${Math.round(project.crop.w * project.imageWidth)}×${Math.round(project.crop.h * project.imageHeight)} px`
                            : "not cropped"
                    }
                    Action {
                        visible: project.cropped
                        text: "undo the crop"
                        onClicked: project.setCrop({ x: 0, y: 0, w: 1, h: 1 })
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                        color: Theme.muted
                        text: `export: ${project.exportFile.slice(project.exportFile.lastIndexOf("/") + 1)}`
                    }
                    Label {
                        visible: project.exportError !== ""
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: Theme.danger
                        text: project.exportError
                    }
                }

                // A picture or a blur box
                ColumnLayout {
                    visible: root.selOverlay !== null
                    Layout.fillWidth: true
                    spacing: 10

                    readonly property var o: root.selOverlay

                    Label { text: parent.o?.name ?? ""; color: Theme.text; Layout.fillWidth: true }

                    RowLayout {
                        visible: parent.o?.type === "blur"
                        spacing: 0

                        Action {
                            text: "blur"
                            active: root.selOverlay?.style !== "pixel"
                            onClicked: project.updateOverlay(root.selOverlay.id, { style: "blur" })
                        }
                        Action {
                            text: "pixelate"
                            active: root.selOverlay?.style === "pixel"
                            onClicked: project.updateOverlay(root.selOverlay.id, { style: "pixel" })
                        }
                    }

                    RowLayout {
                        visible: parent.o?.type === "blur"
                        Layout.fillWidth: true
                        spacing: 10

                        Label { text: "strength"; color: Theme.muted; Layout.preferredWidth: 70 }
                        TuiSlider {
                            Layout.fillWidth: true
                            value: ((root.selOverlay?.strength ?? 14) - 4) / 26
                            onMoved: v => project.updateOverlay(root.selOverlay.id, { strength: Math.round(4 + v * 26) }, false)
                        }
                        Label { text: String(root.selOverlay?.strength ?? ""); Layout.preferredWidth: 30 }
                    }

                    RowLayout {
                        visible: parent.o?.type === "picture"
                        Layout.fillWidth: true
                        spacing: 10

                        Label { text: "opacity"; color: Theme.muted; Layout.preferredWidth: 70 }
                        TuiSlider {
                            Layout.fillWidth: true
                            value: root.selOverlay?.opacity ?? 1
                            onMoved: v => project.updateOverlay(root.selOverlay.id, { opacity: Math.max(0.05, v) }, false)
                        }
                        Label { text: `${Math.round((root.selOverlay?.opacity ?? 1) * 100)}%`; Layout.preferredWidth: 40 }
                    }

                    Label {
                        Layout.fillWidth: true
                        color: Theme.muted
                        text: parent.o && project.imageWidth > 0
                            ? `x ${Math.round(parent.o.x * project.imageWidth)} · y ${Math.round(parent.o.y * project.imageHeight)} · ${Math.round(parent.o.w * project.imageWidth)}×${Math.round((parent.o.h > 0 ? parent.o.h : parent.o.w) * project.imageHeight)} px`
                            : ""
                    }

                    Action {
                        text: "remove"
                        tint: Theme.danger
                        onClicked: root.removeSelected()
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                Action {
                    Layout.alignment: Qt.AlignRight
                    text: "close"
                    onClicked: {
                        project.writeNow();
                        root.closeRequested();
                    }
                }
            }
        }
    }
}
