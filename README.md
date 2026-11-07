<p align="center">
  <a href="https://github.com/facet-shell"><img src="https://raw.githubusercontent.com/facet-shell/.github/main/brand/mark.svg" alt="facet" width="64"></a>
</p>

<h3 align="center">core</h3>

<p align="center">What every style shares: services, bridges, settings and the Hyprland config.</p>

<p align="center"><sub><a href="https://github.com/facet-shell">facet</a> · <b>core</b> · <a href="https://github.com/facet-shell/cli">cli</a> &nbsp;|&nbsp; <a href="https://github.com/facet-shell/style-tui">tui</a> · <a href="https://github.com/facet-shell/style-bloom">bloom</a> &nbsp;|&nbsp; <a href="https://github.com/facet-shell/terminal">terminal</a> · <a href="https://github.com/facet-shell/spotify">spotify</a> · <a href="https://github.com/facet-shell/discord">discord</a> · <a href="https://github.com/facet-shell/steam">steam</a> · <a href="https://github.com/facet-shell/zed">zed</a> · <a href="https://github.com/facet-shell/zen">zen</a> · <a href="https://github.com/facet-shell/dolphin">dolphin</a> · <a href="https://github.com/facet-shell/keyboard">keyboard</a> &nbsp;|&nbsp; <a href="https://facet-shell.github.io">website</a> · <a href="https://github.com/orgs/facet-shell/projects/1">board</a></sub></p>

What every facet style shares and nothing that draws: the Quickshell services and bridges
(notifications and their rules, Discord, Steam, Spotify, GoXLR, sound, game mode, screen
recording, clipboard, timers, weather, stats, updates), the settings (`config/Config.qml`),
the infinite canvas logic, the Hyprland Lua config, the wallpaper helper and the shell's
scripts. A style ([style-tui](https://github.com/facet-shell/style-tui) or
[style-bloom](https://github.com/facet-shell/style-bloom)) puts its bar, panels and popups on top and starts with `Core {}`. Always installed.

Part of [facet](https://github.com/facet-shell); install it with the `facet` command:

```bash
facet add core
```

Files in the package folders are linked into your home with GNU Stow; files with colors come
from `templates/` and are written by `facet theme` in the active theme. Ideas and bugs:
[the board](https://github.com/orgs/facet-shell/projects/1).

## Sound with and without a GoXLR

The channels (System, Game, Chat, Music: apps routed onto them in the app mixer, a fader and
a mute each in the control center, a track each in a recording) come from one of two places;
`audioChannels` in the settings (sound) picks one, `auto` takes the first that is there:

| | GoXLR | virtual channels | neither |
|---|---|---|---|
| where they come from | GoXLR Utility's outputs and mic inputs | `facet audio channels on`: PipeWire loopbacks into your output | – |
| app mixer | a chip per channel | a chip per channel, rules put new apps on theirs (Vesktop → Chat, Spotify → Music, the running game → Game) | a device list per app, master rows for output and mic |
| control center | the physical faders (levels follow, mutes work) | a slider and a mute per channel, then the real output | volume and mic mute |
| recording | a track per GoXLR output and input, plus the stream mix | a track per channel and the mic | the default output and the mic |
| game mode | loads `goxlrGameProfile` | the game's sound lands on Game | – |
| OSD | fader moves and the mic button | channel levels and mutes | the default output's volume |
| lights | `facet goxlr` in the theme's colors | – | – |

The virtual channels are optional and only exist once `facet audio channels on` made them:
`~/.config/pipewire/pipewire.conf.d/facet-channels.conf` (one loopback per channel, sinks
`facet-<name>`, System becomes the default output) and `~/.local/state/frameshell/audio-channels.json`
for the shell. Sinks of the same name you already have are taken over instead of doubled, and
an EasyEffects sink works as the output they play into. `facet audio channels output <sink>`
moves them to another device, `facet audio channels off` removes all of it and puts every app
back on the output. Without them and without a GoXLR nothing about channels shows; the shell
never writes PipeWire config itself (`services/Audio.qml`, `services/Channels.qml`).

## Glint wallpaper backend

Install the wallpaper, Quickshell and Hyprland packages together with
`facet install quickshell hypr wallpaper`. The installer selects Glint with
`~/.local/state/frameshell/wallpaper-backend`; legacy configurations keep their
existing backend until installation succeeds. `frame-glint-start` reuses a running
daemon and migrates legacy assignments only when Glint has no saved state.

The shared Quickshell service talks to Glint over its JSON socket, combines its
installed Workshop library with local images and videos, and exposes per-display
rendering and project settings. Changing a common option for all displays preserves
each display's wallpaper and other options. A disconnected Glint backend reports
an error instead of starting a legacy renderer.

Controller and migration checks, without a GPU or running daemon:

```sh
python3 tests/glint/run-smoke.py
python3 tests/glint/test-helper.py
python3 tests/glint/run-smoke.py --bloom /path/to/style-bloom
python3 tests/glint/run-smoke.py --tui /path/to/style-tui
```

These checks use an asynchronous fake transport; visual rendering and desktop
compositor behavior still need a real-session check.
