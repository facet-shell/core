import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// What every style starts with, before its own bar and panels: a style's shell.qml puts
// `Core {}` first in its ShellRoot. Nothing in here draws anything.
Scope {
    // Singletons only come to life when something uses them; the Spotify one must listen
    // for the Spicetify extension from the start, not from the first "s" in the launcher
    Scope {
        Component.onCompleted: {
            Spotify.refresh();
            // The app rules for the virtual channels (does nothing without them)
            Channels.start();
            // A shell that died while the screen was locked left the wallpaper frozen
            // (frame-wallpaper pause); this one lets it run again
            Quickshell.execDetached(["sh", "-c", 'state="${XDG_STATE_HOME:-$HOME/.local/state}/frameshell/wallpaper-backend"; [ "$(cat "$state" 2>/dev/null)" = glint ] && exit 0; w="$HOME/.local/bin/frame-wallpaper"; [ -x "$w" ] && "$w" resume-if-paused']);
        }
    }

    // The media keys (frame/shell.lua): qs ipc call player toggle|next|prev, no playerctl
    // needed. They act on the player that started playing last, so a second press plays the
    // one the first paused (with Spotify and a video both playing, it went to the other one);
    // without one: Spotify if it plays, else whatever plays, then Spotify, then any player
    Scope {
        id: mediaKeys

        property MprisPlayer last: null
        readonly property MprisPlayer player: {
            const list = Mpris.players.values;
            if (last && list.includes(last))
                return last;
            const spotify = list.find(p => p.identity === "Spotify");
            return (spotify?.isPlaying ? spotify : null) ?? list.find(p => p.isPlaying) ?? spotify ?? list[0] ?? null;
        }

        // The player a key acts on stays the target, also once it is paused
        function take() {
            last = player;
            return last;
        }

        Variants {
            model: Mpris.players.values

            Connections {
                required property MprisPlayer modelData
                target: modelData
                function onIsPlayingChanged() {
                    if (modelData.isPlaying)
                        mediaKeys.last = modelData;
                }
            }
        }

        IpcHandler {
            target: "player"

            function toggle(): void { mediaKeys.take()?.togglePlaying(); }
            function next(): void { mediaKeys.take()?.next(); }
            function prev(): void { mediaKeys.take()?.previous(); }
        }
    }
}
