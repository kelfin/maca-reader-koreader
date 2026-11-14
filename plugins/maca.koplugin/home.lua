--[[--
The Maca home screen: Home, Library, Stats and More tabs.

@module koplugin.maca.home
--]]--

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Covers = require("covers")
local Device = require("device")
local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local Library = require("library")
local MacaScreen = require("screen")
local Rows = require("rows")
local Stats = require("stats")
local Theme = require("theme")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template
local dp = Theme.dp

-- Kept across instances: the screen is rebuilt each time a book is closed.
local State = {
    tab = "home",
    offsets = {},
    status = "all",
    sort = G_reader_settings:readSetting("maca_library_sort") or "recent",
    view = G_reader_settings:readSetting("maca_library_view") or "grid",
    group = G_reader_settings:readSetting("maca_library_group") or "none",
    search = nil,
    drill = nil, -- { key =, value = } when looking inside a group
}

local Home = MacaScreen:extend{
    ui = nil, -- the FileManager instance
    nav = {
        { key = "home", icon = "home", label = _("Home") },
        { key = "library", icon = "library", label = _("Library") },
        { key = "stats", icon = "stats", label = _("Stats") },
        { key = "more", icon = "more", label = _("More") },
    },
}

Home.State = State

function Home:init()
    self.nav_active = State.tab
    self.initial_offset = State.offsets[State.tab] or 0
    self.on_nav = function(key) self:switchTab(key) end
    MacaScreen.init(self)
    self.scroll.on_scroll = function(offset)
        State.offsets[State.tab] = offset
    end
    Library:addListener("home", function() self:scheduleRebuild() end)
    self:rebuild(true)
    UIManager:nextTick(function()
        Library:ensureScanned()
        Library:extractPending(Covers.specs())
    end)
end

function Home:onCloseWidget()
    Library:removeListener("home")
    if self.rebuild_task then
        UIManager:unschedule(self.rebuild_task)
    end
    MacaScreen.onCloseWidget(self)
end

function Home:onResize()
    -- simplest correct answer to a rotation: start over at the new size
    local ui = self.ui
    UIManager:close(self)
    UIManager:show(Home:new{ ui = ui })
end

-- Coalesce bursts of index changes (background extraction) into one rebuild.
function Home:scheduleRebuild()
    if self.rebuild_task then return end
    self.rebuild_task = function()
        self.rebuild_task = nil
        self:rebuild(true)
    end
    UIManager:scheduleIn(0.3, self.rebuild_task)
end

function Home:switchTab(key)
    if key == State.tab then
        if State.drill and key == "library" then
            State.drill = nil
            self:rebuild()
        else
            self.scroll:stopFling()
            self.scroll:scrollTo(0)
        end
        return
    end
    State.tab = key
    self.nav_active = key
    self:rebuild(true)
end

