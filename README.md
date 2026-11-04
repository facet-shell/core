# facet · core

What every facet style shares and nothing that draws: the Quickshell services and bridges
(notifications and their rules, Discord, Steam, Spotify, GoXLR, sound, game mode, screen
recording, clipboard, timers, weather, stats, updates), the settings (`config/Config.qml`),
the infinite canvas logic, the Hyprland Lua config, the wallpaper helper and the shell's
scripts. A style ([style-tui](https://github.com/facet-shell/style-tui)) puts its bar, panels
and popups on top and starts with `Core {}`. Always installed.

Part of [facet](https://github.com/facet-shell); install it with the `facet` command:

```bash
facet add core
```

Files in the package folders are linked into your home with GNU Stow; files with colors come
from `templates/` and are written by `facet theme` in the active theme. Ideas and bugs:
[the board](https://github.com/orgs/facet-shell/projects/1).
