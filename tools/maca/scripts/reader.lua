-- Open a book, show the reading bars and the display sheet, try the themes.
local H = MacaHarness
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Screen = require("device").screen
local prefix = (os.getenv("MACA_DEVICE") or "phone") .. "-r"
local W, H_ = Screen:getWidth(), Screen:getHeight()

local function gesture(kind, x, y, extra)
    local ges = { ges = kind, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }
    for k, v in pairs(extra or {}) do ges[k] = v end
    UIManager:sendEvent(Event:new("Gesture", ges))
end
local function top()
    return UIManager._window_stack[#UIManager._window_stack].widget
end
local function ui()
    return require("apps/reader/readerui").instance
end
local Reader = require("maca/reader")

H.steps{
    { 4, function()
        local Library = require("maca/library")
        local book = Library:query{ sort = "title" }[2]
        for i = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if widget.openBook then widget:openBook(book) break end
        end
    end },
    { 5, function()
        assert(ui(), "reader did not open")
        ui():handleEvent(Event:new("GotoPage", 12))
    end },
    { 1, function()
        H.shot(prefix .. "1-page")
        gesture("tap", W / 2, H_ / 2)
    end },
    { 0.6, function()
        assert(top().showDisplay, "tapping the middle did not show the bars")
        H.shot(prefix .. "2-bars")
        -- drag the progress slider to about 60%
        local s = top().slider
        gesture("touch", s.x + 10, s.y)
        gesture("pan", s.x + s.w * 0.6, s.y, { relative = { x = s.w * 0.6, y = 0 } })
        gesture("pan_release", s.x + s.w * 0.6, s.y, { relative = { x = s.w * 0.6, y = 0 } })
    end },
    { 1, function()
        local page = ui():getCurrentPage()
        local count = ui().document:getPageCount()
        assert(page > count * 0.5 and page < count * 0.7, "slider did not seek: page " .. page .. " of " .. count)
        top():showDisplay()
    end },
    { 0.6, function()
        assert(top().setBrightness, "display sheet did not open")
        H.shot(prefix .. "3-sheet")
        Reader.applyTheme(ui(), "sepia")
        ui():handleEvent(Event:new("SetFontSize", 26))
        top():refresh()
    end },
    { 1.5, function()
        H.shot(prefix .. "4-sepia")
        UIManager:close(top())
        Reader.applyTheme(ui(), "dim")
    end },
    { 1, function()
        H.shot(prefix .. "5-dim")
        Reader.applyTheme(ui(), "dark")
    end },
    { 1, function()
        H.shot(prefix .. "6-dark")
        Reader.applyTheme(ui(), "light")
        ui():handleEvent(Event:new("SetFontSize", 22))
    end },
    { 1, function() end },
}
