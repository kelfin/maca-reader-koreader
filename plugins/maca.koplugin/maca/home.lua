--[[--
The Maca home screen: Home, Library, Stats and More tabs.

@module koplugin.maca.home
--]]--

local Animator = require("maca/animator")
local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Covers = require("maca/covers")
local Device = require("device")
local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local Library = require("maca/library")
local MacaScreen = require("maca/screen")
local Rows = require("maca/rows")
local Stats = require("maca/stats")
local Theme = require("maca/theme")
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
    local function index(tab)
        for i, item in ipairs(self.nav) do
            if item.key == tab then return i end
        end
    end
    local forward = index(key) > index(State.tab)
    Animator.transition({
        kind = "slide", dir = forward and "left" or "right", duration = 0.2,
        rect = self:bodyRect(),
    }, function()
        State.tab = key
        self.nav_active = key
        self:rebuild(true)
    end)
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
        rows = require("maca/statsview").rows(self, w)
    else
        self:setHeader(_("More"))
        rows = self:moreRows(w)
    end
    self.scroll.offset = keep_offset and (State.offsets[tab] or 0) or 0
    self.scroll.background = tab == "home" and self:ambientWash() or nil
    self:setRows(rows, true)
    State.offsets[tab] = self.scroll.offset
    self:redraw()
end

-- A soft wash of the current book's colour behind the top of the home tab.
function Home:ambientWash()
    local current = Library.scanned and Library:current()
    local tint = current and Covers:tint(current)
    if not tint then return nil end
    local height = dp(300)
    local bands = 30
    local band_h = math.ceil(height / bands)
    return function(bb, x, y, w, h, offset)
        if offset >= height then return end
        for i = 0, bands - 1 do
            local strength = 0.30 * (1 - i / bands) ^ 1.6
            Theme.fillRect(bb, x, y + i * band_h - offset, w, band_h,
                Theme.mix(tint[1], tint[2], tint[3], strength))
        end
    end
end

-- Actions -----------------------------------------------------------------

function Home:openBook(entry)
    local file = entry.file
    UIManager:close(self)
    self.ui:openFile(file)
end

function Home:showBook(entry)
    local BookDetail = require("maca/bookdetail")
    Animator.transition({ kind = "cover", dir = "left", duration = 0.24 }, function()
        UIManager:show(BookDetail:new{
            ui = self.ui,
            entry = entry,
            on_open = function() self:openBook(entry) end,
            on_open_other = function(other) self:openBook(other) end,
            on_change = function() self:rebuild(true) end,
        })
    end)
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
        return require("maca/statsview").todayCard(self, cw, function() self:switchTab("stats") end)
    end
    local hero
    if current then
        local percent = T(_("%1% read"), math.floor((current.percent or 0) * 100 + 0.5))
        local left = Stats:timeLeft(current.file, current.percent, current.pages)
        local detail = left and left > 60 and T(_("%1 · %2 left"), percent, Theme.duration(left)) or percent
        hero = function(cw)
            return Rows.hero(cw, current, {
                label = _("CONTINUE READING"), detail = detail, on_tap = on_tap, on_hold = on_hold,
                glass = true,
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
            Animator.transition({ kind = "uncover", dir = "right", duration = 0.22 }, function()
                State.drill = nil
                self:rebuild()
            end)
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
                    Animator.transition({ kind = "cover", dir = "left", duration = 0.22 }, function()
                        State.drill = { key = State.group, value = group.name }
                        self:rebuild()
                    end)
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

function Home:addFolder(replace)
    local PathChooser = require("ui/widget/pathchooser")
    local folders = Library:getFolders()
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = folders[1],
        onConfirm = function(path)
            local dirs = {}
            if not replace then
                for _, dir in ipairs(folders) do
                    if dir ~= path then dirs[#dirs + 1] = dir end
                end
            end
            dirs[#dirs + 1] = path
            Library:setFolders(dirs)
            Library:extractPending(Covers.specs())
        end,
    })
end

-- First choice of a library folder replaces the guessed defaults.
function Home:chooseFolder()
    self:addFolder(not Library:foldersChosen())
end

function Home:manageFolders()
    local folders = Library:getFolders()
    local dialog
    local buttons = {}
    for _, dir in ipairs(folders) do
        buttons[#buttons + 1] = { {
            text = T(_("Remove %1"), BD.dirpath(dir)),
            align = "left",
            enabled = #folders > 1,
            callback = function()
                UIManager:close(dialog)
                local dirs = {}
                for _, other in ipairs(folders) do
                    if other ~= dir then dirs[#dirs + 1] = other end
                end
                Library:setFolders(dirs)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Add a folder…"),
        callback = function()
            UIManager:close(dialog)
            self:addFolder(false)
        end,
    } }
    dialog = ButtonDialog:new{
        title = _("Maca shows the books in these folders and the folders inside them."),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Home:chooseSyncFolder()
    local SyncFolder = require("maca/syncfolder")
    local choices = { { "pick", _("Choose folder…") } }
    if SyncFolder.dir() then choices[#choices + 1] = { "off", _("Turn off") } end
    self:pick(_("Highlights, notes and reading status are shared through this folder. Keep it in sync between your devices with an app such as Syncthing."),
        choices, nil, function(choice)
            if choice == "off" then
                G_reader_settings:delSetting("maca_sync_dir")
                self:rebuild(true)
                return
            end
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                select_directory = true,
                select_file = false,
                path = SyncFolder.dir() or Library:getFolders()[1],
                onConfirm = function(path)
                    G_reader_settings:saveSetting("maca_sync_dir", path)
                    self:rebuild(true)
                end,
            })
        end)
end

function Home:backup()
    local Backup = require("maca/backup")
    local InfoMessage = require("ui/widget/infomessage")
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = Library:getFolders()[1],
        onConfirm = function(path)
            local target, copied = Backup.create(path)
            UIManager:show(InfoMessage:new{
                text = target and T(_("Backup saved to %1 (%2 files)."), BD.dirpath(target), copied)
                    or _("Could not create a backup in that folder."),
            })
        end,
    })
