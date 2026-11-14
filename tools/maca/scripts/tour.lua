-- Walk through the Maca screens and save a screenshot of each.
local H = MacaHarness
local UIManager = require("ui/uimanager")
local Home = require("maca/home")
local Library = require("maca/library")
local prefix = (os.getenv("MACA_DEVICE") or "phone") .. "-"

local function home()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget.nav and widget.switchTab then return widget end
    end
    error("Maca home screen is not showing")
end

H.steps{
    { 4, function() H.shot(prefix .. "1-home") end },
    { 0.3, function() home():switchTab("library") end },
    { 0.5, function() H.shot(prefix .. "2-library") end },
    { 0.2, function()
        Home.State.view = "list"
        home():rebuild()
    end },
    { 0.5, function() H.shot(prefix .. "3-library-list") end },
    { 0.2, function()
        Home.State.view = "grid"
        Home.State.group = "author"
        home():rebuild()
    end },
    { 0.5, function() H.shot(prefix .. "4-library-authors") end },
    { 0.2, function()
        Home.State.group = "none"
        home():switchTab("stats")
    end },
    { 0.5, function() H.shot(prefix .. "5-stats") end },
    { 0.2, function() home().scroll:scrollTo(home().scroll:maxOffset()) end },
    { 0.5, function() H.shot(prefix .. "6-stats-bottom") end },
    { 0.2, function() home():switchTab("more") end },
    { 0.5, function() H.shot(prefix .. "7-more") end },
    { 0.2, function() home():showBook(Library:current() or Library.books[1]) end },
    { 0.5, function() H.shot(prefix .. "8-book") end },
}
