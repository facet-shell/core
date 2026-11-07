-- Apps outside Quickshell: Dolphin, Zed, Zen. Loaded from facet/shell.lua.

-- Qt apps (Dolphin) take style, fonts and the theme palette from qt6ct
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
-- Without Plasma, KDE apps find no application menu and "Open with" stays empty;
-- archlinux-xdg-menu provides arch-applications.menu
hl.env("XDG_MENU_PREFIX", "arch-")

-- Takes the keys over from the distro config (see shell.lua)
local function take(keys, dispatcher, opts)
    for _, spelling in ipairs({ keys, (keys:gsub("CTRL", "CONTROL")) }) do
        for _ = 1, 4 do
            pcall(hl.unbind, spelling)
        end
    end
    return hl.bind(keys, dispatcher, opts)
end

take("SUPER + E", hl.dsp.exec_cmd("dolphin"), { description = "frame apps · Dolphin" })
take("SUPER + B", hl.dsp.exec_cmd("zen-browser"), { description = "frame apps · Zen" })
-- Programs that ask for $BROWSER (gh auth login, xdg-open fallbacks) get Zen, not the
-- distro's firefox; the autostart pushes Hyprland's environment to systemd, so
-- terminals opened later see it too
hl.env("BROWSER", "zen-browser")
take("SUPER + SHIFT + E", hl.dsp.exec_cmd("zeditor"), { description = "frame apps · Zed" })
