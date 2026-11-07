-- Hold Super for a second and a half: the hotkey overlay opens; letting go closes it.
-- Loaded from facet/shell.lua. Quickshell draws the overlay (qs ipc call hotkeys …).
--
-- It stays closed when Super is used for something else in the meantime: another key
-- (Super+Space, Super+1, …) or a window drag with Super and the mouse.

local HOLD_MS = 1500
local TICK_MS = 100
-- Super_L and Super_R: XKB keycodes (evdev KEY_LEFTMETA/RIGHTMETA + 8) and the raw
-- evdev codes, whichever Hyprland hands over
local SUPER = { [133] = true, [134] = true, [125] = true, [126] = true }
-- A cursor that moved this far means Super is dragging or resizing a window; a hand that
-- rests on the mouse moves less than that
local DRAG_PX = 160

local held, used, shown, elapsed, start = false, false, false, 0, nil

local function overlay(action)
    hl.exec_cmd("qs ipc call hotkeys " .. action)
end

-- ── Hotkey hints on the keyboard ────────────────────────────
-- While modifiers are held, the shell lights the keys that do something with them on an
-- AULA F75 (quickshell/services/Keyboard.qml): Super with anything, or two others together
-- (Ctrl+Alt, Ctrl+Shift). A lone Shift or Ctrl is typing. The shell hears about it a moment
-- after the modifiers settle, so Ctrl+C and Super+Space do not light anything.
--
-- The two code sets cannot be mixed in one table: XKB's Shift (50) is evdev's M, its Ctrl
-- (37) evdev's K, and the other way round evdev's Shift (42) is XKB's G. So the set is
-- learned from the first Super press (125/126 evdev, 133/134 XKB); until then only Super
-- itself counts.
local MOD_CODES = {
    evdev = {
        [125] = "super", [126] = "super", [42] = "shift", [54] = "shift",
        [29] = "ctrl", [97] = "ctrl", [56] = "alt", [100] = "alt",
    },
    xkb = {
        [133] = "super", [134] = "super", [50] = "shift", [62] = "shift",
        [37] = "ctrl", [105] = "ctrl", [64] = "alt", [108] = "alt",
    },
}
local MODS = nil -- one of MOD_CODES once Super was pressed

local function modOf(keycode)
    if not MODS then
        if keycode == 125 or keycode == 126 then
            MODS = MOD_CODES.evdev
        elseif keycode == 133 or keycode == 134 then
            MODS = MOD_CODES.xkb
        else
            return nil
        end
    end
    return MODS[keycode]
end
local MODS_DELAY_MS = 200
local down = {}   -- modifier name -> true while a key of it is held
local told = ""   -- what the shell knows

local function modsText()
    local out = {}
    for _, m in ipairs({ "super", "ctrl", "alt", "shift" }) do
        if down[m] then
            out[#out + 1] = m
        end
    end
    return table.concat(out, "+")
end

local function tell(text)
    if text ~= told then
        told = text
        hl.exec_cmd("qs ipc call keyboard mods '" .. text .. "'")
    end
end

local modsTimer = hl.timer(function()
    local text = modsText()
    if text:find("super", 1, true) or text:find("+", 1, true) then
        tell(text)
    end
end, { timeout = MODS_DELAY_MS, type = "oneshot" })
modsTimer:set_enabled(false)

local function modifierChanged()
    modsTimer:set_enabled(false)
    if modsText() == "" then
        tell("")
    else
        modsTimer:set_enabled(true)
    end
end

local function cursorMoved()
    local now = hl.get_cursor_pos()
    if not start or not now then
        return false
    end
    return math.abs(now.x - start.x) > DRAG_PX or math.abs(now.y - start.y) > DRAG_PX
end

-- Counting ticks instead of one long timeout: re-enabling a timer then never has to
-- restart it, and a tick is short enough to feel exact
local tick = hl.timer(function()
    if not held or used or shown then
        return
    end
    elapsed = elapsed + TICK_MS
    if cursorMoved() then
        used = true
    elseif elapsed >= HOLD_MS then
        shown = true
        overlay("open")
    end
end, { timeout = TICK_MS, type = "repeat" })
tick:set_enabled(false)

-- state: 0 released, 1 pressed, 2 repeated
hl.on("input.keyboard.key", function(keycode, _, state)
    local mod = modOf(keycode)
    if mod and state ~= 2 then
        down[mod] = state == 1 or nil
        modifierChanged()
    end
    if SUPER[keycode] then
        if state == 1 and not held then
            held, used, elapsed, start = true, false, 0, hl.get_cursor_pos()
            tick:set_enabled(true)
        elseif state == 0 then
            held = false
            tick:set_enabled(false)
            if shown then
                shown = false
                overlay("close")
            end
        end
    elseif state == 1 and held and not mod then
        -- another modifier on top of Super is no "use" of it, the overlay may still open
        used = true
    end
end)
