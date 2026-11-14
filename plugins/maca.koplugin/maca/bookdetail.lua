--[[--
Book page: cover, description, progress, reading time and actions.

@module koplugin.maca.bookdetail
--]]--

local Animator = require("maca/animator")
local BD = require("ui/bidi")
local BookList = require("ui/widget/booklist")
local Covers = require("maca/covers")
local Library = require("maca/library")
local MacaScreen = require("maca/screen")
local Rows = require("maca/rows")
local Stats = require("maca/stats")
local Theme = require("maca/theme")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template
local dp = Theme.dp
local keep = Rows.keep
local M = Rows.MARGIN

local BookDetail = MacaScreen:extend{
    ui = nil,
    entry = nil,
    on_open = nil,   -- function(): open the book
    on_open_other = nil, -- function(entry): open another book (next in series)
    on_change = nil, -- function(): the book's status changed or it was deleted
}

function BookDetail:init()
    self.on_back = function()
        Animator.transition({ kind = "uncover", dir = "right", duration = 0.22 }, function()
            UIManager:close(self)
        end)
    end
    MacaScreen.init(self)
    self:rebuild()
end

function BookDetail:onResize()
    local args = { ui = self.ui, entry = self.entry, on_open = self.on_open, on_change = self.on_change,
        on_open_other = self.on_open_other }
    UIManager:close(self)
    UIManager:show(BookDetail:new(args))
end

function BookDetail:setStatus(status)
    local entry = self.entry
    local doc_settings = BookList.getDocSettings(entry.file)
    local summary = doc_settings:readSetting("summary") or {}
    summary.status = status
    filemanagerutil.saveSummary(doc_settings, summary)
    BookList.setBookInfoCacheProperty(entry.file, "status", status)
    Library:loadStatus(entry)
    if self.on_change then self.on_change() end
    self:rebuild(true)
end

-- Cover beside title, author and series.
local function headerRow(w, entry)
    local cover_w = math.min(dp(150), math.floor(w * 0.36))
    local cover_h = math.floor(cover_w * 1.5)
    return Rows.custom{
        h = cover_h + dp(20),
        paint = function(row, bb, x, y)
            local tx = x + M + cover_w + dp(18)
            local tw = w - (tx - x) - M
            if not row.built then
                row.title = keep(row, Theme.textBox(entry.title or "", 21, tw, 4, { bold = true }))
                if entry.authors then
                    row.author = keep(row, Theme.textBox((entry.authors:gsub("\n", ", ")), 15, tw, 2, { color = Theme.MUTED }))
                end
                if entry.series then
                    local series = entry.series
                    if entry.series_index then
                        series = T(_("%1 · Book %2"), series, string.format("%g", entry.series_index))
                    end
                    row.series = keep(row, Theme.textBox(series, 13.5, tw, 2, { color = Theme.MUTED }))
                end
                row.built = true
            end
            Covers:paint(bb, x + M, y + dp(4), cover_w, cover_h, entry)
            local ty = y + dp(4)
            row.title:paintTo(bb, tx, ty)
            ty = ty + row.title:getSize().h + dp(6)
            if row.author then
                row.author:paintTo(bb, tx, ty)
                ty = ty + row.author:getSize().h + dp(6)
            end
            if row.series then row.series:paintTo(bb, tx, ty) end
        end,
    }
end

