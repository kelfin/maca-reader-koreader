--[[--
Reading-screen controls: a top and bottom bar shown by tapping the middle of
the page, and a display sheet ("Aa") with the settings people change most.

@module koplugin.maca.reader
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Theme = require("maca/theme")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template
local Screen = Device.screen
local dp = Theme.dp

local Reader = {}

-- Page themes ---------------------------------------------------------------

-- `bg` is the page colour before night mode inverts the screen.
Reader.themes = {
    { key = "light", name = _("Light"), bg = 0xFFFFFF, night = false, swatch = { 0xFF, 0xFF, 0xFF } },
    { key = "sepia", name = _("Sepia"), bg = 0xF5EBD5, night = false, swatch = { 0xF5, 0xEB, 0xD5 } },
    { key = "paper", name = _("Paper"), bg = 0xE9E9E4, night = false, swatch = { 0xE9, 0xE9, 0xE4 } },
    { key = "dim", name = _("Dim"), bg = 0xD4D4D4, night = true, swatch = { 0x2B, 0x2B, 0x2B } },
    { key = "dark", name = _("Dark"), bg = 0xFFFFFF, night = true, swatch = { 0x00, 0x00, 0x00 } },
}

function Reader.currentTheme()
    local key = G_reader_settings:readSetting("maca_reader_theme")
    if not key then
        key = G_reader_settings:isTrue("night_mode") and "dark" or "light"
    end
    for _, theme in ipairs(Reader.themes) do
        if theme.key == key then return theme end
    end
    return Reader.themes[1]
end

-- Many books force a white page in their own stylesheet; with a tinted theme
-- that must be dropped, or the tint only shows in the margins.
local TINT_CSS = [[
DocFragment, body, body > div, body > section { background-color: transparent !important; }
]]

local function themeIsTinted(theme)
    return theme.bg ~= 0xFFFFFF
end

--- Make the book's stylesheet step aside while a tinted theme is active.
-- Call from the plugin's init, before the document settings are read.
function Reader.hookStyles(ui)
    local styletweak = ui.styletweak
    if not styletweak or styletweak.maca_hooked then return end
    styletweak.maca_hooked = true
    local getCssText = styletweak.getCssText
    styletweak.getCssText = function(this)
        local css = getCssText(this)
        if themeIsTinted(Reader.currentTheme()) then
            css = (css and css .. "\n" or "") .. TINT_CSS
        end
        return css
    end
end

function Reader.applyTheme(ui, key)
    local theme
    for _, item in ipairs(Reader.themes) do
        if item.key == key then theme = item end
    end
    if not theme then return end
    local was_tinted = themeIsTinted(Reader.currentTheme())
    G_reader_settings:saveSetting("maca_reader_theme", key)
    if themeIsTinted(theme) then
        G_reader_settings:saveSetting("cre_background_color", theme.bg)
    else
        G_reader_settings:delSetting("cre_background_color")
    end
    local doc = ui.document
    if doc and doc.provider == "crengine" then
        doc:setBackgroundColor(theme.bg)
        doc:resetCallCache()
        if was_tinted ~= themeIsTinted(theme) then
            -- the stylesheet override comes or goes: the book is laid out again
            ui:handleEvent(Event:new("ApplyStyleSheet"))
        end
    end
    UIManager:broadcastEvent(Event:new("SetNightMode", theme.night))
    UIManager:setDirty("all", "ui")
end

-- Shared pieces -------------------------------------------------------------

local function isRolling(ui)
    return ui.rolling ~= nil
end

local function pageInfo(ui)
    local page = ui:getCurrentPage() or 1
    local count = ui.document:getPageCount() or 1
    return page, math.max(1, count)
end

local function secondsPerPage(ui)
    local stats = ui.statistics
    local avg = stats and stats.avg_time
    if avg and avg > 0 and avg == avg then return avg end
end

-- Hit regions are rebuilt on every paint: { x, y, w, h, fn }.
local function hit(self, x, y, w, h, fn)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

local function dispatchTap(self, pos)
    for i = #self.hits, 1, -1 do
        local r = self.hits[i]
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            r.fn(pos)
            return true
        end
    end
    return false
end

local function paintSlider(bb, x, y, w, fraction)
    local track_h, knob = dp(4), dp(18)
    Theme.progress(bb, x, y - math.floor(track_h / 2), w, track_h, fraction)
    local kx = x + math.floor((w - knob) * math.max(0, math.min(1, fraction)))
    Theme.fillRect(bb, kx, y - math.floor(knob / 2), knob, knob, Theme.accent(), math.floor(knob / 2))
end

-- Bars ----------------------------------------------------------------------

local Bars = InputContainer:extend{
    ui = nil,
}

function Bars:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.top_h = dp(56)
    self.bottom_h = dp(104)
    self.widgets = {}
    self.hits = {}
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Touch = { GestureRange:new{ ges = "touch", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Bars:free()
    for _, widget in pairs(self.widgets) do
        widget:free()
    end
    self.widgets = {}
end

function Bars:refresh()
    self:free()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Bars:close()
    UIManager:close(self)
end

function Bars:onClose()
    self:close()
    return true
end

function Bars:onCloseWidget()
    self:free()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function Bars:paintTo(bb, x, y)
    self.hits = {}
    local w, h = self.dimen.w, self.dimen.h
    local ws = self.widgets
    local ui = self.ui
    local icon_size = dp(24)
    local slot = dp(48)

    -- top bar
    bb:paintRect(x, y, w, self.top_h, Theme.BG)
    bb:paintRect(x, y + self.top_h - 1, w, 1, Theme.LINE)
    local function icon(key, name, ix, fn)
        ws[key] = ws[key] or Theme.icon(name, icon_size)
        ws[key]:paintTo(bb, ix + math.floor((slot - icon_size) / 2), y + math.floor((self.top_h - icon_size) / 2))
        hit(self, ix, y, slot, self.top_h, fn)
    end
    icon("back", "back", x + dp(4), function()
        self:close()
        ui:handleEvent(Event:new("Home"))
    end)
    local bookmarked = ui.bookmark and ui.bookmark:isPageBookmarked()
    local items = {
        { "menu", "more", function() self:showMore() end },
        { "aa", "text", function() self:showDisplay() end },
        { bookmarked and "bm_on" or "bm", bookmarked and "bookmark-on" or "bookmark", function()
            ui:handleEvent(Event:new("ToggleBookmark"))
            self:refresh()
        end },
        { "search", "search", function()
            self:close()
            ui:handleEvent(Event:new("ShowFulltextSearchInput"))
        end },
        { "toc", "contents", function()
            self:close()
            ui:handleEvent(Event:new("ShowToc"))
        end },
    }
    local ix = x + w - dp(4)
    for _, item in ipairs(items) do
        ix = ix - slot
        icon(item[1], item[2], ix, item[3])
    end
    local title_x = x + dp(4) + slot + dp(4)
    local title_w = ix - title_x - dp(8)
    if title_w > dp(90) then
        local props = ui.doc_props or {}
        ws.title = ws.title or Theme.text(props.display_title or "", 16, { bold = true, max_width = title_w })
        ws.title:paintTo(bb, title_x, y + math.floor((self.top_h - ws.title:getSize().h) / 2))
    end

    -- bottom bar
    local by = y + h - self.bottom_h
    bb:paintRect(x, by, w, self.bottom_h, Theme.BG)
    bb:paintRect(x, by, w, 1, Theme.LINE)
    local margin = dp(20)
    local page, count = pageInfo(ui)
    local shown_page = self.seek_page or page
    local fraction = count > 1 and (shown_page - 1) / (count - 1) or 0
    local chapter = ui.toc and ui.toc:getTocTitleByPage(shown_page) or ""
    if chapter ~= self.chapter_text and ws.chapter then
        ws.chapter:free()
        ws.chapter = nil
    end
    self.chapter_text = chapter
    if chapter ~= "" then
        ws.chapter = ws.chapter or Theme.text(chapter, 13.5, { color = Theme.MUTED, max_width = w - 2 * margin })
        ws.chapter:paintTo(bb, x + math.floor((w - ws.chapter:getSize().w) / 2), by + dp(12))
    end
    local slider_y = by + dp(50)
    self.slider = { x = x + margin, w = w - 2 * margin, y = slider_y }
    paintSlider(bb, self.slider.x, slider_y, self.slider.w, fraction)

    local left = T(_("Page %1 of %2"), shown_page, count)
    local right
    local per_page = secondsPerPage(ui)
    if self.seek_page then
        right = T(_("%1%"), math.floor(fraction * 100 + 0.5))
    elseif per_page then
        local chapter_left = ui.toc and ui.toc:getChapterPagesLeft(page)
        if chapter_left and chapter_left > 0 then
            right = T(_("%1 left in chapter"), Theme.duration(chapter_left * per_page))
        else
            right = T(_("%1 left in book"), Theme.duration((count - page) * per_page))
        end
    else
        right = T(_("%1%"), math.floor(fraction * 100 + 0.5))
    end
    -- these change as the slider moves, so they are rebuilt on each paint
    local left_widget = Theme.text(left, 13, { color = Theme.MUTED })
    local right_widget = Theme.text(right, 13, { color = Theme.MUTED })
    left_widget:paintTo(bb, x + margin, by + dp(70))
    right_widget:paintTo(bb, x + w - margin - right_widget:getSize().w, by + dp(70))
    left_widget:free()
    right_widget:free()
end

function Bars:inSlider(pos)
    local s = self.slider
    return s and pos.y > s.y - dp(26) and pos.y < s.y + dp(26)
end

function Bars:pageAt(pos)
    local s = self.slider
    local _, count = pageInfo(self.ui)
    local fraction = math.max(0, math.min(1, (pos.x - s.x) / s.w))
    return math.floor(fraction * (count - 1) + 0.5) + 1
end

function Bars:gotoPage(page)
    local ui = self.ui
    if ui.link then ui.link:addCurrentLocationToStack() end
    ui:handleEvent(Event:new("GotoPage", page))
end

function Bars:onTap(_, ges)
    if dispatchTap(self, ges.pos) then return true end
    if self:inSlider(ges.pos) then
        self:gotoPage(self:pageAt(ges.pos))
        self:refresh()
        return true
    end
    local y = ges.pos.y - self.dimen.y
    if y > self.top_h and y < self.dimen.h - self.bottom_h then
        self:close()
    end
    return true
end

function Bars:onTouch(_, ges)
    self.seeking = self:inSlider(ges.pos)
    return true
end

function Bars:onPan(_, ges)
    if self.seeking then
        self.seek_page = self:pageAt(ges.pos)
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
    return true
end

function Bars:endSeek()
    if self.seeking and self.seek_page then
        local page = self.seek_page
        self.seek_page = nil
        self.seeking = false
        self:gotoPage(page)
        self:refresh()
        return true
    end
    self.seeking = false
end

function Bars:onPanRelease()
    self:endSeek()
    return true
end

function Bars:onSwipe()
    if not self:endSeek() then
        self:close()
    end
    return true
end

function Bars:onHold()
    return true
end

function Bars:showDisplay()
    self:close()
    UIManager:show(Reader.Sheet:new{ ui = self.ui })
end

function Bars:showMore()
    local ui = self.ui
    local dialog
    local function item(text, fn)
        return { {
            text = text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:close()
                fn()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        buttons = {
            item(_("Notes and bookmarks"), function() ui:handleEvent(Event:new("ShowBookmark")) end),
            item(_("About this book"), function() ui:handleEvent(Event:new("ShowBookInfo")) end),
            item(_("More display options"), function() ui:handleEvent(Event:new("ShowConfigMenu")) end),
            item(_("Full menu"), function() ui.menu:onShowMenu() end),
        },
    }
    UIManager:show(dialog)
end

Reader.Bars = Bars

-- Display sheet ---------------------------------------------------------------

local Sheet = InputContainer:extend{
    ui = nil,
}

local PREFERRED_FONTS = {
    "Literata", "Bitter", "Noto Serif", "Source Serif 4", "Crimson Pro", "Merriweather",
    "Atkinson Hyperlegible", "Noto Sans", "Lexend",
}

local function availableFonts(ui)
    local have = {}
    local ok, cre = pcall(function() return require("document/credocument"):engineInit() end)
    if ok and cre then
        for _, face in ipairs(cre.getFontFaces()) do have[face] = true end
    end
    local list = {}
    for _, name in ipairs(PREFERRED_FONTS) do
        if have[name] then list[#list + 1] = name end
    end
    local current = ui.font and ui.font.font_face
    if current then
        local found = false
        for _, name in ipairs(list) do
            if name == current then found = true end
        end
        if not found then table.insert(list, 1, current) end
    end
    return list
end

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.widgets = {}
    self.hits = {}
    self.rolling = isRolling(self.ui)
    self.powerd = Device:hasFrontlight() and Device:getPowerDevice() or nil
    self.fonts = self.rolling and availableFonts(self.ui) or {}
    self.font_page = 1
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Touch = { GestureRange:new{ ges = "touch", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- a comfortable column on tablets, full width on phones
    self.sheet_w = math.min(self.dimen.w, dp(560))
    local rows = (self.powerd and 1 or 0) + 1 + (self.rolling and 4 or 0)
    self.row_h = dp(60)
    self.sheet_h = rows * self.row_h + dp(60)
end

function Sheet:free()
    for _, widget in pairs(self.widgets) do
        widget:free()
    end
    self.widgets = {}
end

function Sheet:refresh()
    self:free()
    UIManager:setDirty("all", function() return "ui", self.dimen end)
end

function Sheet:onClose()
    UIManager:close(self)
    return true
end

function Sheet:onCloseWidget()
    self:free()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

local line_spacings = { { 90, _("Tight") }, { 100, _("Normal") }, { 115, _("Open") }, { 130, _("Wide") } }

local function marginChoices()
    -- wider screens want proportionally wider margins
    local wide = math.min(Screen:getWidth(), Screen:getHeight()) >= dp(600)
    if wide then
        return { { 25, _("Narrow") }, { 50, _("Normal") }, { 85, _("Wide") } }
    end
    return { { 12, _("Narrow") }, { 25, _("Normal") }, { 45, _("Wide") } }
end
Reader.marginChoices = marginChoices

function Sheet:paintTo(bb, x, y)
    self.hits = {}
    local ws = self.widgets
    local ui = self.ui
    local sw, sh = self.sheet_w, self.sheet_h
    local sx = x + math.floor((self.dimen.w - sw) / 2)
    local sy = y + self.dimen.h - sh
    self.sheet_rect = { x = sx, y = sy, w = sw, h = sh }
    Theme.fillRect(bb, sx, sy, sw, sh + dp(20), Theme.BG, dp(18))
    bb:paintRect(sx + dp(18), sy, sw - dp(36), 1, Theme.LINE)
    -- grab handle
    Theme.fillRect(bb, sx + math.floor((sw - dp(36)) / 2), sy + dp(8), dp(36), dp(4), Theme.TRACK, dp(2))

    local margin = dp(20)
    local label_w = dp(84)
    local cx = sx + margin + label_w
    local cw = sw - 2 * margin - label_w
    local ry = sy + dp(22)
    local row_h = self.row_h

    local function label(key, str)
        ws[key] = ws[key] or Theme.text(str, 13.5, { color = Theme.MUTED, max_width = label_w - dp(6) })
        ws[key]:paintTo(bb, sx + margin, ry + math.floor((row_h - ws[key]:getSize().h) / 2))
    end

    -- Segmented choice: equal cells, the active one filled.
    local function segments(key, choices, current, on_pick)
        local gap = dp(6)
        local n = #choices
        local cell_w = math.floor((cw - (n - 1) * gap) / n)
        local cell_h = dp(38)
        local cy = ry + math.floor((row_h - cell_h) / 2)
        for i, choice in ipairs(choices) do
            local active = choice[1] == current
            local bx = cx + (i - 1) * (cell_w + gap)
            Theme.fillRect(bb, bx, cy, cell_w, cell_h, active and Theme.accent() or Theme.CARD, dp(10))
            local wkey = key .. i .. (active and "a" or "")
            ws[wkey] = ws[wkey] or Theme.text(choice[2], 13.5, {
                bold = active, color = active and Theme.gray(255) or Theme.FG, max_width = cell_w - dp(8),
            })
            local tw = ws[wkey]:getSize()
            ws[wkey]:paintTo(bb, bx + math.floor((cell_w - tw.w) / 2), cy + math.floor((cell_h - tw.h) / 2))
            hit(self, bx, ry, cell_w, row_h, function() on_pick(choice[1]) end)
        end
    end

    -- brightness
    if self.powerd then
        label("l_bright", _("Brightness"))
        local powerd = self.powerd
        local min, max = powerd.fl_min or 0, powerd.fl_max or 100
        local value = self.brightness or powerd:frontlightIntensity()
        local icon_size = dp(20)
        ws.sun = ws.sun or Theme.icon("sun", icon_size)
        ws.sun:paintTo(bb, cx, ry + math.floor((row_h - icon_size) / 2))
        local slider_x = cx + icon_size + dp(14)
        local slider_w = cw - icon_size - dp(14)
        self.bright_slider = { x = slider_x, w = slider_w, y = ry + math.floor(row_h / 2), min = min, max = max }
        paintSlider(bb, slider_x, self.bright_slider.y, slider_w, max > min and (value - min) / (max - min) or 0)
        ry = ry + row_h
    end

    -- theme swatches
    label("l_theme", _("Theme"))
    local current = Reader.currentTheme()
    local themes = self.rolling and Reader.themes or { Reader.themes[1], Reader.themes[5] }
    local swatch = dp(38)
    local step = math.floor((cw - swatch) / math.max(1, #Reader.themes - 1))
    for i, theme in ipairs(themes) do
        local bx = cx + (i - 1) * step
        local by = ry + math.floor((row_h - swatch) / 2)
        local active = theme.key == current.key
        if active then
            Theme.fillRect(bb, bx - dp(4), by - dp(4), swatch + dp(8), swatch + dp(8), Theme.accent(), math.floor(swatch / 2) + dp(4))
            Theme.fillRect(bb, bx - dp(2), by - dp(2), swatch + dp(4), swatch + dp(4), Theme.BG, math.floor(swatch / 2) + dp(2))
        else
            Theme.fillRect(bb, bx - dp(1), by - dp(1), swatch + dp(2), swatch + dp(2), Theme.FAINT, math.floor(swatch / 2) + dp(1))
        end
        Theme.fillRect(bb, bx, by, swatch, swatch, Theme.rgb(theme.swatch[1], theme.swatch[2], theme.swatch[3]),
            math.floor(swatch / 2))
        hit(self, bx - dp(8), ry, swatch + dp(16), row_h, function()
            Reader.applyTheme(ui, theme.key)
            self:refresh()
        end)
    end
    ry = ry + row_h

    if self.rolling then
        local font = ui.font
        -- text size
        label("l_size", _("Text size"))
        local size = font.configurable.font_size
        local button_w, button_h = dp(84), dp(38)
        local by = ry + math.floor((row_h - button_h) / 2)
        local icon_size = dp(22)
        local function sizeButton(key, name, bx, delta)
            Theme.fillRect(bb, bx, by, button_w, button_h, Theme.CARD, dp(10))
            ws[key] = ws[key] or Theme.icon(name, icon_size)
            ws[key]:paintTo(bb, bx + math.floor((button_w - icon_size) / 2), by + math.floor((button_h - icon_size) / 2))
            hit(self, bx, ry, button_w, row_h, function()
                ui:handleEvent(Event:new("SetFontSize", size + delta))
                self:refresh()
            end)
        end
        sizeButton("smaller", "text-small", cx, -1)
        sizeButton("larger", "text-large", cx + cw - button_w, 1)
        local size_widget = Theme.text(string.format("%g", size), 16, { bold = true })
        size_widget:paintTo(bb, cx + math.floor((cw - size_widget:getSize().w) / 2),
            ry + math.floor((row_h - size_widget:getSize().h) / 2))
        size_widget:free()
        ry = ry + row_h

        -- font: three at a time, the last cell pages through the rest
        label("l_font", _("Font"))
        local per_page = 3
        local pages = math.max(1, math.ceil(#self.fonts / per_page))
        if self.font_page > pages then self.font_page = 1 end
        local choices = {}
        for i = (self.font_page - 1) * per_page + 1, math.min(#self.fonts, self.font_page * per_page) do
            choices[#choices + 1] = { self.fonts[i], self.fonts[i] }
        end
        if pages > 1 then
            choices[#choices + 1] = { "\0more", "···" }
        end
        segments("font" .. self.font_page .. "_", choices, font.font_face, function(face)
            if face == "\0more" then
                self.font_page = self.font_page % pages + 1
            else
                ui:handleEvent(Event:new("SetFont", face))
            end
            self:refresh()
        end)
        ry = ry + row_h

        label("l_spacing", _("Spacing"))
        local spacing = font.configurable.line_spacing
        local nearest = line_spacings[1][1]
        for _, choice in ipairs(line_spacings) do
            if math.abs(choice[1] - spacing) < math.abs(nearest - spacing) then nearest = choice[1] end
        end
        segments("spacing", line_spacings, nearest, function(value)
            ui:handleEvent(Event:new("SetLineSpace", value))
            self:refresh()
        end)
        ry = ry + row_h

        label("l_margin", _("Margins"))
        local margins = ui.document.configurable.h_page_margins or { 10, 10 }
        local choices_m = marginChoices()
        local nearest_m = choices_m[1][1]
        for _, choice in ipairs(choices_m) do
            if math.abs(choice[1] - margins[1]) < math.abs(nearest_m - margins[1]) then nearest_m = choice[1] end
        end
        segments("margin", choices_m, nearest_m, function(value)
            ui.document.configurable.h_page_margins = { value, value }
            ui:handleEvent(Event:new("SetPageHorizMargins", { value, value }))
            self:refresh()
        end)
        ry = ry + row_h
    end

    -- footer link to everything else
    ws.more = ws.more or Theme.text(_("More display options"), 13.5, { color = Theme.MUTED })
    local more_w = ws.more:getSize().w
    ws.more:paintTo(bb, sx + math.floor((sw - more_w) / 2), ry + dp(8))
    hit(self, sx, ry, sw, dp(40), function()
        UIManager:close(self)
        ui:handleEvent(Event:new("ShowConfigMenu"))
    end)
end

function Sheet:inBrightness(pos)
    local s = self.bright_slider
    return s and pos.x > s.x - dp(20) and pos.x < s.x + s.w + dp(20)
        and pos.y > s.y - dp(28) and pos.y < s.y + dp(28)
end

function Sheet:setBrightness(pos)
    local s = self.bright_slider
    local fraction = math.max(0, math.min(1, (pos.x - s.x) / s.w))
    local value = math.floor(s.min + fraction * (s.max - s.min) + 0.5)
    if value ~= self.brightness then
        self.brightness = value
        self.powerd:setIntensity(value)
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
end

function Sheet:onTap(_, ges)
    local r = self.sheet_rect
    if not r or ges.pos.y < r.y or ges.pos.x < r.x or ges.pos.x > r.x + r.w then
        UIManager:close(self)
        return true
    end
    if self:inBrightness(ges.pos) then
        self:setBrightness(ges.pos)
        return true
    end
    dispatchTap(self, ges.pos)
    return true
end

function Sheet:onTouch(_, ges)
    self.dragging = self:inBrightness(ges.pos)
    return true
end

function Sheet:onPan(_, ges)
    if self.dragging then self:setBrightness(ges.pos) end
    return true
end

function Sheet:onPanRelease()
    self.dragging = false
    return true
end

function Sheet:onSwipe(_, ges)
    if self.dragging then
        self.dragging = false
    elseif ges.direction == "south" then
        UIManager:close(self)
    end
    return true
end

function Sheet:onHold()
    return true
end

Reader.Sheet = Sheet

-- Wiring --------------------------------------------------------------------

--- Register the tap zones that open the bars. Call once the reader is ready.
function Reader.setup(ui)
    local function show()
        UIManager:show(Bars:new{ ui = ui })
        return true
    end
    ui:registerTouchZones({
        {
            id = "maca_bars_centre",
            ges = "tap",
            screen_zone = { ratio_x = 0.3, ratio_y = 0.15, ratio_w = 0.4, ratio_h = 0.7 },
            overrides = { "tap_forward", "tap_backward" },
            handler = show,
        },
        {
            id = "maca_bars_top",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readermenu_tap", "readermenu_ext_tap", "tap_forward", "tap_backward" },
            handler = show,
        },
    })
    -- Links, highlights and the status bar keep priority over our zones.
    local graph = ui.touch_zone_dg
    for _, mine in ipairs{ "maca_bars_centre", "maca_bars_top" } do
        for _, theirs in ipairs{ "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode",
                "readerfooter_tap", "inertial_scrolling_tap" } do
            if ui._zones[theirs] then
                graph:addNodeDep(mine, theirs)
            end
        end
    end
    ui:registerTouchZones({}) -- re-sort with the new priorities
end

return Reader
