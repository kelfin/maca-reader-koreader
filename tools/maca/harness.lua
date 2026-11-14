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

_G.MacaHarness = H
H.after(tonumber(os.getenv("MACA_DELAY")) or 2, function()
    dofile(script)
end)