function Home:rebuild(keep_offset)
    local tab = State.tab
    local w = self:width()
    local rows
    if tab == "home" then
        self:setHeader(_("Maca"), { { icon = "search", on_tap = function() self:search() end } })
        rows = self:homeRows(w)
    elseif tab == "library" then
        rows = self:libraryRows(w)
    elseif tab == "stats" then
        self:setHeader(_("Reading stats"))
        rows = require("statsview").rows(self, w)
    else
        self:setHeader(_("More"))
        rows = self:moreRows(w)
    end
    rows[#rows + 1] = Rows.spacer(dp(24))
    self.scroll.offset = keep_offset and (State.offsets[tab] or 0) or 0
    self.scroll:setRows(rows, true)
    State.offsets[tab] = self.scroll.offset
    self:redraw()
end

-- Actions -----------------------------------------------------------------

function Home:openBook(entry)
    local file = entry.file
    UIManager:close(self)
    self.ui:openFile(file)
end

function Home:showBook(entry)
    local BookDetail = require("bookdetail")
    UIManager:show(BookDetail:new{
        ui = self.ui,
        entry = entry,
        on_open = function() self:openBook(entry) end,
        on_change = function() self:rebuild(true) end,
    })
end

function Home:search()
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input = State.search or "",
        input_hint = _("Title, author, series or tag"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = util.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    State.search = query ~= "" and query or nil
                    State.drill = nil
                    State.status = "all"
                    State.tab, self.nav_active = "library", "library"
                    self:rebuild()
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Home:pick(title, choices, current, on_pick)
    local dialog
    local buttons = {}
    for _, choice in ipairs(choices) do
        buttons[#buttons + 1] = { {
            text = choice[2] .. (choice[1] == current and "  ✓" or ""),
            callback = function()
                UIManager:close(dialog)
                on_pick(choice[1])
            end,
        } }
    end
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Home tab ----------------------------------------------------------------

local function statusText(entry)
    if entry.status == "complete" then
        return _("Finished")
    elseif entry.status == "new" then
        return entry.pages and T(N_("%1 page", "%1 pages", entry.pages), entry.pages) or _("Unread")
    end
    local percent = T(_("%1%"), math.floor((entry.percent or 0) * 100 + 0.5))
    if entry.status == "abandoned" then
        return T(_("%1 · On hold"), percent)
    end
    return percent
end
Home.statusText = statusText

function Home:goalSeconds()
    return (G_reader_settings:readSetting("maca_daily_goal_min") or 30) * 60
end

function Home:homeRows(w)
    local rows = {}
    local on_tap = function(entry) self:openBook(entry) end
    local on_hold = function(entry) self:showBook(entry) end

    if not Library.scanned then
        rows[#rows + 1] = Rows.message(w, _("Loading your library…"), "")
        return rows
    end
    if #Library.books == 0 then
        rows[#rows + 1] = Rows.message(w, _("No books yet"),
            T(_("Maca looked in %1 and found no books. Choose the folder where you keep them."),
                BD.dirpath(Library:getFolders()[1])),
            _("Choose library folder"), function() self:chooseFolder() end)
        return rows
    end

    local wide = w >= dp(700)
    local current = Library:current()
    local today_card = function(cw)
        return require("statsview").todayCard(self, cw, function() self:switchTab("stats") end)
    end
    local hero
    if current then
        local percent = T(_("%1% read"), math.floor((current.percent or 0) * 100 + 0.5))
        local left = Stats:timeLeft(current.file, current.percent, current.pages)
        local detail = left and left > 60 and T(_("%1 · %2 left"), percent, Theme.duration(left)) or percent
        hero = function(cw)
            return Rows.hero(cw, current, {
                label = _("CONTINUE READING"), detail = detail, on_tap = on_tap, on_hold = on_hold,
            })
        end
    end
    rows[#rows + 1] = Rows.spacer(dp(4))
    if hero and wide then
        rows[#rows + 1] = Rows.split(w, hero, today_card)
    else
        if hero then rows[#rows + 1] = hero(w) end
        rows[#rows + 1] = today_card(w)
    end

    local function shelf(title, list, action)
        if #list == 0 then return end
        rows[#rows + 1] = Rows.section(title, _("See all"), action)
        rows[#rows + 1] = Rows.shelf(w, list, { on_tap = on_tap, on_hold = on_hold })
    end
    local function seeAll(status, sort)
        return function()
            State.status, State.sort, State.search, State.drill = status, sort, nil, nil
            State.tab, self.nav_active = "library", "library"
            self:rebuild()
        end
    end

    local reading = {}
    for _, entry in ipairs(Library:query{ status = "reading", sort = "recent" }) do
        if entry ~= current then reading[#reading + 1] = entry end
    end
    shelf(_("Keep reading"), reading, seeAll("reading", "recent"))
    shelf(_("Recently added"), Library:query{ status = "new", sort = "added" }, seeAll("new", "added"))
    shelf(_("Finished"), Library:query{ status = "complete", sort = "recent" }, seeAll("complete", "recent"))
    if Library.extracting then
        rows[#rows + 1] = Rows.paragraph(w, T(N_("Reading details of %1 book…", "Reading details of %1 books…",
            #Library.pending), #Library.pending), 13, { color = Theme.MUTED })
    end
    return rows
end

-- Library tab -------------------------------------------------------------

local function labelOf(list, key)
    for _, item in ipairs(list) do
        if item[1] == key then return item[2] end
    end
end

function Home:libraryRows(w)
    local rows = {}
    local on_tap = function(entry) self:openBook(entry) end
    local on_hold = function(entry) self:showBook(entry) end
    local rebuild = function() self:rebuild() end

    -- header
    if State.drill then
        self:setHeader(State.drill.value, nil, function()
            State.drill = nil
            self:rebuild()
        end)
    elseif State.search then
        self:setHeader(T(_("“%1”"), State.search), { { icon = "close", on_tap = function()
            State.search = nil
            self:rebuild()
        end } })
    else
        self:setHeader(_("Library"), { { icon = "search", on_tap = function() self:search() end } })
    end

    if #Library.books == 0 then
        rows[#rows + 1] = Rows.message(w, _("No books yet"),
            _("Choose the folder where you keep your books."),
            _("Choose library folder"), function() self:chooseFolder() end)
        return rows
    end

    -- status filter
    local counts = Library:counts()
    local chips = {}
    for _, item in ipairs(Library.status_names) do
        if item[1] == "all" or (counts[item[1]] or 0) > 0 then
            chips[#chips + 1] = { item[1], T("%1  %2", item[2], counts[item[1]] or 0) }
        end
    end
    if not State.drill then
        rows[#rows + 1] = Rows.spacer(dp(4))
        rows[#rows + 1] = Rows.chips(w, chips, State.status, function(key)
            State.status = key
            self:rebuild()
        end)
    end

    local grouped = State.group ~= "none" and not State.drill and not State.search
    local query = {
        status = not State.drill and State.status or nil,
        search = State.search,
        sort = State.sort,
        group_key = State.drill and State.drill.key,
        group_value = State.drill and State.drill.value,
    }

    local buttons = {}
    if not grouped and not (State.drill and State.drill.key == "series") then
        buttons[#buttons + 1] = { icon = "sort", label = labelOf(Library.sort_names, State.sort), on_tap = function()
            self:pick(_("Sort by"), Library.sort_names, State.sort, function(key)
                State.sort = key
                G_reader_settings:saveSetting("maca_library_sort", key)
                rebuild()
            end)
        end }
    end
    if not State.drill and not State.search then
        buttons[#buttons + 1] = { icon = "filter", on_tap = function()
            self:pick(_("Group by"), Library.group_names, State.group, function(key)
                State.group = key
                G_reader_settings:saveSetting("maca_library_group", key)
                rebuild()
            end)
        end }
    end
    if not grouped then
        buttons[#buttons + 1] = { icon = State.view == "grid" and "list" or "grid", on_tap = function()
            State.view = State.view == "grid" and "list" or "grid"
            G_reader_settings:saveSetting("maca_library_view", State.view)
            rebuild()
        end }
    end

    if grouped then
        local groups = Library:groups(State.group, query)
        rows[#rows + 1] = Rows.toolbar(w, T(N_("%1 group", "%1 groups", #groups), #groups), buttons)
        for _, group in ipairs(groups) do
            rows[#rows + 1] = Rows.item(w, State.group == "folder" and "folder" or "library", group.name,
                tostring(#group.books), function()
                    State.drill = { key = State.group, value = group.name }
                    self:rebuild()
                end)
        end
        if #groups == 0 then
            rows[#rows + 1] = Rows.message(w, _("Nothing to group"),
                _("None of the books in this view has that detail."))
        end
        return rows
    end

    local books = Library:query(query)
    rows[#rows + 1] = Rows.toolbar(w, T(N_("%1 book", "%1 books", #books), #books), buttons)
    if #books == 0 then
        rows[#rows + 1] = Rows.message(w, _("No matching books"),
            State.search and _("Try a shorter search, or look in All.") or _("No books have this status yet."))
    elseif State.view == "grid" then
        local gap = dp(14)
        local n, tile_w = Rows.columns(w, dp(104), gap)
        for i = 1, #books, n do
            local slice = {}
            for j = i, math.min(i + n - 1, #books) do
                slice[#slice + 1] = books[j]
            end
            rows[#rows + 1] = Rows.grid(w, slice, n, tile_w, gap, { on_tap = on_tap, on_hold = on_hold })
        end
    else
        for _, entry in ipairs(books) do
            rows[#rows + 1] = Rows.book(w, entry, { on_tap = on_tap, on_hold = on_hold, status_text = statusText })
        end
    end
    return rows
end

-- More tab ----------------------------------------------------------------

function Home:chooseFolder()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = Library:getFolders()[1],
        onConfirm = function(path)
            Library:setFolders({ path })
            Library:extractPending(Covers.specs())
        end,
    })
end

function Home:setGoal()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Daily reading goal"),
        info_text = _("Minutes of reading that count as a day done."),
        value = G_reader_settings:readSetting("maca_daily_goal_min") or 30,
        value_min = 5,
        value_max = 600,
        value_step = 5,
        value_hold_step = 30,
        unit = _("min"),
        ok_text = _("Set goal"),
        callback = function(spin)
            G_reader_settings:saveSetting("maca_daily_goal_min", spin.value)
            self:rebuild(true)
        end,
    })
end

function Home:browseFiles()
    State.browsing = true
    UIManager:close(self)
end

function Home:moreRows(w)
    local rows = {}
    local folders = Library:getFolders()
    rows[#rows + 1] = Rows.section(_("Library"))
    rows[#rows + 1] = Rows.item(w, "folder", _("Library folder"), nil, function() self:chooseFolder() end,
        { sub = BD.dirpath(folders[1]) })
    rows[#rows + 1] = Rows.item(w, "sync", _("Rescan library"),
        T(N_("%1 book", "%1 books", #Library.books), #Library.books), function()
            Library:scan()
            Library:extractPending(Covers.specs())
        end, { no_chevron = true })
    rows[#rows + 1] = Rows.item(w, "book", _("Browse files"), nil, function() self:browseFiles() end)

    rows[#rows + 1] = Rows.section(_("Reading"))
    rows[#rows + 1] = Rows.item(w, "target", _("Daily reading goal"),
        T(_("%1 min"), G_reader_settings:readSetting("maca_daily_goal_min") or 30), function() self:setGoal() end)
    rows[#rows + 1] = Rows.item(w, "theme", _("Dark mode"),
        Device.screen.night_mode and _("On") or _("Off"), function()
            UIManager:broadcastEvent(Event:new("ToggleNightMode"))
            Covers:clear()
            self:rebuild(true)
        end, { no_chevron = true })

    rows[#rows + 1] = Rows.section(_("App"))
    rows[#rows + 1] = Rows.item(w, "home", _("Open Maca when the app starts"),
        G_reader_settings:nilOrTrue("maca_home_on_start") and _("On") or _("Off"), function()
            G_reader_settings:flipNilOrTrue("maca_home_on_start")
            self:rebuild(true)
        end, { no_chevron = true })
    rows[#rows + 1] = Rows.item(w, "settings", _("All settings"), nil, function()
        self.ui.menu:onShowMenu()
    end, { sub = _("The full KOReader menu") })
    return rows
end

return Home
