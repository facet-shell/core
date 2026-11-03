import QtQuick
import Quickshell
import Quickshell.Io

// The screen drawing (Super+P, DrawOverlay.qml): its shapes with undo and redo, kept in the
// shell's state folder (draw.json) so a shell restart does not lose it. The picture editor
// keeps its shapes in ImageProject instead, with the rest of the edit. Both offer the same
// calls to DrawCanvas and DrawToolbar: shapes, addShape, removeShapes, clearShapes, undo, redo.
Scope {
    id: root

    property var shapes: []
    // Earlier shape lists; a list is never changed in place, so keeping it is enough
    property var undoStack: []
    property var redoStack: []

    function push() {
        undoStack = undoStack.concat([shapes]).slice(-100);
        redoStack = [];
    }

    function addShape(shape) {
        push();
        shapes = shapes.concat([shape]);
        save.restart();
    }

    // undoable false: the eraser's later hits in the same drag, one undo takes them all back
    function removeShapes(indices, undoable) {
        if (indices.length === 0)
            return;
        if (undoable !== false)
            push();
        shapes = shapes.filter((s, i) => !indices.includes(i));
        save.restart();
    }

    function clearShapes() {
        if (shapes.length === 0)
            return;
        push();
        shapes = [];
        save.restart();
    }

    function undo() {
        if (undoStack.length === 0)
            return false;
        redoStack = redoStack.concat([shapes]);
        shapes = undoStack[undoStack.length - 1];
        undoStack = undoStack.slice(0, -1);
        save.restart();
        return true;
    }

    function redo() {
        if (redoStack.length === 0)
            return false;
        undoStack = undoStack.concat([shapes]);
        shapes = redoStack[redoStack.length - 1];
        redoStack = redoStack.slice(0, -1);
        save.restart();
        return true;
    }

    function writeNow() {
        save.stop();
        file.setText(JSON.stringify({ version: 1, shapes }));
    }

    // Many strokes in a row are one write
    Timer {
        id: save
        interval: 600
        onTriggered: root.writeNow()
    }

    FileView {
        id: file
        path: Quickshell.statePath("draw.json")
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        try {
            const text = file.text();
            const saved = text.trim() !== "" ? JSON.parse(text) : null;
            if (saved && saved.version === 1 && Array.isArray(saved.shapes))
                shapes = saved.shapes.filter(s => s && typeof s.tool === "string" && Array.isArray(s.points));
        } catch (e) {
            // A broken file starts an empty drawing; the next stroke writes it again
        }
    }
}
