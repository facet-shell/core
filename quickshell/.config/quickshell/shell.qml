import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.bar
import qs.canvas
import qs.controlcenter
import qs.draw
import qs.editor
import qs.gallery
import qs.hotkeys
import qs.keyboard
import qs.launcher
import qs.lockscreen
import qs.media
import qs.notifications
import qs.osd
import qs.screenshot
import qs.services
import qs.settings
import qs.voice
import qs.wallpapers

// Entry point. Each module is added here as it gets built.
ShellRoot {
    // Singletons only come to life when something uses them; the Spotify one must listen
    // for the Spicetify extension from the start, not from the first "s" in the launcher
    Scope {
        Component.onCompleted: {
            Spotify.refresh();
            // A shell that died while the screen was locked left the wallpaper frozen
            // (frame-wallpaper pause); this one lets it run again
            Quickshell.execDetached(["sh", "-c", 'w="$HOME/.local/bin/frame-wallpaper"; [ -x "$w" ] && "$w" resume-if-paused']);
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

    Lock {
        id: lock

        // Panels leave the screen before the lockscreen takes its snapshot
        onAboutToLock: {
            controlCenter.hide();
            launcher.hide();
            history.hide();
            wallpapers.hide();
            keyboard.hide();
            hotkeys.hide();
            overview.close();
        }
    }

    Bar {
        hidden: lock.active
        onControlCenterRequested: screen => {
            history.hide();
            controlCenter.toggle(screen);
        }
        onHistoryRequested: screen => {
            controlCenter.hide();
            history.toggle(screen);
        }
    }

    ControlCenter {
        id: controlCenter
        onLockRequested: lock.lock()
        onWallpapersRequested: wallpapers.show()
        onKeyboardRequested: keyboard.show()
        onSettingsRequested: settings.show()
    }

    Launcher {
        id: launcher
    }

    // Separate wallpaper app (Super+W)
    // Still wallpapers and the plain background (the moving ones come from frame-wallpaper)
    Backdrop {}

    WallpaperApp {
        id: wallpapers
    }

    // AULA F75 lighting, Fn keys and per-key colors (Super+K, keyboard package)
    KeyboardApp {
        id: keyboard
    }

    // Popups step aside while a panel on the right is open
    Popups {
        rightOffset: controlCenter.open ? (controlCenter.mixerOpen ? 1318 : 626)
            : history.open ? 486
            : 14
    }

    History {
        id: history
    }

    SpotifyPopup {}

    // Discord voice: who is in your channel and who talks, on the left (Super+Shift+V moves it)
    VoiceOverlay {
        hidden: lock.active
    }

    // Hold Super for 1.5 seconds (hypr/frame/hotkeys.lua); closed while locked or
    // while Super is busy with the canvas overview
    HotkeyOverlay {
        id: hotkeys
        hidden: lock.active || overview.open
    }

    // Infinite canvas: Super+wheel zooms out to every window (frame layout canvas)
    CanvasOverview {
        id: overview
        hidden: lock.active
    }

    // Infinite canvas: dragging empty canvas moves the view
    CanvasDesk {}

    // Infinite canvas: pictures of the windows on screen, for the overview's off-screen ones
    CanvasThumbs {}

    // Shows fader, mute, volume and layout changes; never on the lockscreen
    Osd {
        hidden: lock.active
    }

    // Print: region or window, Shift+Print: the screen (hypr/frame/shell.lua)
    Screenshot {
        hidden: lock.active
    }

    // Editors for recordings (cuts, blur boxes, pictures, levels per channel) and pictures
    // (blur, pictures, crop): "edit" on a notification or in the media app; own window
    EditorWindow {}

    // Screenshots and recordings: browse, delete many at once, open in the editor (Super+G)
    MediaApp {
        id: media
    }

    // Theme, layout, the shell's own settings, sound, modules and system (Super+, or
    // "settings" in the control center)
    SettingsApp {
        id: settings
        onWallpapersRequested: wallpapers.show()
        onKeyboardRequested: keyboard.show()
    }

    // Super+P: draw on the screen, again hides it; the drawing stays (and moves with the
    // infinite canvas). Gone while locked.
    DrawOverlay {
        hidden: lock.active
    }
}
