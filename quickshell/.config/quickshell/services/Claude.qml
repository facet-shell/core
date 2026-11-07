pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config

// Short answers from Claude for the launcher (c), through the Claude Code CLI
// (`claude -p`, signed in as you). The mode only exists when `claude` is installed and
// Config.claudeEnabled is on. Nothing is sent while typing, only on Enter.
// It runs in its own empty folder, so no project's CLAUDE.md or files come along.
// Hyprland starts qs with the system PATH only, so ~/.local/bin (where the CLI's installer
// puts `claude`) and the npm folders are added before looking for it.
Singleton {
    id: root

    property bool installed: false
    readonly property bool available: installed && Config.claudeEnabled

    property string question: ""
    property string answer: ""
    property string error: ""
    readonly property bool busy: proc.running
    // When the question went out (ms) and how long the answer took (s), for the launcher
    property real askedAt: 0
    property real took: 0

    readonly property string workDir: `${Quickshell.env("HOME")}/.local/state/facet/claude`
    readonly property string withPath: 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/npm/bin:$PATH"; '

    // The launcher shows Markdown (paragraphs, lists, code blocks), so a command can come as one
    readonly property string instructions: "You answer quick questions typed into a desktop launcher. "
        + "Be brief: a few sentences, or a short list and a code block when a command helps. "
        + "Plain Markdown only, no tables. Use the language of the question."

    function ask(text) {
        const q = text.trim();
        if (q === "" || (q === question && (busy || answer !== "")))
            return;
        proc.running = false;
        question = q;
        answer = "";
        error = "";
        const model = Config.claudeModel !== "" ? ["--model", Config.claudeModel] : [];
        proc.asked = q;
        askedAt = Date.now();
        took = 0;
        // First line of the output: exit code; the rest: the answer or the error. stdin is
        // closed, or claude waits 3 s for piped input and prints a warning into the answer.
        proc.command = ["sh", "-c", withPath + 'mkdir -p "$0" && cd "$0" || exit 1; out=$(claude "$@" 2>&1 </dev/null); printf "%s\\n%s" "$?" "$out"',
            workDir, "-p", "--append-system-prompt", instructions].concat(model).concat([q]);
        proc.running = true;
    }

    Process {
        id: proc
        property string asked: ""
        stdout: StdioCollector {
            onStreamFinished: {
                if (proc.asked !== root.question)
                    return;
                const newline = text.indexOf("\n");
                const code = newline < 0 ? text.trim() : text.slice(0, newline);
                const out = newline < 0 ? "" : text.slice(newline + 1).trim();
                root.took = (Date.now() - root.askedAt) / 1000;
                if (code === "0" && out !== "")
                    root.answer = out;
                else
                    root.error = out.split("\n").pop() || `claude stopped with code ${code || "?"}`;
            }
        }
    }

    Process {
        command: ["sh", "-c", root.withPath + "command -v claude"]
        running: true
        onExited: code => root.installed = code === 0
    }
}
