--[[--
Full-screen page with a header, a scrolling body and an optional bottom
navigation bar. Base of every Maca screen.

@module koplugin.maca.screen
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollView = require("scrollview")
local Theme = require("theme")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local dp = Theme.dp

local MacaScreen = InputContainer:extend{
    title = "",
    on_back = nil,      -- function; shows a back arrow when set
    actions = nil,      -- { { icon =, on_tap = }, ... } shown right in the header
    nav = nil,          -- { { key =, icon =, label = }, ... }
    nav_active = nil,
    on_nav = nil,       -- function(key)
    covers_fullscreen = true,
}

function MacaScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.header_h = dp(56)
    self.nav_h = self.nav and dp(64) or 0
    self.scroll = ScrollView:new{
        dimen = Geom:new{
            x = 0, y = self.header_h,
            w = self.dimen.w, h = self.dimen.h - self.header_h - self.nav_h,
        },
        show_parent = self,
        offset = self.initial_offset or 0,
    }
    self[1] = self.scroll
    self.ges_events = {
        ScreenTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Back = { { Device.input.group.Back } } }
    end
    self.header_widgets = {}
    self.nav_widgets = {}
end

function MacaScreen:width()
    return self.dimen.w
end

function MacaScreen:setHeader(title, actions, on_back)
    self.title, self.actions, self.on_back = title, actions, on_back
    self:freeWidgets(self.header_widgets)
    self.header_widgets = {}
end

function MacaScreen:freeWidgets(list)
    for _, widget in pairs(list) do
        widget:free()
    end
end

function MacaScreen:redraw()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function MacaScreen:paintHeader(bb, x, y)
    local w, h = self.dimen.w, self.header_h
    local hw = self.header_widgets
    bb:paintRect(x, y, w, h, Theme.BG)
    local margin = dp(16)
    local icon_size = dp(24)
    local tx = x + margin
    if self.on_back then
        hw.back = hw.back or Theme.icon("back", icon_size)
        hw.back:paintTo(bb, x + margin - dp(4), y + math.floor((h - icon_size) / 2))
        tx = x + margin + icon_size + dp(12)
    end
    local actions = self.actions or {}
    local right = x + w - margin
    self.action_rects = {}
    for i = #actions, 1, -1 do
        local key = "action" .. i
        hw[key] = hw[key] or Theme.icon(actions[i].icon, icon_size)
        right = right - icon_size
        hw[key]:paintTo(bb, right, y + math.floor((h - icon_size) / 2))
        self.action_rects[i] = { x = right - x - dp(10), w = icon_size + dp(20) }
        right = right - dp(20)
    end
    if not hw.title then
        hw.title = Theme.text(self.title or "", self.on_back and 19 or 23,
            { bold = true, max_width = math.max(dp(40), right - tx) })
    end
    hw.title:paintTo(bb, tx, y + math.floor((h - hw.title:getSize().h) / 2))
    if self.scroll.offset > 0 then
        bb:paintRect(x, y + h - 1, w, 1, Theme.LINE)
    end
end

function MacaScreen:paintNav(bb, x, y)
    local w, h = self.dimen.w, self.nav_h
    local nw = self.nav_widgets
    bb:paintRect(x, y, w, h, Theme.BG)
    bb:paintRect(x, y, w, 1, Theme.LINE)
    local item_w = math.floor(w / #self.nav)
    local icon_size = dp(24)
    for i, item in ipairs(self.nav) do
        local active = item.key == self.nav_active
        local cx = x + (i - 1) * item_w + math.floor(item_w / 2)
        if active then
            local pill_w, pill_h = dp(60), dp(30)
            Theme.fillRect(bb, cx - math.floor(pill_w / 2), y + dp(7), pill_w, pill_h,
                Theme.accentTint(0.22), math.floor(pill_h / 2))
        end
        local icon_key = "icon" .. i
        nw[icon_key] = nw[icon_key] or Theme.icon(item.icon, icon_size)
        nw[icon_key]:paintTo(bb, cx - math.floor(icon_size / 2), y + dp(10))
        local label_key = "label" .. i .. (active and "a" or "")
        nw[label_key] = nw[label_key] or Theme.text(item.label, 11.5,
            { bold = active, color = active and Theme.FG or Theme.MUTED })
        local label = nw[label_key]
        label:paintTo(bb, cx - math.floor(label:getSize().w / 2), y + dp(40))
    end
end

function MacaScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    -- body first: rows may overflow its top and bottom edge, the bars cover that
    self.scroll:paintTo(bb, x, y + self.header_h)
    self:paintHeader(bb, x, y)
    if self.nav then
        self:paintNav(bb, x, y + self.dimen.h - self.nav_h)
    end
end

function MacaScreen:onScreenTap(_, ges)
    local tx, ty = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    if ty < self.header_h then
        if self.on_back and tx < dp(64) then
            self.on_back()
            return true
        end
        for i, rect in pairs(self.action_rects or {}) do
            if tx >= rect.x and tx <= rect.x + rect.w then
                self.actions[i].on_tap()
                return true
            end
        end
        -- tapping the title bar scrolls back to the top
        self.scroll:stopFling()
        self.scroll:scrollTo(0)
        return true
    end
    if self.nav and ty >= self.dimen.h - self.nav_h then
        local i = math.floor(tx / (self.dimen.w / #self.nav)) + 1
        local item = self.nav[i]
        if item and self.on_nav then self.on_nav(item.key) end
        return true
    end
    return true
end

function MacaScreen:onBack()
    if self.on_back then
        self.on_back()
    end
    return true
end

function MacaScreen:onSetDimensions()
    -- screen rotated or resized: subclasses rebuild themselves
    if self.onResize then
        UIManager:nextTick(function() self:onResize() end)
    end
end

function MacaScreen:onCloseWidget()
    self:freeWidgets(self.header_widgets)
    self:freeWidgets(self.nav_widgets)
    UIManager:setDirty(nil, "ui")
end

return MacaScreen
