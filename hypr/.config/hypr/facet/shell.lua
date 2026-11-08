-- facet for Hyprland (Lua config, Hyprland 0.55+): autostart, shell keybinds, idle.
-- Loaded from your own hyprland.lua with require("facet/shell"); `facet install hypr`
-- adds that line. Descriptions show up in the hotkey overlay (hold Super).

-- Glint handles wallpaper transitions itself; compositor fades can hide a background layer.
hl.layer_rule({
    name = "facet-glint",
    match = { namespace = "^glint$" },
    no_anim = true,
})

-- Quickshell runs bar, launcher, lockscreen and the rest (also the idle lock and screen
-- off, lockscreen/Lock.qml); glint starts the selected wallpaper;
-- facet-clip keeps what you copy for the launcher
hl.on("hyprland.start", function()
    hl.exec_cmd("qs")
    -- Restarts the shell when it hangs (a hung shell looks like a frozen PC) and keeps its log
    hl.exec_cmd("~/.local/bin/facet-shell-watchdog")
    hl.exec_cmd([[sh -c 'state="${XDG_STATE_HOME:-$HOME/.local/state}/facet/wallpaper-backend"; if [ -x "$HOME/.local/bin/glint" ] && [ "$(cat "$state" 2>/dev/null)" = glint ]; then exec "$HOME/.local/bin/facet-glint-start"; else exec "$HOME/.local/bin/facet-wallpaper" apply; fi']])
    -- Clipboard history for the launcher (;)
    hl.exec_cmd("wl-paste --watch ~/.local/bin/facet-clip store")
    -- GoXLR faders and mutes for the shell; does nothing without GoXLR Utility
    hl.exec_cmd("command -v goxlr-daemon >/dev/null && goxlr-daemon")
    -- `facet login auto`: greetd logs in without a greeter, so the session starts locked and
    -- the shell's lockscreen asks for the password instead; without the lock the session
    -- ends (quickshell/.local/bin/facet-start-locked). Only here, at Hyprland's start, never
    -- when the shell alone restarts.
    hl.exec_cmd("~/.local/bin/facet-start-locked")
end)

-- A key bound twice runs both binds, and the distro config (CachyOS: config/binds.lua)
-- has its own on some of frame's keys, so those are dropped first. hl.unbind takes one
-- bind per call and wants the modifiers spelled as the other bind wrote them (CachyOS:
-- CONTROL, not CTRL); the key itself may differ in case. apps.lua and canvas.lua do the same.
local function take(keys, dispatcher, opts)
    for _, spelling in ipairs({ keys, (keys:gsub("CTRL", "CONTROL")) }) do
        for _ = 1, 4 do
            pcall(hl.unbind, spelling)
        end
    end
    return hl.bind(keys, dispatcher, opts)
end

local function shell(target, action)
    return hl.dsp.exec_cmd("qs ipc call " .. target .. " " .. action)
end

take("SUPER + SPACE", shell("launcher", "toggle"), { description = "facet shell · launcher" })
take("SUPER + C", shell("controlcenter", "toggle"), { description = "facet shell · control center" })
take("SUPER + V", shell("launcher", "clipboard"), { description = "facet shell · clipboard history" })
take("SUPER + W", shell("wallpapers", "toggle"), { description = "facet shell · wallpapers" })
take("SUPER + K", shell("keyboard", "toggle"), { description = "facet shell · keyboard (AULA F75)" })
take("SUPER + G", shell("media", "toggle"), { description = "facet shell · media: screenshots and recordings" })
take("SUPER + comma", shell("settings", "toggle"), { description = "facet shell · settings" })
take("SUPER + L", shell("lock", "lock"), { description = "facet shell · lock" })
-- Hyprland still takes keys when the shell hangs: this restarts it without waiting for the
-- watchdog (facet-shell-watchdog), the lock comes back if it was on
take("SUPER + SHIFT + Escape", hl.dsp.exec_cmd("~/.local/bin/facet-shell-watchdog restart"), { description = "facet shell · restart the shell (when it hangs)" })
-- Ctrl+Alt+Q types an @ and Ctrl+Alt+E a € (the Windows habit; for a keyboard without a
-- working AltGr). Hyprland sends AltGr+key (MOD5) straight to the focused window, so the app
-- sees the real key and no virtual keyboard shows up as a layout change. The launcher is a
-- layer, not a window, so while it is open the character goes to it over IPC instead (else it
-- lands behind it). Vesktop (Chromium on Wayland) types nothing for that AltGr+key: it gets
-- Ctrl+Alt+key itself and the ShellBridge plugin inserts the character. Ghostty too: with Ctrl
-- and Alt still held it read the AltGr+key as a control sequence; its config types the
-- character for ctrl+alt+q/e (terminal module).
for key, char in pairs({ q = "@", e = "€" }) do
    take("CTRL + ALT + " .. key:upper(), function()
        local w = hl.get_active_window()
        if #hl.get_layers({ namespace = "qs-launcher" }) > 0 then
            hl.exec_cmd("qs ipc call launcher type " .. char)
        elseif w and (w.class == "vesktop" or w.class == "com.mitchellh.ghostty") then
            hl.dispatch(hl.dsp.exec_raw("sendshortcut CTRL ALT, " .. key .. ", activewindow"))
        else
            hl.dispatch(hl.dsp.exec_raw("sendshortcut MOD5, " .. key .. ", activewindow"))
        end
    end, { description = "facet shell · type " .. char })
