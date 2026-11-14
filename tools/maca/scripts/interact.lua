-- Exercise gestures: scroll the library, open a book, come back, dark mode.
local H = MacaHarness
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Home = require("maca/home")
local prefix = (os.getenv("MACA_DEVICE") or "phone") .. "-"

local function home()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget.nav and widget.switchTab then return widget end
    end
end

local function gesture(kind, x, y, extra)
    local ges = { ges = kind, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }
    for k, v in pairs(extra or {}) do ges[k] = v end
    UIManager:sendEvent(Event:new("Gesture", ges))
end

local W, H_ = require("device").screen:getWidth(), require("device").screen:getHeight()

H.steps{
    { 4, function() home():switchTab("library") end },
    { 0.3, function()
        -- drag the list up by 260 px in a few steps
        gesture("touch", W / 2, H_ * 0.7)
        for i = 1, 5 do
            gesture("pan", W / 2, H_ * 0.7 - i * 52, { relative = { x = 0, y = -i * 52 }, direction = "north", distance = i * 52 })
        end
        gesture("pan_release", W / 2, H_ * 0.7 - 260, { relative = { x = 0, y = -260 } })
    end },
    { 0.5, function()
        assert(home().scroll.offset > 0, "library did not scroll")
        H.shot(prefix .. "a-library-scrolled")
    end },
    { 0.2, function()
        -- tap the first cover that is fully on screen
        gesture("tap", W * 0.2, H_ * 0.5)
    end },
    { 5, function()
        local ReaderUI = require("apps/reader/readerui")
        assert(ReaderUI.instance, "tapping a cover did not open the reader")
        H.shot(prefix .. "b-reader")
        ReaderUI.instance:onHome()
    end },
    { 3, function()
        assert(home(), "home screen did not come back after closing the book")
        assert(Home.State.tab == "library")
        H.shot(prefix .. "c-back-in-library")
        home():switchTab("home")
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
        require("maca/covers"):clear()
        home():rebuild(true)
    end },
    { 0.6, function()
        H.shot(prefix .. "d-home-dark")
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    end },
}