end

function Home:restore()
    local Backup = require("maca/backup")
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = Library:getFolders()[1],
        onConfirm = function(path)
            if not Backup.isBackup(path) then
                UIManager:show(InfoMessage:new{ text = _("That folder is not a Maca backup.") })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = _("Replace the current settings, history and reading statistics with this backup? The app will close; open it again afterwards."),
                ok_text = _("Restore"),
                ok_callback = function()
                    Backup.restore(path)
                    -- leave without saving, or the old settings would overwrite the restored ones
                    G_reader_settings.flush = function() end
                    UIManager:quit()
                end,
            })
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
    local folder_names = {}
    for i, dir in ipairs(folders) do folder_names[i] = BD.dirpath(dir) end
    rows[#rows + 1] = Rows.item(w, "folder", N_("Library folder", "Library folders", #folders), nil,
        function() self:manageFolders() end, { sub = table.concat(folder_names, ", ") })
    rows[#rows + 1] = Rows.item(w, "sync", _("Rescan library"),
        T(N_("%1 book", "%1 books", #Library.books), #Library.books), function()
            Library:scan()
            Library:extractPending(Covers.specs())
        end, { no_chevron = true })
    rows[#rows + 1] = Rows.item(w, "note", _("Highlights and notes"), nil, function()
        require("maca/notebook").showAll(self.ui)
    end)
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

    local kosync = self.ui.kosync
    if kosync and kosync.settings then
        local settings = kosync.settings
        local function save()
            G_reader_settings:saveSetting("kosync", settings)
            self:rebuild(true)
        end
        -- the plugin refreshes "its menu" after logging in or out; use that to refresh ours
        local on_account_change = { updateItems = function()
            if settings.userkey then settings.auto_sync = true end
            save()
        end }
        rows[#rows + 1] = Rows.section(_("Sync between devices"))
        if settings.userkey then
            rows[#rows + 1] = Rows.item(w, "sync", _("Reading position"), settings.username, function()
                self:pick(T(_("Signed in as %1"), settings.username), { { "logout", _("Sign out") } }, nil,
                    function() kosync:logout(on_account_change) end)
            end, { sub = _("Pick up on one device where you stopped on another") })
            rows[#rows + 1] = Rows.item(w, "check", _("Sync automatically"),
                settings.auto_sync and _("On") or _("Off"), function()
                    settings.auto_sync = not settings.auto_sync
                    save()
                end, { no_chevron = true })
        else
            rows[#rows + 1] = Rows.item(w, "sync", _("Reading position"), _("Off"), function()
                kosync:login(on_account_change)
            end, { sub = _("Sign in or register to continue a book on another device") })
        end
        rows[#rows + 1] = Rows.item(w, "settings", _("Sync server"),
            settings.custom_server or _("Default"), function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Sync server address"),
                    description = _("Leave empty to use the public KOReader sync server."),
                    input = settings.custom_server or "https://",
                    buttons = { {
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Save"), is_enter_default = true, callback = function()
                            local address = util.trim(dialog:getInputText())
                            UIManager:close(dialog)
                            if address == "https://" then address = "" end
                            kosync:setCustomServer(address)
                            save()
                        end },
                    } },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end)
    end

    -- highlights, notes and status through a folder the user keeps in sync
    local SyncFolder = require("maca/syncfolder")
    local sync_dir = SyncFolder.dir()
    if not (kosync and kosync.settings) then
        rows[#rows + 1] = Rows.section(_("Sync between devices"))
    end
    rows[#rows + 1] = Rows.item(w, "folder", _("Highlights and status"),
        sync_dir and _("On") or _("Off"), function() self:chooseSyncFolder() end,
        { sub = sync_dir and BD.dirpath(sync_dir)
            or _("Pick a folder that you keep in sync between your devices") })
    if sync_dir then
        rows[#rows + 1] = Rows.item(w, "sync", _("Sync highlights now"), nil, function()
            local touched, gained = SyncFolder.syncAll(Library.books)
            Library:scan()
            UIManager:show(require("ui/widget/infomessage"):new{
                text = gained > 0
                    and T(N_("Added %1 highlight from other devices.", "Added %1 highlights from other devices.", gained), gained)
                    or _("Everything is up to date."),
                timeout = 3,
            })
        end, { no_chevron = true })
    end

    rows[#rows + 1] = Rows.section(_("Backup"))
    rows[#rows + 1] = Rows.item(w, "bookmark", _("Back up settings and statistics"), nil,
        function() self:backup() end, { no_chevron = true })
    rows[#rows + 1] = Rows.item(w, "sync", _("Restore a backup"), nil, function() self:restore() end)

    rows[#rows + 1] = Rows.section(_("App"))
    rows[#rows + 1] = Rows.item(w, "home", _("Open Maca when the app starts"),
        G_reader_settings:nilOrTrue("maca_home_on_start") and _("On") or _("Off"), function()
            G_reader_settings:flipNilOrTrue("maca_home_on_start")
            self:rebuild(true)
        end, { no_chevron = true })
    rows[#rows + 1] = Rows.item(w, "forward", _("Animations"),
        Animator.enabled() and _("On") or _("Off"), function()
            G_reader_settings:saveSetting("maca_animations", not Animator.enabled())
            self:rebuild(true)
        end, { no_chevron = true, sub = _("Sliding pages, screens and panels") })
    if Animator.canSetRefreshRate() then
        rows[#rows + 1] = Rows.item(w, "flame", _("High refresh rate"),
            G_reader_settings:nilOrTrue("maca_high_refresh") and T(_("On · %1 Hz"), Animator.refreshRate()) or _("Off"),
            function()
                G_reader_settings:flipNilOrTrue("maca_high_refresh")
                Animator.applyRefreshRate()
                -- the display needs a moment to switch before we can read the new rate
                UIManager:scheduleIn(0.6, function() self:rebuild(true) end)
            end, { no_chevron = true, sub = _("Smoother motion; uses a little more battery") })
    end
    rows[#rows + 1] = Rows.item(w, "theme", _("Glass effects"),
        G_reader_settings:nilOrTrue("maca_glass") and _("On") or _("Off"), function()
            G_reader_settings:flipNilOrTrue("maca_glass")
            self:rebuild(true)
        end, { no_chevron = true, sub = _("Frosted bars and panels; turn off if scrolling stutters") })
    rows[#rows + 1] = Rows.item(w, "settings", _("All settings"), nil, function()
        self.ui.menu:onShowMenu()
    end, { sub = _("The full KOReader menu") })
    return rows
end

return Home
