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
