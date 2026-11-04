import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import qs.ui

// The login screen, in the lockscreen's clothes: clock, date, one password field for the
// one person who uses this machine. greetd runs it (frame-greeter-session) and starts the
// session once the password is right. greeter.json next to this file says who and what:
//   { "user": "name", "command": ["/usr/bin/start-hyprland"] }
// Installed by `facet login`; `qs -p greeter` shows it inside a running desktop too (then
// greetd is not there and the field only says so).
ShellRoot {
    id: root

    property string user: ""
    property var command: []
    property string hostname: ""

    // What the field says underneath
    property string status: ""
    property bool failed: false
    property bool busy: false
    property bool starting: false
    // greetd asked for the password and waits
    property bool asked: false
    property string pending: ""
    property bool appeared: false

    FileView {
        // Next to this file, wherever it is installed
        path: Qt.resolvedUrl("greeter.json").toString().replace("file://", "")
        printErrors: false
        onLoaded: {
            try {
                const data = JSON.parse(text());
                root.user = data.user ?? "";
                root.command = data.command ?? [];
            } catch (e) {
                root.status = "greeter.json is not readable";
            }
            root.begin();
        }
        onLoadFailed: root.status = "no greeter.json · run: facet login"
    }

    FileView {
        path: "/etc/hostname"
        printErrors: false
        onLoaded: root.hostname = text().trim()
    }

    function begin() {
        if (!Greetd.available) {
            status = "greetd is not running here";
            return;
        }
        if (user === "") {
            status = "greeter.json names no user";
            return;
        }
        asked = false;
        Greetd.createSession(user);
    }

    // Enter: send the password now, or as soon as greetd asks for it
    function submit(password) {
        if (password === "" || busy || starting)
            return;
        failed = false;
        busy = true;
        if (asked) {
            asked = false;
            Greetd.respond(password);
        } else {
            pending = password;
        }
    }

    Connections {
        target: Greetd

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                if (root.pending !== "") {
                    const p = root.pending;
                    root.pending = "";
                    Greetd.respond(p);
                } else {
                    // A further question after the password (expired password, second
                    // factor): the field has to take an answer again
                    // (busy means something was already sent, so show what PAM wants now)
                    if (root.busy && message !== "")
                        root.status = message.toLowerCase();
                    root.asked = true;
                    root.busy = false;
                }
            } else if (message !== "") {
                root.status = message.toLowerCase();
            }
        }

        function onAuthFailure(message) {
            root.busy = false;
            root.pending = "";
            root.failed = true;
            root.status = "wrong password";
            // A failed attempt ends the greetd session; a new one asks again
            Qt.callLater(root.begin);
        }

        function onReadyToLaunch() {
            root.busy = false;
            root.starting = true;
            root.status = "starting …";
            Greetd.launch(root.command.length > 0 ? root.command : ["/usr/bin/start-hyprland"], [], true);
        }

        function onError(error) {
            root.busy = false;
            root.pending = "";
            root.status = String(error).toLowerCase();
            // The session is gone after an error; start a new one so Enter works again
            retry.restart();
        }
    }

    // Not straight away: when greetd itself is the problem, this would spin
    Timer {
        id: retry
        interval: 2000
        onTriggered: root.begin()
    }

    Component.onCompleted: appeared = true

    // One plain window: the greeter compositors (noctalia's, cage) show it full screen and
    // know no layer shell. Inside a desktop it is just a window.
    FloatingWindow {
        id: window

        readonly property bool primary: true

        title: "frameshell login"
        color: Theme.bg
        minimumSize: Qt.size(960, 540)
        implicitWidth: 1920
        implicitHeight: 1080

        // Everything fades and rises in, like the lockscreen does
        property real progress: root.appeared ? 1 : 0
        Behavior on progress {
            NumberAnimation { duration: Theme.anim.slow; easing.type: Easing.OutCubic }
        }
        function stage(start) {
            return Math.max(0, Math.min(1, (progress - start) / (1 - start)));
        }

        Item {
            anchors.fill: parent

            component Label: Text {
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: Theme.size.normal
            }

            // Top right: who is logging in where
            Label {
                visible: window.primary
                anchors { top: parent.top; right: parent.right; topMargin: 56; rightMargin: 80 }
                text: `${root.user !== "" ? root.user : "login"}@${root.hostname}`
                color: Theme.muted
                font.pixelSize: 18
                opacity: window.stage(0.45)
            }

            SystemClock {
                id: clock
                precision: SystemClock.Minutes
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 0

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Qt.formatTime(clock.date, "hh:mm")
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.size.clock
                    font.weight: Font.Light
                    font.letterSpacing: -4
                    opacity: window.stage(0.15)
                    transform: Translate { y: 26 * (1 - window.stage(0.15)) }
                }

                Label {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 14
                    Layout.bottomMargin: 64
                    text: clock.date.toLocaleDateString(Qt.locale("en_GB"), "dddd · d MMMM").toLowerCase()
                    color: Theme.muted
                    font.pixelSize: Theme.size.large
                    opacity: window.stage(0.15)
                    transform: Translate { y: 26 * (1 - window.stage(0.15)) }
                }

                Frame {
                    id: field

                    visible: window.primary
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 560
                    Layout.preferredHeight: 78
                    label: "login"
                    padding: 0
                    borderColor: root.failed ? Theme.danger : Theme.primary
                    labelColor: borderColor
                    opacity: window.stage(0.25)
                    transform: [
                        Translate { y: 26 * (1 - window.stage(0.25)) },
                        Translate { id: shake }
                    ]

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 26
                        anchors.rightMargin: 26
                        spacing: 16

                        Text {
                            text: "❯"
                            color: Theme.primary
                            font.family: Theme.font
                            font.pixelSize: 24
                            font.weight: Font.Medium
                        }

                        TextInput {
                            id: input

                            Layout.fillWidth: true
                            focus: true
                            enabled: !root.busy && !root.starting
                            echoMode: TextInput.Password
                            passwordCharacter: "•"
                            color: Theme.secondary
                            font.family: Theme.font
                            font.pixelSize: 24
                            font.letterSpacing: 8
                            cursorDelegate: Rectangle { width: 12; color: Theme.secondary }

                            onTextChanged: root.failed = false
                            onAccepted: {
                                root.submit(text);
                                text = "";
                            }
                            Keys.onEscapePressed: text = ""
                            Component.onCompleted: forceActiveFocus()
                        }
                    }

                    SequentialAnimation {
                        id: shakeAnimation
                        NumberAnimation { target: shake; property: "x"; to: -12; duration: 50 }
                        NumberAnimation { target: shake; property: "x"; to: 12; duration: 70 }
                        NumberAnimation { target: shake; property: "x"; to: -8; duration: 70 }
                        NumberAnimation { target: shake; property: "x"; to: 6; duration: 60 }
                        NumberAnimation { target: shake; property: "x"; to: 0; duration: 50 }
                    }

                    Connections {
                        target: root
                        function onFailedChanged() {
                            if (root.failed)
                                shakeAnimation.restart();
                        }
                    }
                }

                Label {
                    visible: window.primary
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 16
                    text: root.busy ? "checking…" : root.status !== "" ? root.status : "enter to log in · esc to clear"
                    color: root.failed ? Theme.danger : Theme.muted
                    font.pixelSize: 16
                    opacity: window.stage(0.25)
                }
            }

            // Bottom right: what it is
            Label {
                visible: window.primary
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 80; bottomMargin: 80 }
                text: "frameshell"
                color: Theme.frame
                font.pixelSize: Theme.size.small
                opacity: window.stage(0.45)
            }
        }
    }
}