-- Label / value pairs in two columns.
local function facts(w, items)
    local col_w = math.floor((w - 2 * M) / 2)
    local line_h = dp(52)
    local lines = math.ceil(#items / 2)
    return Rows.custom{
        h = lines * line_h + dp(4),
        paint = function(row, bb, x, y)
            if not row.built then
                row.cells = {}
                for i, item in ipairs(items) do
                    row.cells[i] = {
                        keep(row, Theme.text(item[1], 12.5, { color = Theme.MUTED, max_width = col_w - dp(8) })),
                        keep(row, Theme.text(item[2], 16, { bold = true, max_width = col_w - dp(8) })),
                    }
                end
                row.built = true
            end
            for i, cell in ipairs(row.cells) do
                local cx = x + M + ((i - 1) % 2) * col_w
                local cy = y + math.floor((i - 1) / 2) * line_h
                cell[1]:paintTo(bb, cx, cy)
                cell[2]:paintTo(bb, cx, cy + cell[1]:getSize().h + dp(1))
            end
        end,
    }
end

function BookDetail:rebuild(keep_offset)
    local entry = self.entry
    local w = self:width()
    -- on wide screens keep the page a comfortable reading width
    local rows = {}
    self:setHeader("", { { icon = "info", on_tap = function()
        self.ui.bookinfo:show(entry.file)
    end } }, self.on_back)

    rows[#rows + 1] = headerRow(w, entry)

    local primary
    if entry.status == "new" then
        primary = _("Start reading")
    elseif entry.status == "complete" then
        primary = _("Read again")
    else
        primary = T(_("Continue · %1%"), math.floor((entry.percent or 0) * 100 + 0.5))
    end
    rows[#rows + 1] = Rows.buttons(w, { { label = primary, primary = true, on_tap = function()
        UIManager:close(self)
        self.on_open()
    end } })
    if entry.status ~= "new" then
        rows[#rows + 1] = Rows.custom{
            h = dp(22),
            paint = function(row, bb, x, y)
                Theme.progress(bb, x + M, y + dp(2), w - 2 * M, dp(6), entry.status == "complete" and 1 or entry.percent)
            end,
        }
    end

    local next_book = Library:nextInSeries(entry)
    if next_book and entry.status == "complete" then
        rows[#rows + 1] = Rows.item(w, "forward", T(_("Next in series: %1"), next_book.title), nil, function()
            Animator.transition({ kind = "cover", dir = "left", duration = 0.24 }, function()
                UIManager:show(BookDetail:new{
                    ui = self.ui, entry = next_book, on_change = self.on_change,
                    on_open = function()
                        UIManager:close(self)
                        self.on_open_other(next_book)
                    end,
                })
            end)
        end)
    end

    -- reading facts
    local stats = Stats:book(entry.file)
    local items = {}
    if stats and stats.seconds > 0 then
        items[#items + 1] = { _("Time read"), Theme.duration(stats.seconds) }
        local left = entry.status ~= "complete" and Stats:timeLeft(entry.file, entry.percent, entry.pages)
        if left and left > 60 then
            items[#items + 1] = { _("Time left"), Theme.duration(left) }
        end
        items[#items + 1] = { _("Days read"), tostring(stats.days) }
        if stats.seconds_per_page then
            items[#items + 1] = { _("Pace"), T(_("%1 pages/h"), math.floor(3600 / stats.seconds_per_page + 0.5)) }
        end
    end
    if entry.pages then
        items[#items + 1] = { _("Length"), T(N_("%1 page", "%1 pages", entry.pages), entry.pages) }
    end
    if entry.last_read then
        items[#items + 1] = { _("Last read"), os.date("%d %b %Y", entry.last_read) }
    end
    if #items > 0 then
        rows[#rows + 1] = Rows.spacer(dp(8))
        rows[#rows + 1] = facts(w, items)
    end

    -- status
    rows[#rows + 1] = Rows.section(_("Status"))
    local chips = {
        { "reading", _("Reading") },
        { "abandoned", _("On hold") },
        { "complete", _("Finished") },
    }
    rows[#rows + 1] = Rows.chips(w, chips, entry.status, function(status) self:setStatus(status) end)

    if entry.description and entry.description ~= "" then
        rows[#rows + 1] = Rows.section(_("About this book"))
        local text = util.htmlToPlainTextIfHtml(entry.description)
        rows[#rows + 1] = Rows.paragraph(w, text, 15, {
            max_lines = not self.full_description and 8 or nil,
            line_height = 0.35,
            on_tap = function()
                self.full_description = not self.full_description
                self:rebuild(true)
            end,
        })
    end

    local note_count = entry.has_annotations and #require("maca/notebook").items(entry.file) or 0
    rows[#rows + 1] = Rows.spacer(dp(8))
    rows[#rows + 1] = Rows.item(w, "note", _("Highlights and notes"), tostring(note_count), function()
        require("maca/notebook").showBook(self.ui, entry)
    end)

    rows[#rows + 1] = Rows.section(_("File"))
    local dir, name = util.splitFilePathName(entry.file)
    rows[#rows + 1] = Rows.item(w, "note", name, nil, nil, {
        sub = T("%1 · %2", util.getFriendlySize(entry.size or 0), os.date("%d %b %Y", entry.added or 0)),
    })
    rows[#rows + 1] = Rows.item(w, "folder", BD.dirpath(filemanagerutil.abbreviate(dir)), nil, nil)
    rows[#rows + 1] = Rows.item(w, "bookmark", _("Collections"), nil, function()
        self.ui.collections:onShowCollList(entry.file, function() end)
    end)
    rows[#rows + 1] = Rows.item(w, "trash", _("Delete book"), nil, function()
        self.ui:showDeleteFileDialog(entry.file, function()
            UIManager:close(self)
            Covers:forget(entry.file)
            Library:scan()
        end)
    end, { no_chevron = true, no_line = true })
    if not keep_offset then self.scroll.offset = 0 end
    self:setRows(rows, true)
    self:redraw()
end

return BookDetail
