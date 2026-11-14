--[[--
Short transitions between two screen states.

KOReader has no animation system (it is built for e-ink), so this works on
the framebuffer directly: take the screen before a change, let the change
paint itself with screen updates held back, then show in-between frames made
of pieces of both pictures. The loop is blocking and time-based, so it runs
at whatever rate the display accepts frames.

@module koplugin.maca.animator
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local Animator = {
    busy = false,
    last_frames = 0, -- frames shown by the last transition (for tests and tuning)
    last_seconds = 0,
}

local REFRESH_NAMES = {
    "refreshFull", "refreshPartial", "refreshNoMergePartial", "refreshFlashPartial", "refreshUI",
    "refreshNoMergeUI", "refreshFlashUI", "refreshFast", "refreshA2", "refreshWaitForLast",
}

--- On unless switched off; e-ink screens need it switched on explicitly.
function Animator.enabled()
    local setting = G_reader_settings:readSetting("maca_animations")
    if setting == nil then
        return not Device:hasEinkScreen()
    end
    return setting
end

--- Display refresh rate in Hz.
function Animator.refreshRate()
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android.getRefreshRate then
            local ok_rate, rate = pcall(android.getRefreshRate)
            if ok_rate and rate and rate >= 30 then return rate end
        end
    end
    return 60
end

--- Seconds between frames for self-paced animations (scrolling).
function Animator.frameTime()
    if not Animator.frame_time then
        Animator.frame_time = 1 / math.min(144, Animator.refreshRate())
    end
    return Animator.frame_time
end

--- Ask Android for its fastest display mode, or hand the choice back.
function Animator.applyRefreshRate()
    Animator.frame_time = nil
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if ok and android.setHighRefreshRate then
        pcall(android.setHighRefreshRate, G_reader_settings:nilOrTrue("maca_high_refresh"))
    end
end

function Animator.canSetRefreshRate()
    if not Device:isAndroid() then return false end
    local ok, android = pcall(require, "android")
    return ok and android.setHighRefreshRate ~= nil
end

local function easeOut(t)
    local inv = 1 - t
    return 1 - inv * inv * inv
end

-- Run fn and paint its result into the framebuffer without showing it.
local function paintHidden(fn)
    local saved = {}
    local function noop() end
    for _, name in ipairs(REFRESH_NAMES) do
        saved[name] = rawget(Screen, name)
        Screen[name] = noop
    end
    local ok, err = xpcall(function()
        fn()
        UIManager:forceRePaint()
    end, debug.traceback)
    for _, name in ipairs(REFRESH_NAMES) do
        Screen[name] = saved[name]
    end
    if not ok then error(err, 0) end
end

local function fullRect()
    return { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

-- Frame painters. `p` is progress 0..1; all draw only inside rect `r`.
local painters = {}

-- Both pictures move together; the new one enters from the right ("left") or left ("right").
function painters.slide(bb, old, new, r, dir, p)
    local off = math.floor(r.w * p + 0.5)
    if dir == "left" then
        bb:blitFrom(old, r.x, r.y, r.x + off, r.y, r.w - off, r.h)
        bb:blitFrom(new, r.x + r.w - off, r.y, r.x, r.y, off, r.h)
    else
        bb:blitFrom(old, r.x + off, r.y, r.x, r.y, r.w - off, r.h)
        bb:blitFrom(new, r.x, r.y, r.x + r.w - off, r.y, off, r.h)
    end
end

-- The new picture slides in over a still old one, from the named edge's opposite:
-- "left" enters from the right, "up" from the bottom, "down" from the top.
function painters.cover(bb, old, new, r, dir, p)
    if dir == "left" then
        local off = math.floor(r.w * p + 0.5)
        bb:blitFrom(new, r.x + r.w - off, r.y, r.x, r.y, off, r.h)
    elseif dir == "up" then
        local off = math.floor(r.h * p + 0.5)
        bb:blitFrom(new, r.x, r.y + r.h - off, r.x, r.y, r.w, off)
    else -- down
        local off = math.floor(r.h * p + 0.5)
        bb:blitFrom(new, r.x, r.y, r.x, r.y + r.h - off, r.w, off)
    end
end

-- The old picture slides away, uncovering a still new one. "right" leaves to
-- the right, "down" to the bottom, "up" to the top.
function painters.uncover(bb, old, new, r, dir, p)
    if dir == "right" then
        local off = math.floor(r.w * p + 0.5)
        bb:blitFrom(new, r.x, r.y, r.x, r.y, off, r.h)
        bb:blitFrom(old, r.x + off, r.y, r.x, r.y, r.w - off, r.h)
    elseif dir == "down" then
        local off = math.floor(r.h * p + 0.5)
        bb:blitFrom(new, r.x, r.y, r.x, r.y, r.w, off)
        bb:blitFrom(old, r.x, r.y + off, r.x, r.y, r.w, r.h - off)
    else -- up
        local off = math.floor(r.h * p + 0.5)
        bb:blitFrom(new, r.x, r.y + r.h - off, r.x, r.y + r.h - off, r.w, off)
        bb:blitFrom(old, r.x, r.y, r.x, r.y + off, r.w, r.h - off)
    end
end

--[[--
Animate a change of the screen.

@tparam table spec
    kind      "slide", "cover" or "uncover"
    dir       direction, see the painters above
    rect      area that animates (default: whole screen); or
    parts     list of { kind =, dir =, rect = } animated together
    duration  seconds (default 0.22)
    changed   optional function() returning false when the change did nothing
              (the animation is then skipped)
@tparam function change makes the change (show/close a widget, turn a page…)
--]]--
function Animator.transition(spec, change)
    if Animator.busy or not Animator.enabled() then
        return change()
    end
    Animator.busy = true
    local bb = Screen.bb
    local old = bb:copy()
    local ok, err = pcall(paintHidden, change)
    if not ok then
        old:free()
        Animator.busy = false
        error(err, 0)
    end
    local parts = spec.parts or { { kind = spec.kind, dir = spec.dir, rect = spec.rect } }
    local frames = 0
    local started = time.now()
    if not spec.changed or spec.changed() ~= false then
        local new = bb:copy()
        local duration = spec.duration or 0.22
        local frame_time = 1 / math.min(144, Animator.refreshRate())
        -- everything outside the animated areas shows its new state at once
        for _, part in ipairs(parts) do
            part.rect = part.rect or fullRect()
            local r = part.rect
            bb:blitFrom(old, r.x, r.y, r.x, r.y, r.w, r.h)
        end
        while true do
            local frame_start = time.now()
            local t = time.to_s(frame_start - started) / duration
            if t >= 1 then break end
            local p = easeOut(t)
            for _, part in ipairs(parts) do
                painters[part.kind](bb, old, new, part.rect, part.dir, p)
            end
            Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
            frames = frames + 1
            if Animator.on_frame then Animator.on_frame(p) end -- test hook
            local spent = time.to_s(time.now() - frame_start)
            if spent < frame_time then
                ffiUtil.usleep(math.floor((frame_time - spent) * 1e6))
            end
        end
        bb:blitFrom(new, 0, 0, 0, 0, new:getWidth(), new:getHeight())
        new:free()
    end
    old:free()
    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    Animator.last_frames = frames
    Animator.last_seconds = time.to_s(time.now() - started)
    logger.dbg("Maca animation:", frames, "frames in", Animator.last_seconds, "s")
    Animator.busy = false
end

return Animator
