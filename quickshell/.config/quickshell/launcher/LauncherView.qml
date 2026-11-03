import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.components
import qs.config
import qs.services

// Launcher UI: query line, result list, info pane and mode tabs.
// The modes themselves (prefixes, rows, what Enter does) live in Modes.qml.
Item {
    id: root

    signal closeRequested()

    // Keeps clicks on the panel itself (the picture preview, empty space) from reaching
    // the click-outside area behind it, which would close the launcher
    MouseArea {
        anchors.fill: parent
        onClicked: input.forceActiveFocus()
    }

    property string query: ""
    property int current: 0
    // Power action waiting for its second Enter
    property string armed: ""

    readonly property var parsed: modes.parse(query)
    readonly property string mode: parsed.mode
    readonly property string rest: parsed.rest
    readonly property var results: modes.compute(mode, rest)
    readonly property var selected: results.length > 0 ? results[Math.min(current, results.length - 1)] : null
    readonly property int maxRows: 9
    // Long lists (emoji, files, clipboard) scroll in windows of maxRows
    readonly property int first: Math.max(0, Math.min(current - maxRows + 1, results.length - maxRows))
    // Claude has answered the question that is typed: the answer takes the place of the list
    // and the info pane, in the launcher's own size; while it thinks, a line with the seconds
    readonly property bool answering: selected?.kind === "claude" && selected.answered === true
    readonly property bool thinking: selected?.kind === "claude" && !selected.answered && Claude.busy && Claude.question === selected.question
    // The answer as blocks to draw: [{ kind: "p" | "h" | "item" | "code", html, text, lang }]
    readonly property var answerBlocks: answering ? parseAnswer(Claude.answer) : []
    property int thinkSeconds: 0
    property int spinFrame: 0
    readonly property string spinner: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".charAt(spinFrame % 10)
    // "copied …" under the answer for a moment after a copy
    property string copied: ""

    // Tab keeps the text, so a new mode also searches what is already typed
    onModeChanged: {
        modes.modeEntered(mode);
        modes.queryChanged(mode, rest);
    }
    onRestChanged: modes.queryChanged(mode, rest)

    Modes {
        id: modes
    }

    // Opens in a mode, e.g. "; " for the clipboard history (Super+V)
    function preset(text) {
        input.text = text;
        input.cursorPosition = text.length;
    }

    // Types text at the cursor, over a selection (Ctrl+Alt+Q → @, frame/shell.lua)
    function type(text) {
        if (input.selectedText !== "")
            input.remove(input.selectionStart, input.selectionEnd);
        input.insert(input.cursorPosition, text);
    }

    function reset() {
        input.text = "";
        current = 0;
        armed = "";
        input.forceActiveFocus();
    }

    function move(step) {
        const count = results.length;
        if (count > 0)
            current = (current + step + count) % count;
        armed = "";
    }

    function cycleMode(step) {
        const order = modes.order;
        const next = order[(order.indexOf(mode) + step + order.length) % order.length];
        input.text = modes.prefix(next) + rest;
    }

    function setMode(next) {
        input.text = modes.prefix(next) + rest;
        input.forceActiveFocus();
    }

    // Ctrl+C in the answer view: the selected part of the answer, else all of it
    function copyAnswer(all) {
        const part = all ? "" : answerSelection();
        modes.copy(part !== "" ? part : Claude.answer);
        copied = part !== "" ? `copied ${part.length} of ${Claude.answer.length} characters` : "copied the whole answer";
        copiedTimer.restart();
    }

    function copyCode(text) {
        modes.copy(text);
        copied = "copied the code block";
        copiedTimer.restart();
    }

    // The selection sits in one block at a time
    function answerSelection() {
        for (let i = 0; i < blockRepeater.count; i++) {
            const part = blockRepeater.itemAt(i)?.selection() ?? "";
            if (part !== "")
                return part;
        }
        return "";
    }

    function clearAnswerSelection() {
        let had = false;
        for (let i = 0; i < blockRepeater.count; i++)
            had = (blockRepeater.itemAt(i)?.deselect() ?? false) || had;
        return had;
    }

    // The bits of Markdown Claude answers with: paragraphs, headings, - and 1. lists, ```
    // code blocks; `code` and **bold** inside a line
    function inlineHtml(line) {
        const esc = line.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return esc
            .replace(/`([^`]+)`/g, `<span style="color:${Theme.secondary};background-color:${Theme.surface}">&nbsp;$1&nbsp;</span>`)
            .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    }

    function parseAnswer(md) {
        const out = [];
        const lines = md.split("\n");
        let i = 0;
        while (i < lines.length) {
            const line = lines[i];
            if (/^\s*```/.test(line)) {
                const lang = line.trim().slice(3).trim();
                const code = [];
                i++;
                while (i < lines.length && !/^\s*```/.test(lines[i]))
                    code.push(lines[i++]);
                i++;
                out.push({ kind: "code", text: code.join("\n"), lang: lang || "text", html: "" });
            } else if (/^#{1,6}\s/.test(line)) {
                const title = line.replace(/^#+\s*/, "");
                out.push({ kind: "h", html: `<span style="color:${Theme.frame}">## </span><span style="color:${Theme.primary}">${inlineHtml(title)}</span>`, text: title, lang: "" });
                i++;
            } else if (/^\s*([-*]|\d+\.)\s/.test(line)) {
                const item = line.replace(/^\s*([-*]|\d+\.)\s+/, "");
                out.push({ kind: "item", html: inlineHtml(item), text: item, lang: "" });
                i++;
            } else if (line.trim() === "") {
                i++;
            } else {
                const para = [];
                while (i < lines.length && lines[i].trim() !== "" && !/^\s*(```|[-*]\s|\d+\.\s|#{1,6}\s)/.test(lines[i]))
                    para.push(lines[i++].trim());
                out.push({ kind: "p", html: inlineHtml(para.join(" ")), text: para.join(" "), lang: "" });
            }
        }
        return out;
    }

    Timer {
        running: root.thinking
        interval: 90
        repeat: true
        onTriggered: root.spinFrame += 1
    }

    Timer {
        running: root.thinking
        interval: 500
        repeat: true
        triggeredOnStart: true
        onTriggered: root.thinkSeconds = Math.floor((Date.now() - Claude.askedAt) / 1000)
    }

    function scrollAnswer(by) {
        answerFlick.contentY = Math.max(0, Math.min(answerFlick.contentY + by, answerFlick.contentHeight - answerFlick.height));
    }

    Timer {
        id: copiedTimer
        interval: 2200
        onTriggered: root.copied = ""
    }

    onAnsweringChanged: {
        copied = "";
        answerFlick.contentY = 0;
    }

    function activate(shift) {
        if (!selected)
            return;
        const next = modes.activate(selected, shift, armed);
        armed = next.arm ?? "";
        if (next.query !== undefined)
            input.text = next.query;
        if (next.close)
            closeRequested();
    }

    // ── Building blocks ──────────────────────────────────────

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: Theme.size.normal
    }

    component Divider: Rectangle {
        color: Theme.border
        implicitWidth: 1
        implicitHeight: 1
    }

    // ── Layout ───────────────────────────────────────────────

    // Swallows clicks so they do not reach the dimmed background behind
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        opacity: 0.94
    }

    Frame {
        anchors.fill: parent
        label: "run"
        borderColor: Theme.primary
        padding: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 1
            spacing: 0

            // Query line
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 84
                Layout.leftMargin: 30
                Layout.rightMargin: 30
                spacing: 18

                Text {
                    text: "❯"
                    color: Theme.primary
                    font.family: Theme.font
                    font.pixelSize: 26
                    font.weight: Font.Medium
                }

                TextInput {
                    id: input

                    Layout.fillWidth: true
                    focus: true
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 26
                    cursorDelegate: Rectangle { width: 3; color: Theme.secondary }

                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: input.text === ""
                        text: "search apps · s spotify · d discord · / files · tab for more"
                        color: Theme.frame
                        font.pixelSize: 26
                    }

                    onTextChanged: {
                        root.query = text;
                        root.current = 0;
                        root.armed = "";
                    }

                    Keys.onPressed: event => {
                        // The answer view: arrows and page keys scroll the answer, Ctrl+C copies
                        // it (the query line's own selection still wins, so editing stays normal)
                        if (root.answering) {
                            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                            const page = answerFlick.height - 60;
                            let handled = true;
                            if (ctrl && event.key === Qt.Key_C && input.selectedText === "")
                                root.copyAnswer(false);
                            else if (event.key === Qt.Key_Down)
                                root.scrollAnswer(60);
                            else if (event.key === Qt.Key_Up)
                                root.scrollAnswer(-60);
                            else if (event.key === Qt.Key_PageDown)
                                root.scrollAnswer(page);
                            else if (event.key === Qt.Key_PageUp)
                                root.scrollAnswer(-page);
                            else if (ctrl && event.key === Qt.Key_Home)
                                root.scrollAnswer(-answerFlick.contentHeight);
                            else if (ctrl && event.key === Qt.Key_End)
                                root.scrollAnswer(answerFlick.contentHeight);
                            else if (event.key === Qt.Key_Escape && root.answerSelection() !== "")
                                root.clearAnswerSelection();
                            else
                                handled = false;
                            if (handled) {
                                event.accepted = true;
                                return;
                            }
                        }
                        switch (event.key) {
                        case Qt.Key_Down:
                            root.move(1);
                            break;
                        case Qt.Key_Up:
                            root.move(-1);
                            break;
                        case Qt.Key_Tab:
                            root.cycleMode(1);
                            break;
                        case Qt.Key_Backtab:
                            root.cycleMode(-1);
                            break;
                        case Qt.Key_Escape:
                            root.closeRequested();
                            break;
                        case Qt.Key_Return:
                        case Qt.Key_Enter:
                            root.activate((event.modifiers & Qt.ShiftModifier) !== 0);
                            break;
                        default:
                            return;
                        }
                        event.accepted = true;
                    }
                }

                Rectangle {
                    implicitWidth: modeLabel.implicitWidth + 24
                    implicitHeight: modeLabel.implicitHeight + 6
                    color: "transparent"
                    border.color: Theme.border
                    border.width: 1
                    Label {
                        id: modeLabel
                        anchors.centerIn: parent
                        text: modes.names[root.mode] ?? "apps"
                        color: Theme.secondary
                        font.pixelSize: Theme.size.small
                    }
                }
            }

            Divider { Layout.fillWidth: true }

            // Claude, in place of the list and the info pane: the wait, then the answer as
            // blocks (text, headings, list items, code with its own copy), selectable, scrolls
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.answering || root.thinking

                Column {
                    anchors.centerIn: parent
                    visible: root.thinking
                    spacing: 16

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: `${root.spinner}  claude · ${Config.claudeModel || "cli default"} is thinking · ${root.thinkSeconds} s`
                        color: Theme.muted
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 360
                        height: 2
                        color: Theme.border
                        clip: true

                        Rectangle {
                            width: 108
                            height: 2
                            color: Theme.accent

                            SequentialAnimation on x {
                                running: root.thinking
                                loops: Animation.Infinite
                                NumberAnimation { from: -108; to: 360; duration: 1400; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 30
                    anchors.rightMargin: 30
                    anchors.topMargin: 18
                    visible: root.answering
                    spacing: 14

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14

                        AppIcon {
                            glyph: "c"
                            tint: Theme.accent
                        }

                        Label {
                            Layout.fillWidth: true
                            text: `claude · ${Config.claudeModel || "cli default"} · ${Claude.took.toFixed(1)} s · ${Claude.answer.length} characters`
                            color: Theme.muted
                            font.pixelSize: Theme.size.small
                            elide: Text.ElideRight
                        }

                        Label {
                            visible: root.copied !== ""
                            text: root.copied
                            color: Theme.ok
                            font.pixelSize: Theme.size.small
                        }

                        TuiButton {
                            implicitWidth: copyLabel.implicitWidth + 24
                            implicitHeight: copyLabel.implicitHeight + 10
                            accent: Theme.accent
                            active: root.copied !== ""
                            onClicked: root.copyAnswer(true)

                            Label {
                                id: copyLabel
                                anchors.centerIn: parent
                                text: "⧉ copy answer"
                                color: parent.hovered ? Theme.text : Theme.secondary
                                font.pixelSize: Theme.size.small
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true

                        // Wheel and keys scroll; a press and drag selects text instead of flicking
                        Flickable {
                            id: answerFlick

                            anchors.fill: parent
                            anchors.rightMargin: 22
                            contentWidth: width
                            contentHeight: blocks.implicitHeight + 22
                            interactive: false
                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: blocks

                                y: 4
                                // About 84 characters a line stay readable
                                width: Math.min(answerFlick.width, 860)
                                spacing: 12

                                Repeater {
                                    id: blockRepeater

                                    model: root.answerBlocks

                                    delegate: Item {
                                        id: block

                                        required property var modelData
                                        readonly property bool isCode: modelData.kind === "code"

                                        function selection() {
                                            return isCode ? codeText.selectedText : prose.selectedText;
                                        }

                                        function deselect() {
                                            const had = selection() !== "";
                                            codeText.deselect();
                                            prose.deselect();
                                            return had;
                                        }

                                        width: blocks.width
                                        height: isCode ? codeBox.height : prose.height + (modelData.kind === "h" ? 6 : 0)

                                        // List items get an accent dot in front
                                        Text {
                                            visible: block.modelData.kind === "item"
                                            x: 8
                                            y: prose.y
                                            text: "·"
                                            color: Theme.accent
                                            font.family: Theme.font
                                            font.pixelSize: 17
                                            font.bold: true
                                        }

                                        TextEdit {
                                            id: prose

                                            visible: !block.isCode
                                            x: block.modelData.kind === "item" ? 26 : 0
                                            y: block.modelData.kind === "h" ? 6 : 0
                                            width: parent.width - x
                                            text: block.isCode ? "" : block.modelData.html
                                            textFormat: TextEdit.RichText
                                            readOnly: true
                                            selectByMouse: true
                                            // The query line keeps the keyboard, so typing still edits the question
                                            activeFocusOnPress: false
                                            persistentSelection: true
                                            wrapMode: TextEdit.Wrap
                                            color: Theme.text
                                            selectionColor: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.55)
                                            selectedTextColor: Theme.text
                                            font.family: Theme.font
                                            font.pixelSize: 17
                                            font.weight: block.modelData.kind === "h" ? Font.Medium : Font.Normal

                                            MouseArea {
                                                anchors.fill: parent
                                                acceptedButtons: Qt.NoButton
                                                cursorShape: Qt.IBeamCursor
                                            }
                                        }

                                        // Code: its own box with the language and a copy of just this
                                        Rectangle {
                                            id: codeBox

                                            visible: block.isCode
                                            width: parent.width
                                            height: block.isCode ? codeText.height + 26 : 0
                                            color: Theme.surface

                                            Rectangle {
                                                width: 2
                                                height: parent.height
                                                color: Theme.accent
                                            }

                                            TextEdit {
                                                id: codeText

                                                x: 18
                                                y: 13
                                                width: parent.width - 36 - codeTools.width
                                                text: block.isCode ? block.modelData.text : ""
                                                textFormat: TextEdit.PlainText
                                                readOnly: true
                                                selectByMouse: true
                                                activeFocusOnPress: false
                                                persistentSelection: true
                                                wrapMode: TextEdit.WrapAnywhere
                                                color: Theme.textDim
                                                selectionColor: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.55)
                                                selectedTextColor: Theme.text
                                                font.family: Theme.font
                                                font.pixelSize: 15

                                                MouseArea {
                                                    anchors.fill: parent
                                                    acceptedButtons: Qt.NoButton
                                                    cursorShape: Qt.IBeamCursor
                                                }
                                            }

                                            Row {
                                                id: codeTools

                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                anchors.margins: 8
                                                spacing: 8

                                                Label {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: block.modelData.lang ?? ""
                                                    color: Theme.muted
                                                    font.pixelSize: 12
                                                }

                                                TuiButton {
                                                    implicitWidth: codeCopy.implicitWidth + 16
                                                    implicitHeight: codeCopy.implicitHeight + 6
                                                    accent: Theme.accent
                                                    onClicked: root.copyCode(block.modelData.text)

                                                    Label {
                                                        id: codeCopy
                                                        anchors.centerIn: parent
                                                        text: "⧉ copy"
                                                        color: parent.hovered ? Theme.text : Theme.secondary
                                                        font.pixelSize: 12
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        WheelHandler {
                            target: null
                            onWheel: event => root.scrollAnswer(-event.angleDelta.y)
                        }

                        // Scroll position, only when the answer is longer than the box
                        Rectangle {
                            visible: answerFlick.contentHeight > answerFlick.height
                            x: parent.width - 3
                            y: (parent.height - height) * (answerFlick.contentY / Math.max(1, answerFlick.contentHeight - answerFlick.height))
                            width: 3
                            height: Math.max(40, parent.height * answerFlick.height / Math.max(1, answerFlick.contentHeight))
                            color: Theme.frame
                        }
                    }
                }
            }

            // Results and info pane
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !root.answering && !root.thinking
                spacing: 0

                Item {
                    Layout.preferredWidth: 640
                    Layout.fillHeight: true

                    Label {
                        anchors { left: parent.left; top: parent.top; margins: 24 }
                        visible: root.results.length === 0
                        text: "no matches · tab switches the mode"
                        color: Theme.muted
                    }

                    ListView {
                        anchors.fill: parent
                        anchors.topMargin: 14
                        interactive: false
                        model: root.results.slice(root.first, root.first + root.maxRows)

                        delegate: Item {
                            id: row

                            required property var modelData
                            required property int index
                            readonly property int position: root.first + index
                            readonly property bool active: position === root.current
                            readonly property bool passive: modelData.kind === "info"

                            width: ListView.view.width
                            height: 52

                            Rectangle {
                                anchors.fill: parent
                                color: row.active && !row.passive ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16)
                                    : hover.containsMouse && !row.passive ? Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.06)
                                    : "transparent"
                            }

                            Rectangle {
                                width: 3
                                height: parent.height
                                color: Theme.primary
                                visible: row.active && !row.passive
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 18
                                anchors.rightMargin: 22
                                spacing: 16

                                Text {
                                    Layout.preferredWidth: 20
                                    text: "❯"
                                    color: Theme.primary
                                    font.family: Theme.font
                                    font.pixelSize: Theme.size.normal
                                    opacity: row.active && !row.passive ? 1 : 0
                                }

                                AppIcon {
                                    visible: !row.passive
                                    icon: row.modelData.icon
                                    glyph: row.modelData.glyph
                                    glyphFont: row.modelData.glyphFont ?? Theme.font
                                    tint: row.modelData.tint
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    Label {
                                        Layout.fillWidth: true
                                        text: row.modelData.markup ?? modes.escapeHtml(row.modelData.title)
                                        textFormat: Text.StyledText
                                        color: row.passive ? Theme.muted : row.active ? Theme.text : Theme.textDim
                                        elide: Text.ElideRight
                                    }

                                    // Info rows say what to type; other rows keep their detail for the info pane
                                    Label {
                                        Layout.fillWidth: true
                                        visible: row.passive && (row.modelData.desc ?? "") !== ""
                                        text: row.modelData.desc ?? ""
                                        color: Theme.frame
                                        font.pixelSize: Theme.size.small
                                        elide: Text.ElideRight
                                    }
                                }

                                Label {
                                    text: row.modelData.category ?? ""
                                    color: Theme.frame
                                    font.pixelSize: Theme.size.small
                                }
                            }

                            MouseArea {
                                id: hover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: row.passive ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onEntered: root.current = row.position
                                onClicked: mouse => {
                                    root.current = row.position;
                                    root.activate((mouse.modifiers & Qt.ShiftModifier) !== 0);
                                }
                            }
                        }
                    }

                    Label {
                        anchors { right: parent.right; bottom: parent.bottom; margins: 14 }
                        visible: root.results.length > root.maxRows
                        text: `${root.current + 1} / ${root.results.length}`
                        color: Theme.frame
                        font.pixelSize: Theme.size.small
                    }
                }

                Divider { Layout.fillHeight: true }

                // Info pane for the selected result
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 32
                    spacing: 6
                    visible: root.selected !== null && root.selected.kind !== "info"

                    RowLayout {
                        visible: root.selected?.kind !== "calc"
                        Layout.bottomMargin: 18
                        spacing: 22

                        AppIcon {
                            size: 76
                            icon: root.selected?.icon ?? ""
                            glyph: root.selected?.glyph ?? ""
                            glyphFont: root.selected?.glyphFont ?? Theme.font
                            tint: root.selected?.tint ?? Theme.primary
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                text: root.selected?.kind === "run" ? "run command" : root.selected?.title ?? ""
                                color: Theme.text
                                font.pixelSize: 28
                                font.weight: Font.Medium
                                wrapMode: Text.WordWrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: root.selected?.desc ?? ""
                                color: Theme.muted
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    Label {
                        visible: root.selected?.kind === "calc"
                        text: "── result"
                        color: Theme.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 22
                        visible: root.selected?.kind === "calc"
                        text: root.selected?.value ?? "…"
                        color: Theme.text
                        font.family: Theme.font
                        font.pixelSize: 64
                        font.weight: Font.Light
                        wrapMode: Text.WrapAnywhere
                    }

                    // Longer text: Claude's answer, a clipboard entry
                    // The first lines of a text file (file search), read when it is selected
                    // A process that is still running ignores running = true, so a quick ↓ would
                    // leave the next file without a preview and show the last one's text: each
                    // run remembers its file, late output is dropped and the current one follows
                    Process {
                        id: textPeek
                        property string path: root.selected?.textPreview ?? ""
                        property string startedFor: ""
                        property string snippet: ""
                        function start() {
                            if (path === "" || running)
                                return;
                            startedFor = path;
                            command = ["head", "-c", "3000", path];
                            running = true;
                        }
                        onPathChanged: {
                            snippet = "";
                            start();
                        }
                        onExited: Qt.callLater(() => {
                            if (textPeek.startedFor !== textPeek.path)
                                textPeek.start();
                        })
                        stdout: StdioCollector {
                            onStreamFinished: {
                                if (textPeek.startedFor === textPeek.path)
                                    textPeek.snippet = this.text.split("\n").slice(0, 28).join("\n");
                            }
                        }
                    }

                    Rectangle {
                        visible: (root.selected?.textPreview ?? "") !== "" && textPeek.snippet !== ""
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(360, snippetLabel.implicitHeight + 24)
                        Layout.bottomMargin: 18
                        color: Theme.surface
                        border.width: 1
                        border.color: Theme.border
                        clip: true

                        Text {
                            id: snippetLabel
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                            text: textPeek.snippet
                            color: Theme.textDim
                            font.family: Theme.font
                            font.pixelSize: 13
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }

                    // A thumbnail for a video or PDF (file search), made when it is selected and
                    // kept in $XDG_RUNTIME_DIR/qs-thumbs
                    // Same pattern as textPeek: one run at a time, results only for the file
                    // that is still selected
                    Process {
                        id: thumbPeek
                        property string source: (root.selected?.thumbSource || root.selected?.pdfSource) ?? ""
                        property string startedFor: ""
                        property string startedFile: ""
                        property string ready: ""
                        function start() {
                            if (source === "" || running)
                                return;
                            // Read here, not from a binding that may still hold the last file's value
                            const pdf = (root.selected?.pdfSource ?? "") === source;
                            startedFor = source;
                            startedFile = `${Quickshell.env("XDG_RUNTIME_DIR")}/qs-thumbs/${Qt.md5(source)}.png`;
                            command = ["sh", "-c", pdf
                                ? 'mkdir -p "$(dirname "$2")" && { [ -s "$2" ] || { pdftoppm -png -r 40 -f 1 -l 1 -singlefile "$1" "${2%.png}"; }; }'
                                : 'mkdir -p "$(dirname "$2")" && { [ -s "$2" ] || ffmpegthumbnailer -i "$1" -o "$2" -s 640 -q 8; }',
                                "thumb", source, startedFile];
                            running = true;
                        }
                        onSourceChanged: {
                            ready = "";
                            start();
                        }
                        onExited: code => {
                            if (code === 0 && startedFor === source && source !== "")
                                ready = startedFile;
                            else if (startedFor !== source)
                                Qt.callLater(start);
                        }
                    }

                    // A picture (clipboard history or a file, or the thumbnail of a video or PDF):
                    // shown large
                    Rectangle {
                        readonly property string shown: (root.selected?.preview ?? "") !== "" ? root.selected.preview : thumbPeek.ready
                        visible: shown !== ""
                        Layout.fillWidth: true
                        // A fixed height, so the pane does not jump while a picture loads
                        Layout.preferredHeight: 300
                        Layout.bottomMargin: 18
                        color: Theme.surface
                        border.width: 1
                        border.color: Theme.border
                        clip: true

                        Image {
                            id: previewImage
                            anchors.fill: parent
                            anchors.margins: 1
                            // Encoded per path part: a "#" or "?" in a file name would end the URL early
                            source: parent.shown !== "" ? "file://" + parent.shown.split("/").map(encodeURIComponent).join("/") : ""
                            // Big screenshots are scaled down once on load, not on every paint
                            sourceSize.width: 1200
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 18
                        visible: (root.selected?.body ?? "") !== ""
                        text: root.selected?.body ?? ""
                        color: Theme.text
                        wrapMode: Text.Wrap
                        maximumLineCount: 9
                        elide: Text.ElideRight
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 16
                        rowSpacing: 6

                        Repeater {
                            model: (root.selected?.rows ?? []).reduce((all, row) => all.concat(row), [])

                            Label {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: index % 2 === 1
                                Layout.preferredWidth: index % 2 === 0 ? 110 : -1
                                text: modelData
                                color: index % 2 === 0 ? Theme.frame : Theme.secondary
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            Divider { Layout.fillWidth: true }

            // Mode tabs and key hints
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                Layout.leftMargin: 26
                Layout.rightMargin: 26
                spacing: 4

                Repeater {
                    model: modes.order

                    Rectangle {
                        required property string modelData
                        readonly property bool on: root.mode === modelData
                        implicitWidth: tabLabel.implicitWidth + 14
                        implicitHeight: tabLabel.implicitHeight + 4
                        color: "transparent"
                        border.width: 1
                        border.color: on ? Theme.border : "transparent"

                        Label {
                            id: tabLabel
                            anchors.centerIn: parent
                            text: parent.modelData === "" ? "apps" : parent.on ? `${parent.modelData} ${modes.names[parent.modelData]}` : parent.modelData
                            color: parent.on ? Theme.secondary : Theme.muted
                            font.pixelSize: Theme.size.small
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setMode(parent.modelData)
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Label {
                    text: root.armed !== "" ? `press enter again to ${root.armed}`
                        : root.selected?.keys ?? "↑↓ select · enter launch · tab mode · esc close"
                    color: root.armed !== "" ? Theme.warn : Theme.frame
                    font.pixelSize: Theme.size.small
                    elide: Text.ElideLeft
                    Layout.maximumWidth: root.answering ? 640 : 420
                }
            }
        }
    }
}
