import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// One picture being edited: blur boxes and pictures on top, a drawing (draw/, the same
// tools as Super+P) and a crop. Kept next to the picture as <name>.edit.json; the picture
// itself is never changed, export writes <name>-edit.png. x, y, w, h (overlays and the
// crop) are fractions of the picture; the drawing's shapes are in picture pixels
// (draw/DrawEngine.js), so the export draws them at full resolution.
Scope {
    id: root

    property string image: ""
    readonly property string stem: image.replace(/\.[^./]+$/, "")
    readonly property string editFile: stem === "" ? "" : `${stem}.edit.json`
    readonly property string exportFile: stem === "" ? "" : `${stem}-edit.png`
    readonly property string name: image.slice(image.lastIndexOf("/") + 1)

    // From the shown picture once it is loaded
    property int imageWidth: 0
    property int imageHeight: 0

    property var overlays: []
    property var shapes: []
    property var crop: ({ x: 0, y: 0, w: 1, h: 1 })
    readonly property bool cropped: crop.x > 0.001 || crop.y > 0.001 || crop.w < 0.999 || crop.h < 0.999

    property var undoStack: []
    property var redoStack: []
    // Something was changed since the last write; opening alone writes no file
    property bool dirty: false

    function load(path) {
        if (path === image)
            return;
        save.stop();
        dirty = false;
        image = path;
        imageWidth = 0;
        imageHeight = 0;
        undoStack = [];
        redoStack = [];
        overlays = [];
        shapes = [];
        crop = { x: 0, y: 0, w: 1, h: 1 };
        editView.path = editFile;
        try {
            const text = editView.text();
            const saved = text.trim() !== "" ? JSON.parse(text) : null;
            if (saved && saved.version === 1) {
                overlays = saved.overlays ?? [];
                shapes = saved.shapes ?? [];
                crop = saved.crop ?? crop;
            }
        } catch (e) {
            // A broken file starts fresh; it is written again on the first change
        }
    }

    function changed() {
        dirty = true;
        save.restart();
    }

    function writeNow() {
        if (!dirty || editFile === "")
            return;
        dirty = false;
        editView.setText(JSON.stringify({ version: 1, image, overlays, shapes, crop }, null, 1));
    }

    Timer {
        id: save
        interval: 800
        onTriggered: root.writeNow()
    }

    FileView {
        id: editView
        blockLoading: true
        printErrors: false
    }

    // ── Editing ──────────────────────────────────────────────

    function state() {
        return JSON.stringify({ overlays, shapes, crop });
    }

    function restore(text) {
        const last = JSON.parse(text);
        overlays = last.overlays;
        shapes = last.shapes ?? [];
        crop = last.crop;
        changed();
    }

    function snapshot() {
        undoStack = undoStack.concat([state()]).slice(-60);
        redoStack = [];
    }

    function undo() {
        if (undoStack.length === 0)
            return false;
        redoStack = redoStack.concat([state()]);
        const last = undoStack[undoStack.length - 1];
        undoStack = undoStack.slice(0, -1);
        restore(last);
        return true;
    }

    function redo() {
        if (redoStack.length === 0)
            return false;
        undoStack = undoStack.concat([state()]);
        const next = redoStack[redoStack.length - 1];
        redoStack = redoStack.slice(0, -1);
        restore(next);
        return true;
    }

    // ── Drawing: the calls DrawCanvas and DrawToolbar make, as on draw/DrawDoc.qml ──

    function addShape(shape) {
        snapshot();
        shapes = shapes.concat([shape]);
        changed();
    }

    // undoable false: the eraser's later hits in the same drag
    function removeShapes(indices, undoable) {
        if (indices.length === 0)
            return;
        if (undoable !== false)
            snapshot();
        shapes = shapes.filter((s, i) => !indices.includes(i));
        changed();
    }

    function clearShapes() {
        if (shapes.length === 0)
            return;
        snapshot();
        shapes = [];
        changed();
    }

    function nextId() {
        let id = 1;
        for (const o of overlays)
            id = Math.max(id, o.id + 1);
        return id;
    }

    function overlay(id) {
        return overlays.find(o => o.id === id) ?? null;
    }

    function addBlur(cx, cy) {
        snapshot();
        const id = nextId();
        const w = 0.2, h = 0.12;
        overlays = overlays.concat([{
            id, type: "blur", name: `blur ${id}`,
            x: Math.max(0, Math.min(1 - w, cx - w / 2)), y: Math.max(0, Math.min(1 - h, cy - h / 2)), w, h,
            strength: 14, style: "blur"
        }]);
        changed();
        return id;
    }

    // h -1: set from the picture's own shape once it is loaded (OverlayBox)
    function addPicture(path, cx, cy) {
        snapshot();
        const id = nextId();
        const w = 0.2;
        overlays = overlays.concat([{
            id, type: "picture", name: path.slice(path.lastIndexOf("/") + 1), src: path,
            x: Math.max(0, Math.min(1 - w, cx - w / 2)), y: Math.max(0, Math.min(0.9, cy - 0.1)), w, h: -1, opacity: 1
        }]);
        changed();
        return id;
    }

    function updateOverlay(id, changes, undoable) {
        if (undoable !== false)
            snapshot();
        overlays = overlays.map(o => o.id === id ? Object.assign({}, o, changes) : o);
        changed();
    }

    function removeOverlay(id) {
        snapshot();
        overlays = overlays.filter(o => o.id !== id);
        changed();
    }

    function setCrop(next, undoable) {
        if (undoable !== false)
            snapshot();
        const x = Math.max(0, Math.min(0.98, next.x)), y = Math.max(0, Math.min(0.98, next.y));
        crop = { x, y, w: Math.max(0.02, Math.min(1 - x, next.w)), h: Math.max(0.02, Math.min(1 - y, next.h)) };
        changed();
    }

    // ── Export ───────────────────────────────────────────────

    property bool exporting: false
    // "export & delete raw": once the export worked, the original goes into the trash with
    // what belongs to it (frame-media trash), and the editor closes
    property bool deleteAfterExport: false
    signal originalDeleted()
    property string exportError: ""
    // The drawing at the picture's size as a PNG, rendered by the view (drawingNeeded) and
    // laid over the picture by ffmpeg; "" without a drawing
    property string drawingFile: ""
    signal drawingNeeded(string file)

    // ffmpeg's arguments: blur boxes, pictures and the drawing on the full picture, the crop last
    function exportArgs() {
        const W = imageWidth, H = imageHeight;
        const px = (v, d) => Math.max(0, Math.round(v * d));
        const pictures = overlays.filter(o => o.type === "picture");
        const blurs = overlays.filter(o => o.type === "blur");
        const args = ["-y", "-nostdin", "-v", "error", "-i", image];
        for (const o of pictures)
            args.push("-i", o.src);
        if (drawingFile !== "")
            args.push("-i", drawingFile);

        // overlay works in yuv420 unless told otherwise (format=auto keeps RGBA): thin colored
        // lines and text of the drawing would get blurred color edges
        const fc = ["[0:v]format=rgba[base]"];
        let last = "base";
        let k = 0;
        for (const o of blurs) {
            const x = px(o.x, W), y = px(o.y, H);
            const w = Math.max(2, Math.min(W - x, px(o.w, W))), h = Math.max(2, Math.min(H - y, px(o.h, H)));
            let fx;
            if (o.style === "pixel") {
                const block = Math.max(4, o.strength * 1.4);
                fx = `scale=${Math.max(1, Math.round(w / block))}:${Math.max(1, Math.round(h / block))}:flags=area,scale=${w}:${h}:flags=neighbor`;
            } else {
                // boxblur's radius may not exceed half the box
                fx = `boxblur=${Math.max(1, Math.min(Math.round(o.strength * 1.5), Math.floor(Math.min(w, h) / 2) - 1))}:2`;
            }
            fc.push(`[${last}]split[b${k}][s${k}]`);
            fc.push(`[s${k}]crop=${w}:${h}:${x}:${y},${fx}[f${k}]`);
            fc.push(`[b${k}][f${k}]overlay=${x}:${y}:format=auto[o${k}]`);
            last = `o${k}`;
            k++;
        }
        pictures.forEach((o, i) => {
            const ph = o.h > 0 ? o.h : o.w;
            fc.push(`[${1 + i}:v]scale=${Math.max(2, px(o.w, W))}:${Math.max(2, px(ph, H))},format=rgba,colorchannelmixer=aa=${Number(o.opacity.toFixed(3))}[p${i}]`);
            fc.push(`[${last}][p${i}]overlay=${px(o.x, W)}:${px(o.y, H)}:format=auto[o${k}]`);
            last = `o${k}`;
            k++;
        });
        // Rendered at the picture's size; scaled anyway in case a HiDPI canvas doubled it
        if (drawingFile !== "") {
            fc.push(`[${1 + pictures.length}:v]scale=${W}:${H},format=rgba[d]`);
            fc.push(`[${last}][d]overlay=0:0:format=auto[o${k}]`);
            last = `o${k}`;
            k++;
        }
        const cx = px(crop.x, W), cy = px(crop.y, H);
        fc.push(`[${last}]crop=${Math.max(1, Math.min(W - cx, px(crop.w, W)))}:${Math.max(1, Math.min(H - cy, px(crop.h, H)))}:${cx}:${cy}[out]`);
        args.push("-filter_complex", fc.join(";"), "-map", "[out]", "-frames:v", "1", "-update", "1", exportFile);
        return args;
    }

    function startExport(deleteOriginal) {
        if (exporting || imageWidth <= 0)
            return;
        deleteAfterExport = deleteOriginal === true;
        writeNow();
        exportError = "";
        exporting = true;
        if (shapes.length === 0) {
            drawingFile = "";
            runExport();
            return;
        }
        drawingFile = `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/frame-draw-${Date.now()}.png`;
        drawingNeeded(drawingFile);
    }

    // The view saved the drawing (ok) or could not
    function drawingReady(ok) {
        if (!exporting || drawingFile === "" || exportProc.running)
            return;
        if (!ok) {
            exporting = false;
            drawingFile = "";
            exportError = "the drawing could not be rendered";
            Notifications.push({ app: "editor", glyph: "✗", title: "export failed", body: exportError });
            return;
        }
        runExport();
    }

    function runExport() {
        exportProc.command = ["ffmpeg"].concat(exportArgs());
        exportProc.running = true;
    }

    Process {
        id: exportProc

        stderr: StdioCollector {
            id: exportErrors
        }
        onExited: code => {
            root.exporting = false;
            if (root.drawingFile !== "") {
                Quickshell.execDetached(["rm", "-f", "--", root.drawingFile]);
                root.drawingFile = "";
            }
            const file = root.exportFile;
            const name = file.slice(file.lastIndexOf("/") + 1);
            if (code !== 0) {
                root.exportError = exportErrors.text.trim().split("\n").pop() || `ffmpeg stopped (${code})`;
                Notifications.push({ app: "editor", glyph: "✗", title: "export failed", body: root.exportError });
                return;
            }
            const removed = root.deleteAfterExport;
            if (removed) {
                root.deleteAfterExport = false;
                Quickshell.execDetached([`${Quickshell.env("HOME")}/.local/bin/frame-media`, "trash", root.image]);
                root.originalDeleted();
            }
            Notifications.push({
                app: "editor",
                title: removed ? "picture exported · original in the trash" : "picture exported",
                body: name,
                image: file,
                actions: [
                    { id: "open", label: "open", style: "ok" },
                    { id: "copy", label: "copy", style: "" },
                    { id: "folder", label: "folder", style: "" }
                ],
                onAction: id => {
                    if (id === "open")
                        Quickshell.execDetached(["xdg-open", file]);
                    else if (id === "copy")
                        // As the picture itself, for pasting into chats
                        Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"', "frame-edit", file]);
                    else if (id === "folder")
                        Quickshell.execDetached(["xdg-open", file.slice(0, file.lastIndexOf("/"))]);
                }
            });
        }
    }
}