end

-- Media keys (the keyboard's Fn+F7/F8/F9): the distro calls playerctl, which is not always
-- installed; the shell drives the player over MPRIS itself. Locked: also on the lockscreen
take("XF86AudioPlay", shell("player", "toggle"), { locked = true, description = "facet shell · media: play / pause" })
take("XF86AudioPause", shell("player", "toggle"), { locked = true, description = "facet shell · media: play / pause" })
take("XF86AudioNext", shell("player", "next"), { locked = true, description = "facet shell · media: next track" })
take("XF86AudioPrev", shell("player", "prev"), { locked = true, description = "facet shell · media: previous track" })
-- Volume keys and a keyboard's knob: the shell turns what settings → sound → output says
-- (the GoXLR's System channel or the default output)
take("XF86AudioRaiseVolume", shell("volume", "up"), { locked = true, repeating = true, description = "facet shell · volume up" })
take("XF86AudioLowerVolume", shell("volume", "down"), { locked = true, repeating = true, description = "facet shell · volume down" })
take("XF86AudioMute", shell("volume", "mute"), { locked = true, description = "facet shell · mute" })

-- Screenshots (the distro binds Print to grim + slurp; the shell has its own picker)
take("Print", shell("screenshot", "region"), { description = "facet shell · screenshot: region or window" })
take("SHIFT + Print", shell("screenshot", "screen"), { description = "facet shell · screenshot: whole screen" })
take("SUPER + Print", shell("screenshot", "screen"), { description = "facet shell · screenshot: whole screen" })
-- Keyboards without a Print key: the Windows shortcuts (Super+Shift+S was the distro's
-- "move window to special workspace")
take("SUPER + SHIFT + S", shell("screenshot", "region"), { description = "facet shell · screenshot: region or window" })
take("SUPER + CTRL + S", shell("screenshot", "screen"), { description = "facet shell · screenshot: whole screen" })
-- Screen recording: the same picker; the same key (or the dot in the bar) stops it
take("SUPER + SHIFT + R", shell("screenshot", "record"), { description = "facet shell · screen recording: start or stop" })
-- Drawing on the screen (quickshell/draw): Super+P again hides it and gives the screen back,
-- the drawing stays for next time; take() drops the distro's own Super+P first
take("SUPER + P", shell("draw", "toggle"), { description = "facet shell · draw on the screen (again: hide)" })
take("SUPER + SHIFT + P", shell("draw", "clear"), { description = "facet shell · draw: clear the drawing" })
-- Discord voice (quickshell/voice): move the overlay, mute and deafen from anywhere, a game
-- included; Discord needs no keybind of its own for that
take("SUPER + SHIFT + V", shell("voice", "move"), { description = "facet shell · voice overlay: move it (again or Esc: done)" })
take("SUPER + SHIFT + M", shell("voice", "mute"), { description = "facet shell · Discord: mute or unmute" })
take("SUPER + SHIFT + D", shell("voice", "deafen"), { description = "facet shell · Discord: deafen or undeafen" })

-- Windows over each other (on the canvas nothing keeps them apart): Alt+Tab goes to the next
-- window and brings it up, Super+Alt+B sends the active one to the back. Super+Alt+S puts the
-- window into the scratchpad and, pressed on a window in there, takes it out again; Super+S
-- shows and hides the scratchpad (the distro had Super+Shift+S for that, the screenshot now)
take("ALT + Tab", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end, { description = "facet windows · next window, brought up" })
take("SUPER + ALT + B", hl.dsp.window.alter_zorder({ mode = "bottom" }), { description = "facet windows · window to the back" })

-- Steam games and gamescope get a workspace of their own from the distro's rules
-- (config/windowrules.lua: name:gaming) and the screen switches to it, so the desktop is out
-- of sight while a game runs. Super+Tab goes back to the desktop and to the games again;
-- with several games open Alt+Tab goes from one to the next (the focused one takes the
-- fullscreen, misc.on_focus_under_fullscreen), and the launcher's Enter on a running game
-- shows that one. Also for the bar: frame_games.toggle()
local GAME_WS = "gaming"
frame_games = {}
function frame_games.toggle()
    local mon = hl.get_active_monitor()
    local ws = mon and mon.active_workspace
    if ws and ws.name == GAME_WS then
        local last = hl.get_last_workspace(mon)
        if last and not last.special and last.name ~= GAME_WS then
            hl.dispatch(hl.dsp.focus({ workspace = tostring(last.id) }))
        else
            hl.dispatch(hl.dsp.focus({ workspace = "previous" }))
        end
        return
    end
    for _, w in ipairs(hl.get_workspaces() or {}) do
        if w.name == GAME_WS and (w.windows or 0) > 0 then
            hl.dispatch(hl.dsp.focus({ workspace = "name:" .. GAME_WS }))
            return
        end
    end
end
-- Games and their launch windows by the same marks the distro's rules use; Wine/Proton
-- windows (.exe) count too, so a game outside Steam is never moved away
function frame_games.is_game(w)
    local class = w.class or ""
    return class:match("^steam_app") ~= nil or class == "gamescope" or class:match("%.exe$") ~= nil
        or w.content_type == "game" or (class == "steam" and (w.title or ""):match("^Launching") ~= nil)
end

-- The monitor's desktop workspace: the last one before the games, else its first normal one
function frame_games.desktop(mon)
    local last = hl.get_last_workspace(mon)
    if last and not last.special and last.name ~= GAME_WS then
        return tostring(last.id)
    end
    for _, w in ipairs(hl.get_workspaces() or {}) do
        if w.monitor and w.monitor.name == mon.name and not w.special and w.name ~= GAME_WS then
            return tostring(w.id)
        end
    end
    return "1"
end

-- An app started while the games are on screen opened on the games workspace and was gone
-- with the next Super+Tab; it goes to the desktop instead and the screen follows it
hl.on("window.open", function(w)
    local ws = w.workspace
    local mon = w.monitor
    if not (ws and mon and ws.name == GAME_WS) or frame_games.is_game(w) then
        return
    end
    local active = mon.active_workspace
    if not (active and active.name == GAME_WS) then
        return
    end
    local address = w.address
    hl.dispatch(hl.dsp.window.move({ workspace = frame_games.desktop(mon), window = "address:" .. address }))
    -- The canvas placed it in the games' view; into the desktop's view once the move is done
    if frame_canvas then
        hl.timer(function()
            frame_canvas.into_view(address)
        end, { timeout = 50, type = "oneshot" })
    end
end)
take("SUPER + Tab", frame_games.toggle, { description = "facet windows · games ↔ desktop (Steam games run on their own workspace)" })
take("SUPER + ALT + S", function()
    local w = hl.get_active_window()
    if not w then
        return
    end
    if w.workspace and w.workspace.special then
        -- Out again: onto the monitor's normal workspace, under the scratchpad
        local mon = hl.get_active_monitor()
        local ws = mon and mon.active_workspace
        hl.dispatch(hl.dsp.window.move({ workspace = ws and ws.name or "e+0" }))
    else
        hl.dispatch(hl.dsp.window.move({ workspace = "special" }))
    end
end, { description = "facet windows · window into the scratchpad and back (Super+S shows it)" })

hl.config({
    misc = {
        -- A restarted Quickshell can take over the lock after a crash
        allow_session_lock_restore = true,
    },
})

-- Each require is its own scope in Hyprland, so an error in one file leaves the others working
require("facet/apps")
require("facet/hotkeys")

-- Layout picked in `facet install` or with `facet layout tiling|canvas`; the normal
-- tiling needs nothing, the infinite canvas lives in facet/canvas.lua
local function layout()
    local home = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
    local f = io.open(home .. "/facet/layout", "r")
    if not f then
        return "tiling"
    end
    local mode = (f:read("*l") or ""):match("^%s*(%a+)") or "tiling"
    f:close()
    return mode
end
if layout() == "canvas" then
    require("facet/canvas")
end
-- Written by `facet theme`; missing until the first run, which must not stop the rest
pcall(require, "facet/colors")
