-- Dev harness, installed as a "late" user patch by tools/maca/dev.sh.
-- Runs the Lua file named by $MACA_SCRIPT inside the running emulator, with a
-- few helpers for scripted screenshots.
local books = os.getenv("MACA_BOOKS")
if books then
    -- the dev profile's library is the sample books folder
    G_reader_settings:saveSetting("home_dir", books)
end
local script = os.getenv("MACA_SCRIPT")
if not script then return end

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local out_dir = os.getenv("MACA_SHOTS") or "."
local H = {}

-- Run fn after `delay` seconds; errors are logged and end the run.
function H.after(delay, fn)
    UIManager:scheduleIn(delay, function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            logger.err("MACA harness error:", err)
            io.stderr:write("MACA_HARNESS_ERROR: ", tostring(err), "\n")
            UIManager:quit(1)
        end
    end)
end

function H.shot(name)
    UIManager:forceRePaint()
    local path = out_dir .. "/" .. name .. ".png"
    Device.screen:shot(path)
    io.stderr:write("MACA_SHOT: ", path, "\n")
end

function H.quit()
    UIManager:quit(0)
end

-- Run a list of {delay, fn} steps one after another, then quit.
function H.steps(list)
    local i = 0
    local function nextStep()
        i = i + 1
        local step = list[i]
        if not step then return H.quit() end
        H.after(step[1], function()
            step[2]()
            nextStep()
        end)
    end
    nextStep()
end

-- Helpers shared by the scripts ---------------------------------------------

local Event = require("ui/event")
local Geom = require("ui/geometry")
local time = require("ui/time")

function H.gesture(kind, x, y, extra)
    local ges = { ges = kind, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }
    for k, v in pairs(extra or {}) do ges[k] = v end
    UIManager:sendEvent(Event:new("Gesture", ges))
end

function H.tap(x, y) H.gesture("tap", x, y) end

--- Topmost widget on screen.
function H.top()
    return UIManager._window_stack[#UIManager._window_stack].widget
end

--- The Maca home screen, if it is shown.
function H.home()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget.nav and widget.switchTab then return widget end
    end
end

function H.ui()
    return require("apps/reader/readerui").instance
end

--- First row of a Maca screen whose `name` (item and section rows) matches `pattern`.
function H.findRow(screen, pattern)
    for _, row in ipairs(screen.scroll.rows) do
        if type(row.name) == "string" and row.name:find(pattern) then return row end
    end
end

--- Scroll a screen so `row` sits just below the header, then tap it at
-- (lx, ly) in row coordinates (default: the middle of the row).
function H.tapRow(screen, row, lx, ly)
    assert(row, "no such row")
    screen.scroll:scrollTo(row.y - screen.header_h - Device.screen:scaleBySize(8))
    UIManager:forceRePaint()
    local x = screen.dimen.x + (lx or math.floor(screen.dimen.w / 2))
    local y = screen.dimen.y + row.y - screen.scroll.offset + (ly or math.floor(row.h / 2))
    assert(y > screen.header_h and y < screen.dimen.h - screen.scroll.touch_bottom, "row is not on screen")
    H.tap(x, y)
end

--- Close the topmost widget, and assert it is not `keep`.
function H.closeTop(keep)
    local top = H.top()
    assert(top ~= keep, "expected a dialog on top")
    UIManager:close(top)
    UIManager:forceRePaint()
    return top
end

_G.MacaHarness = H
H.after(tonumber(os.getenv("MACA_DELAY")) or 2, function()
    dofile(script)
end)
