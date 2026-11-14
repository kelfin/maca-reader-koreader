-- Check that transitions run and save one in-between frame of each.
local H = MacaHarness
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Animator = require("maca/animator")
local Library = require("maca/library")
local Screen = require("device").screen
local prefix = (os.getenv("MACA_DEVICE") or "phone") .. "-m"
local W, H_ = Screen:getWidth(), Screen:getHeight()

local function top() return UIManager._window_stack[#UIManager._window_stack].widget end
local function ui() return require("apps/reader/readerui").instance end
local function home()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget.nav and widget.switchTab then return widget end
    end
end
local function gesture(kind, x, y)
    UIManager:sendEvent(Event:new("Gesture", { ges = kind, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }))
end

-- Save the first frame past the half-way point of the next transition.
local function watch(name)
    local done = false
    Animator.last_frames = 0
    Animator.on_frame = function(p)
        if not done and p > 0.5 then
            done = true
            Screen:shot((os.getenv("MACA_SHOTS") or ".") .. "/" .. prefix .. name .. ".png")
        end
    end
end
local function ran(what)
    Animator.on_frame = nil
    assert(Animator.last_frames >= 3, what .. ": only " .. Animator.last_frames .. " frames")
    io.stderr:write(string.format("MACA anim %-14s %3d frames in %.3f s\n", what, Animator.last_frames, Animator.last_seconds))
end

-- the emulator poses as an e-ink device, where animations are off by default
G_reader_settings:saveSetting("maca_animations", true)

H.steps{
    { 4, function() watch("1-tab") home():switchTab("library") ran("tab switch") end },
    { 0.3, function() watch("2-push") home():showBook(Library:current()) ran("open book page") end },
    { 0.3, function() watch("3-pop") top().on_back() ran("close book page") end },
    { 0.3, function() home():openBook(Library:query{ sort = "title" }[2]) end },
    { 5, function() ui():handleEvent(Event:new("GotoPage", 20)) end },
    { 1, function()
        local before = ui():getCurrentPage()
        watch("4-page")
        ui().rolling:onGotoViewRel(1)
        ran("page turn")
        assert(ui():getCurrentPage() == before + 1, "page did not advance")
        watch("5-page-back")
        ui().rolling:onGotoViewRel(-1)
        ran("page turn back")
        assert(ui():getCurrentPage() == before, "page did not go back")
    end },
    { 0.3, function() watch("6-bars") gesture("tap", W / 2, H_ / 2) ran("reader bars") end },
    { 0.3, function()
        assert(top().showDisplay, "bars are not showing")
        watch("7-sheet")
        top():showDisplay()
        ran("display sheet")
    end },
    { 0.3, function()
        assert(top().dismiss, "sheet is not showing")
        watch("8-sheet-close")
        top():dismiss()
        ran("sheet close")
        assert(not top().dismiss, "sheet did not close")
    end },
    { 0.3, function()
        -- with animations off everything still works, without frames
        G_reader_settings:saveSetting("maca_animations", false)
        Animator.last_frames = 0
        local before = ui():getCurrentPage()
        ui().rolling:onGotoViewRel(1)
        assert(ui():getCurrentPage() == before + 1 and Animator.last_frames == 0, "animations did not turn off")
        G_reader_settings:saveSetting("maca_animations", true)
    end },
}
