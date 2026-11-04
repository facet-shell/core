-- frameshell for Hyprland (Lua config, Hyprland 0.55+): autostart, shell keybinds, idle.
-- Loaded from your own hyprland.lua with require("frame/shell"); `facet install hypr`
-- adds that line. Descriptions show up in the hotkey overlay (hold Super).

-- Quickshell runs bar, launcher, lockscreen and the rest (also the idle lock and screen
-- off, lockscreen/Lock.qml); frame-wallpaper starts the wallpaper picked in the app;
-- frame-clip keeps what you copy for the launcher
hl.on("hyprland.start", function()
    hl.exec_cmd("qs")
    -- Restarts the shell when it hangs (a hung shell looks like a frozen PC) and keeps its log
    hl.exec_cmd("~/.local/bin/frame-shell-watchdog")
    hl.exec_cmd("~/.local/bin/frame-wallpaper apply")
    -- Clipboard history for the launcher (;)
    hl.exec_cmd("wl-paste --watch ~/.local/bin/frame-clip store")
    -- GoXLR faders and mutes for the shell; does nothing without GoXLR Utility
    hl.exec_cmd("command -v goxlr-daemon >/dev/null && goxlr-daemon")
    -- `facet login auto`: greetd logs in without a greeter, so the session starts locked and
    -- the shell's lockscreen asks for the password instead; without the lock the session
    -- ends (quickshell/.local/bin/frame-start-locked). Only here, at Hyprland's start, never
    -- when the shell alone restarts.
    hl.exec_cmd("~/.local/bin/frame-start-locked")
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

take("SUPER + SPACE", shell("launcher", "toggle"), { description = "frame shell · launcher" })
take("SUPER + C", shell("controlcenter", "toggle"), { description = "frame shell · control center" })
take("SUPER + V", shell("launcher", "clipboard"), { description = "frame shell · clipboard history" })
take("SUPER + W", shell("wallpapers", "toggle"), { description = "frame shell · wallpapers" })
take("SUPER + K", shell("keyboard", "toggle"), { description = "frame shell · keyboard (AULA F75)" })
take("SUPER + G", shell("media", "toggle"), { description = "frame shell · media: screenshots and recordings" })
take("SUPER + comma", shell("settings", "toggle"), { description = "frame shell · settings" })
take("SUPER + L", shell("lock", "lock"), { description = "frame shell · lock" })
-- Hyprland still takes keys when the shell hangs: this restarts it without waiting for the
-- watchdog (frame-shell-watchdog), the lock comes back if it was on
take("SUPER + SHIFT + Escape", hl.dsp.exec_cmd("~/.local/bin/frame-shell-watchdog restart"), { description = "frame shell · restart the shell (when it hangs)" })
-- Ctrl+Alt+Q types an @ and Ctrl+Alt+E a € (the Windows habit; for a keyboard without a
-- working AltGr). Hyprland sends AltGr+key (MOD5) straight to the focused window, so the app
-- sees the real key and no virtual keyboard shows up as a layout change. The launcher is a
-- layer, not a window, so while it is open the character goes to it over IPC instead (else it
-- lands behind it). Vesktop (Chromium on Wayland) types nothing for that AltGr+key: it gets
-- Ctrl+Alt+key itself and the ShellBridge plugin inserts the character.
for key, char in pairs({ q = "@", e = "€" }) do
    take("CTRL + ALT + " .. key:upper(), function()
        local w = hl.get_active_window()
        if #hl.get_layers({ namespace = "qs-launcher" }) > 0 then
            hl.exec_cmd("qs ipc call launcher type " .. char)
        elseif w and w.class == "vesktop" then
            hl.dispatch(hl.dsp.exec_raw("sendshortcut CTRL ALT, " .. key .. ", activewindow"))
        else
            hl.dispatch(hl.dsp.exec_raw("sendshortcut MOD5, " .. key .. ", activewindow"))
        end
    end, { description = "frame shell · type " .. char })
end

-- Media keys (the keyboard's Fn+F7/F8/F9): the distro calls playerctl, which is not always
-- installed; the shell drives the player over MPRIS itself. Locked: also on the lockscreen
take("XF86AudioPlay", shell("player", "toggle"), { locked = true, description = "frame shell · media: play / pause" })
take("XF86AudioPause", shell("player", "toggle"), { locked = true, description = "frame shell · media: play / pause" })
take("XF86AudioNext", shell("player", "next"), { locked = true, description = "frame shell · media: next track" })
take("XF86AudioPrev", shell("player", "prev"), { locked = true, description = "frame shell · media: previous track" })

-- Screenshots (the distro binds Print to grim + slurp; the shell has its own picker)
take("Print", shell("screenshot", "region"), { description = "frame shell · screenshot: region or window" })
take("SHIFT + Print", shell("screenshot", "screen"), { description = "frame shell · screenshot: whole screen" })
take("SUPER + Print", shell("screenshot", "screen"), { description = "frame shell · screenshot: whole screen" })
-- Keyboards without a Print key: the Windows shortcuts (Super+Shift+S was the distro's
-- "move window to special workspace")
take("SUPER + SHIFT + S", shell("screenshot", "region"), { description = "frame shell · screenshot: region or window" })
take("SUPER + CTRL + S", shell("screenshot", "screen"), { description = "frame shell · screenshot: whole screen" })
-- Screen recording: the same picker; the same key (or the dot in the bar) stops it
take("SUPER + SHIFT + R", shell("screenshot", "record"), { description = "frame shell · screen recording: start or stop" })
-- Drawing on the screen (quickshell/draw): Super+P again hides it and gives the screen back,
-- the drawing stays for next time; take() drops the distro's own Super+P first
take("SUPER + P", shell("draw", "toggle"), { description = "frame shell · draw on the screen (again: hide)" })
take("SUPER + SHIFT + P", shell("draw", "clear"), { description = "frame shell · draw: clear the drawing" })
-- Discord voice (quickshell/voice): move the overlay, mute and deafen from anywhere, a game
-- included; Discord needs no keybind of its own for that
take("SUPER + SHIFT + V", shell("voice", "move"), { description = "frame shell · voice overlay: move it (again or Esc: done)" })
take("SUPER + SHIFT + M", shell("voice", "mute"), { description = "frame shell · Discord: mute or unmute" })
take("SUPER + SHIFT + D", shell("voice", "deafen"), { description = "frame shell · Discord: deafen or undeafen" })

-- Windows over each other (on the canvas nothing keeps them apart): Alt+Tab goes to the next
-- window and brings it up, Super+Alt+B sends the active one to the back. Super+Alt+S puts the
-- window into the scratchpad and, pressed on a window in there, takes it out again; Super+S
-- shows and hides the scratchpad (the distro had Super+Shift+S for that, the screenshot now)
take("ALT + Tab", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end, { description = "frame windows · next window, brought up" })
take("SUPER + ALT + B", hl.dsp.window.alter_zorder({ mode = "bottom" }), { description = "frame windows · window to the back" })

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
take("SUPER + Tab", frame_games.toggle, { description = "frame windows · games ↔ desktop (Steam games run on their own workspace)" })
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
end, { description = "frame windows · window into the scratchpad and back (Super+S shows it)" })

hl.config({
    misc = {
        -- A restarted Quickshell can take over the lock after a crash
        allow_session_lock_restore = true,
    },
})

-- Each require is its own scope in Hyprland, so an error in one file leaves the others working
require("frame/apps")
require("frame/hotkeys")

-- Layout picked in `facet install` or with `facet layout tiling|canvas`; the normal
-- tiling needs nothing, the infinite canvas lives in frame/canvas.lua
local function layout()
    local home = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
    local f = io.open(home .. "/frameshell/layout", "r")
    if not f then
        return "tiling"
    end
    local mode = (f:read("*l") or ""):match("^%s*(%a+)") or "tiling"
    f:close()
    return mode
end
if layout() == "canvas" then
    require("frame/canvas")
end
-- Written by `facet theme`; missing until the first run, which must not stop the rest
pcall(require, "frame/colors")
