--[[--
Highlights and notes: a list of books that have them, and one book's
highlights as a readable page that can be exported as Markdown.

@module koplugin.maca.notebook
--]]--

local Animator = require("maca/animator")
local Device = require("device")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Library = require("maca/library")
local MacaScreen = require("maca/screen")
local Rows = require("maca/rows")
local Theme = require("maca/theme")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template
local dp = Theme.dp
local keep = Rows.keep
local M = Rows.MARGIN

local Notebook = {}

--- Highlights and notes of a book file (page bookmarks left out), in book order.
function Notebook.items(file)
    if not DocSettings:hasSidecarFile(file) then return {} end
    local annotations = DocSettings:open(file):readSetting("annotations") or {}
    local out = {}
    for _, item in ipairs(annotations) do
        if item.drawer or (item.note and item.note ~= "") then
            out[#out + 1] = item
        end
    end
    return out
end

--- Markdown text of a book's highlights.
function Notebook.markdown(entry, items)
    local lines = { "# " .. (entry.title or "") }
    if entry.authors then
        lines[#lines + 1] = "*" .. entry.authors:gsub("\n", ", ") .. "*"
    end
    lines[#lines + 1] = ""
    local chapter
    for _, item in ipairs(items) do
        if item.chapter and item.chapter ~= chapter then
            chapter = item.chapter
            lines[#lines + 1] = "## " .. chapter
            lines[#lines + 1] = ""
        end
        if item.drawer and item.text and item.text ~= "" then
            lines[#lines + 1] = "> " .. item.text:gsub("\n", "\n> ")
        end
        if item.note and item.note ~= "" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = item.note
        end
        local where = item.pageno and T(_("Page %1"), item.pageno) or nil
        if where or item.datetime then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "— " .. table.concat({ where, item.datetime }, ", ")
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

--- Write the Markdown next to the library, in a "Notes" folder. Returns the path.
function Notebook.export(entry, items)
    local dir = Library:getFolders()[1] .. "/Notes"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    local name = util.getSafeFilename((entry.title or "notes") .. ".md", dir)
    local path = dir .. "/" .. name
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    file:write(Notebook.markdown(entry, items))
    file:close()
    return path
end

local highlight_colors = {
    red = { 0xFF, 0x8A, 0x80 }, orange = { 0xFF, 0xC4, 0x7A }, yellow = { 0xFF, 0xE5, 0x6B },
    green = { 0x9B, 0xE0, 0xA3 }, olive = { 0xC6, 0xD3, 0x7C }, cyan = { 0x8E, 0xE3, 0xEF },
    blue = { 0x9C, 0xC4, 0xFF }, purple = { 0xD0, 0xA8, 0xF5 },
}

-- One highlight: coloured edge, quoted text, the reader's note, where it is.
local function highlightRow(w, item, on_tap)
    local pad = dp(14)
    local tw = w - 2 * M - dp(18)
    local quote = item.drawer and item.text and item.text ~= "" and
        Theme.textBox(item.text, 15, tw, 8, { line_height = 0.3 }) or nil
    local note = item.note and item.note ~= "" and
        Theme.textBox(item.note, 14.5, tw, 6, { bold = true, line_height = 0.3 }) or nil
    local where = {}
    if item.chapter and item.chapter ~= "" then where[#where + 1] = item.chapter end
    if item.pageno then where[#where + 1] = T(_("Page %1"), item.pageno) end
    local meta = Theme.text(table.concat(where, " · "), 12.5, { color = Theme.MUTED, max_width = tw })
    local h = pad
    if quote then h = h + quote:getSize().h + dp(6) end
    if note then h = h + note:getSize().h + dp(6) end
    h = h + meta:getSize().h + pad
    local rgb = highlight_colors[item.color or "yellow"] or highlight_colors.yellow
    return {
        h = h,
        paint = function(row, bb, x, y)
            local ty = y + pad
            local edge = item.drawer and Theme.rgb(rgb[1], rgb[2], rgb[3]) or Theme.TRACK
            Theme.fillRect(bb, x + M, y + pad, dp(4), h - 2 * pad, edge, dp(2))
            local tx = x + M + dp(18)
            if quote then
                quote:paintTo(bb, tx, ty)
                ty = ty + quote:getSize().h + dp(6)
            end
            if note then
                note:paintTo(bb, tx, ty)
                ty = ty + note:getSize().h + dp(6)
            end
            meta:paintTo(bb, tx, ty)
            bb:paintRect(tx, y + h - 1, w - (tx - x), 1, Theme.LINE)
        end,
        tap = function() if on_tap then on_tap(item) end end,
        destroy = function()
            if quote then quote:free() end
            if note then note:free() end
            meta:free()
        end,
    }
end

local function push(screen)
    Animator.transition({ kind = "cover", dir = "left", duration = 0.24 }, function()
        UIManager:show(screen)
    end)
end

local function pop(screen)
    Animator.transition({ kind = "uncover", dir = "right", duration = 0.22 }, function()
        UIManager:close(screen)
    end)
end

--- Show one book's highlights. `ui` is the file manager.
function Notebook.showBook(ui, entry)
    local items = Notebook.items(entry.file)
    local screen
    local function export()
        local path, err = Notebook.export(entry, items)
        UIManager:show(InfoMessage:new{
            text = path and T(_("Saved to %1"), path) or T(_("Could not save the notes: %1"), err or ""),
        })
    end
    local actions = {}
    if #items > 0 then
        if Device.canShareText and Device:canShareText() then
            actions[#actions + 1] = { icon = "forward", on_tap = function()
                Device:doShareText(Notebook.markdown(entry, items), nil, entry.title, "text/markdown")
            end }
        end
        actions[#actions + 1] = { icon = "note", on_tap = export }
    end
    screen = MacaScreen:new{}
    screen:setHeader(entry.title or "", actions, function() pop(screen) end)
    local w = screen:width()
    local rows = {}
    if #items == 0 then
        rows[#rows + 1] = Rows.message(w, _("No highlights yet"),
            _("Hold on a word and drag to highlight a passage while reading. It will be kept here."))
    else
        rows[#rows + 1] = Rows.toolbar(w, T(N_("%1 highlight", "%1 highlights", #items), #items), {})
        for _, item in ipairs(items) do
            rows[#rows + 1] = highlightRow(w, item, function(tapped)
                -- open the book at this highlight
                UIManager:close(screen)
                for i = #UIManager._window_stack, 1, -1 do
                    local widget = UIManager._window_stack[i].widget
                    if widget.switchTab or widget.entry then UIManager:close(widget) end
                end
                ui:openFile(entry.file, nil, nil, nil, function()
                    local reader = require("apps/reader/readerui").instance
                    if not reader then return end
                    if reader.rolling and type(tapped.page) == "string" then
                        reader:handleEvent(Event:new("GotoXPointer", tapped.page, tapped.page))
                    elseif tonumber(tapped.page) then
                        reader:handleEvent(Event:new("GotoPage", tonumber(tapped.page)))
                    end
                end)
            end)
        end
    end
    screen:setRows(rows)
    push(screen)
end

--- Show every book that has highlights or notes.
function Notebook.showAll(ui)
    local screen = MacaScreen:new{}
    screen:setHeader(_("Highlights and notes"), nil, function() pop(screen) end)
    local w = screen:width()
    local rows = {}
    local books = {}
    for _, entry in ipairs(Library:query{ sort = "recent" }) do
        if entry.has_annotations then
            local count = #Notebook.items(entry.file)
            if count > 0 then books[#books + 1] = { entry = entry, count = count } end
        end
    end
    if #books == 0 then
        rows[#rows + 1] = Rows.message(w, _("No highlights yet"),
            _("Passages you highlight and notes you write while reading are collected here, book by book."))
    else
        for _, book in ipairs(books) do
            rows[#rows + 1] = Rows.book(w, book.entry, {
                on_tap = function(entry) Notebook.showBook(ui, entry) end,
                status_text = function()
                    return T(N_("%1 highlight", "%1 highlights", book.count), book.count)
                end,
            })
        end
    end
    screen:setRows(rows)
    push(screen)
end


return Notebook
