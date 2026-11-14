--[[--
Library index: every book found under the library folders, with metadata
(from CoverBrowser's BookInfoManager cache), reading status (from the book's
sidecar settings) and last-read time (from the reading history).

@module koplugin.maca.library
--]]--

local BookInfoManager = require("bookinfomanager")
local BookList = require("ui/widget/booklist")
local DocumentRegistry = require("document/documentregistry")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Library = {
    books = {},       -- array of book entries
    by_file = {},     -- file path -> entry
    pending = {},     -- files whose metadata/cover has not been extracted yet
    scanned = false,
    listeners = {},   -- callbacks invoked when the index changes
}

local MAX_DEPTH = 8

-- KOReader can open far more than books (pictures, text, HTML, archives).
-- Only these count as library books.
local BOOK_EXTENSIONS = {
    epub = true, kepub = true, pdf = true, djvu = true, djv = true, mobi = true, azw = true, azw3 = true,
    prc = true, fb2 = true, fb3 = true, fbz = true, cbz = true, cbt = true, cb7 = true, cbr = true,
    chm = true, docx = true, rtf = true, pdb = true, xps = true,
}

local function isBook(path)
    local lower = path:lower()
    if lower:match("%.fb2%.zip$") or lower:match("%.kepub%.epub$") then return true end
    local ext = lower:match("%.([%w]+)$")
    return ext ~= nil and BOOK_EXTENSIONS[ext] == true and DocumentRegistry:hasProvider(path)
end

Library.isBook = function(path)
    local lower = path:lower()
    if lower:match("%.fb2%.zip$") or lower:match("%.kepub%.epub$") then return true end
    local ext = lower:match("%.([%w]+)$")
    return ext ~= nil and BOOK_EXTENSIONS[ext] == true
end

function Library:getFolders()
    local dirs = G_reader_settings:readSetting("maca_library_dirs")
    if type(dirs) == "table" and #dirs > 0 then
        return dirs
    end
    local Device = require("device")
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
    if Device:isAndroid() and not G_reader_settings:has("home_dir") then
        -- Shared storage holds far more than books; start with the usual places.
        local usual = {}
        for _, name in ipairs{ "Books", "eBooks", "Download", "Documents" } do
            local path = home .. "/" .. name
            if lfs.attributes(path, "mode") == "directory" then usual[#usual + 1] = path end
        end
        if #usual > 0 then return usual end
    end
    return { home }
end

--- True once the user has picked library folders themselves.
function Library:foldersChosen()
    local dirs = G_reader_settings:readSetting("maca_library_dirs")
    return type(dirs) == "table" and #dirs > 0
end

function Library:setFolders(dirs)
    G_reader_settings:saveSetting("maca_library_dirs", dirs)
    self:scan()
end

function Library:addListener(key, fn)
    self.listeners[key] = fn
end

function Library:removeListener(key)
    self.listeners[key] = nil
end

function Library:notify()
    for _, fn in pairs(self.listeners) do
        fn()
    end
end

local function walk(dir, depth, out, seen)
    local real = ffiUtil.realpath(dir)
    if not real or seen[real] then return end
    seen[real] = true
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, dir_obj do
        if name:sub(1, 1) ~= "." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "directory" then
                    if depth < MAX_DEPTH and not name:match("%.sdr$") then
                        walk(path, depth + 1, out, seen)
                    end
                elseif attr.mode == "file" and isBook(path) then
                    out[#out + 1] = { file = path, size = attr.size, added = attr.modification }
                end
            end
        end
    end
end

local function firstAuthor(authors)
    if not authors or authors == "" then return nil end
    return (authors:match("^[^\n]+")) or authors
end

--- Fill in the metadata fields of an entry from the BookInfoManager cache.
-- Returns false when nothing is cached yet (extraction is needed).
function Library:loadMeta(entry)
    local info = BookInfoManager:getBookInfo(entry.file, false)
    local _, filename = util.splitFilePathName(entry.file)
    local basename = util.splitFileNameSuffix(filename)
    if info and info.in_progress == 0 then
        local usable = info.has_meta and not info.ignore_meta
        entry.title = usable and info.title and info.title ~= "" and info.title or basename
        entry.authors = usable and info.authors or nil
        entry.author = firstAuthor(entry.authors)
        entry.series = usable and info.series or nil
        entry.series_index = usable and info.series_index or nil
        entry.language = usable and info.language or nil
        entry.keywords = usable and info.keywords or nil
        entry.description = usable and info.description or nil
        entry.pages = info.pages
        entry.has_cover = info.has_cover and not info.ignore_cover and true or false
        entry.cover_fetched = info.cover_fetched and true or false
        entry.unsupported = info.unsupported
        entry.meta_loaded = true
        return entry.cover_fetched or entry.unsupported ~= nil
    end
    entry.title = entry.title or basename
    entry.meta_loaded = false
    return false
end

--- Refresh reading status and progress of an entry from its sidecar.
function Library:loadStatus(entry, force)
    if force then
        BookList.resetBookInfoCache(entry.file)
    end
    local info = BookList.getBookInfo(entry.file)
    if info.been_opened then
        entry.status = info.status or "reading"
        entry.percent = info.percent_finished or 0
        entry.rating = info.rating
        entry.has_annotations = info.has_annotations
        if info.pages then entry.pages = info.pages end
    else
        entry.status = "new"
        entry.percent = 0
    end
end

local function historyTimes()
    local times = {}
    for _, item in ipairs(ReadHistory.hist) do
        times[item.file] = item.time
    end
    return times
end

--- Walk the library folders and rebuild the index.
function Library:scan()
    local start = os.clock()
    local found = {}
    local seen = {}
    for _, dir in ipairs(self:getFolders()) do
        if lfs.attributes(dir, "mode") == "directory" then
            walk((dir:gsub("/+$", "")), 0, found, seen)
        end
    end
    local times = historyTimes()
    local by_file, pending = {}, {}
    for _, entry in ipairs(found) do
        -- keep what we already know, so a rescan is cheap on the UI
        local old = self.by_file[entry.file]
        if old then
            old.size, old.added = entry.size, entry.added
            entry = old
        end
        if not self:loadMeta(entry) then
            pending[#pending + 1] = entry.file
        end
        self:loadStatus(entry)
        entry.last_read = times[entry.file]
        by_file[entry.file] = entry
    end
    -- two paths can reach the same file through symlinks; index each file once
    local books = {}
    for _, entry in pairs(by_file) do
        books[#books + 1] = entry
    end
    self.books, self.by_file, self.pending = books, by_file, pending
    self.scanned = true
    logger.info(string.format("Maca library: %d books, %d to extract, scanned in %.0f ms",
        #books, #pending, (os.clock() - start) * 1000))
    self:notify()
end

function Library:ensureScanned()
    if not self.scanned then
        self:scan()
    end
end

--- Refresh one book after it was read or changed.
function Library:refreshBook(file)
    local entry = self.by_file[file]
    if not entry then return end
    self:loadMeta(entry)
    self:loadStatus(entry, true)
    for _, item in ipairs(ReadHistory.hist) do
        if item.file == file then
            entry.last_read = item.time
            break
        end
    end
end

--- Extract metadata and covers of pending books in a background process.
function Library:extractPending(cover_specs)
    if #self.pending == 0 or self.extracting then return end
    local files = {}
    for _, file in ipairs(self.pending) do
        files[#files + 1] = { filepath = file, cover_specs = cover_specs }
    end
    if not BookInfoManager:extractInBackground(files) then return end
    self.extracting = true
    local function poll()
        local still_pending = {}
        local changed = false
        for _, file in ipairs(self.pending) do
            local entry = self.by_file[file]
            if entry then
                if self:loadMeta(entry) then
                    changed = true
                else
                    still_pending[#still_pending + 1] = file
                end
            end
        end
        self.pending = still_pending
        if changed then self:notify() end
        if BookInfoManager:isExtractingInBackground() and #still_pending > 0 then
            UIManager:scheduleIn(1, poll)
        else
            self.extracting = false
            -- whatever is left failed to extract; do not retry in a loop
            self.pending = {}
            self:notify()
        end
    end
    self.poll = poll
    UIManager:scheduleIn(1, poll)
end

function Library:stopExtraction()
    if self.poll then
        UIManager:unschedule(self.poll)
        self.poll = nil
    end
    self.extracting = false
end

-- Sorting ---------------------------------------------------------------

local function sortKey(s)
    return util.stringLower(s or "")
end

local sorters = {
    recent = function(a, b)
        local ta, tb = a.last_read or 0, b.last_read or 0
        if ta ~= tb then return ta > tb end
        return (a.added or 0) > (b.added or 0)
    end,
    added = function(a, b)
        if (a.added or 0) ~= (b.added or 0) then return (a.added or 0) > (b.added or 0) end
        return sortKey(a.title) < sortKey(b.title)
    end,
    title = function(a, b) return sortKey(a.title) < sortKey(b.title) end,
    author = function(a, b)
        local aa, ab = sortKey(a.author or "\u{FFFF}"), sortKey(b.author or "\u{FFFF}")
        if aa ~= ab then return aa < ab end
        if a.series and a.series == b.series then
            return (a.series_index or 0) < (b.series_index or 0)
        end
        return sortKey(a.title) < sortKey(b.title)
    end,
    progress = function(a, b)
        if (a.percent or 0) ~= (b.percent or 0) then return (a.percent or 0) > (b.percent or 0) end
        return sortKey(a.title) < sortKey(b.title)
    end,
}

Library.sort_names = {
    { "recent", _("Recently read") },
    { "added", _("Recently added") },
    { "title", _("Title") },
    { "author", _("Author") },
    { "progress", _("Progress") },
}

Library.status_names = {
    { "all", _("All") },
    { "reading", _("Reading") },
    { "new", _("Unread") },
    { "complete", _("Finished") },
    { "abandoned", _("On hold") },
}

Library.group_names = {
    { "none", _("No grouping") },
    { "author", _("Author") },
    { "series", _("Series") },
    { "folder", _("Folder") },
    { "tag", _("Tag") },
}

local function matches(entry, needle)
    local function has(s)
        return s and util.stringLower(s):find(needle, 1, true) ~= nil
    end
    return has(entry.title) or has(entry.authors) or has(entry.series) or has(entry.keywords)
end

--- Return the books matching a query.
-- @tparam table q { status =, search =, sort =, group_key =, group_value = }
function Library:query(q)
    q = q or {}
    local needle = q.search and q.search ~= "" and util.stringLower(q.search) or nil
    local out = {}
    for _, entry in ipairs(self.books) do
        local ok = true
        if q.status and q.status ~= "all" and entry.status ~= q.status then ok = false end
        if ok and needle and not matches(entry, needle) then ok = false end
        if ok and q.group_key then
            ok = false
            for _, value in ipairs(self:groupValues(entry, q.group_key)) do
                if value == q.group_value then ok = true break end
            end
        end
        if ok then out[#out + 1] = entry end
    end
    local sorter = sorters[q.sort or "recent"] or sorters.recent
    if q.group_key == "series" then
        sorter = function(a, b)
            if (a.series_index or 0) ~= (b.series_index or 0) then
                return (a.series_index or 0) < (b.series_index or 0)
            end
            return sortKey(a.title) < sortKey(b.title)
        end
    end
    table.sort(out, sorter)
    return out
end

function Library:groupValues(entry, key)
    if key == "author" then
        local values = {}
        for author in (entry.authors or ""):gmatch("[^\n]+") do
            values[#values + 1] = author
        end
        if #values == 0 then values[1] = _("Unknown author") end
        return values
    elseif key == "series" then
        return entry.series and { entry.series } or {}
    elseif key == "folder" then
        local dir = util.splitFilePathName(entry.file)
        dir = dir:gsub("/+$", "")
        return { (select(2, util.splitFilePathName(dir))) }
    elseif key == "tag" then
        local values = {}
        for tag in (entry.keywords or ""):gmatch("[^\n]+") do
            values[#values + 1] = tag
        end
        return values
    end
    return {}
end

--- Return groups for a grouping key: { { name =, books = {...} }, ... }.
function Library:groups(key, q)
    local base = self:query{ status = q and q.status, search = q and q.search, sort = "title" }
    local map, list = {}, {}
    for _, entry in ipairs(base) do
        for _, value in ipairs(self:groupValues(entry, key)) do
            local group = map[value]
            if not group then
                group = { name = value, books = {} }
                map[value] = group
                list[#list + 1] = group
            end
            group.books[#group.books + 1] = entry
        end
    end
    table.sort(list, function(a, b) return sortKey(a.name) < sortKey(b.name) end)
    return list
end

function Library:counts()
    local counts = { all = #self.books, reading = 0, new = 0, complete = 0, abandoned = 0 }
    for _, entry in ipairs(self.books) do
        counts[entry.status] = (counts[entry.status] or 0) + 1
    end
    return counts
end

--- The book that follows `entry` in its series, if the library has it.
function Library:nextInSeries(entry)
    if not entry.series or not entry.series_index then return nil end
    local best
    for _, other in ipairs(self.books) do
        if other ~= entry and other.series == entry.series and other.series_index
                and other.series_index > entry.series_index then
            if not best or other.series_index < best.series_index then best = other end
        end
    end
    return best
end

--- The book to offer as "continue reading": most recently read, not finished.
function Library:current()
    local best
    for _, entry in ipairs(self.books) do
        if entry.last_read and entry.status ~= "complete" and entry.status ~= "new" then
            if not best or entry.last_read > best.last_read then best = entry end
        end
    end
    return best
end

return Library
