--[[--
Vertically scrolling list that follows the finger and keeps moving after a
flick. Only the rows on screen are painted, so it stays cheap for long lists.

A row is a table with:
    h      height in pixels
    paint  function(row, bb, x, y, w)
    tap    optional function(row, x, y) with coordinates local to the row
    hold   optional function(row, x, y)
    free   optional function(row)

@module koplugin.maca.scrollview
--]]--

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Theme = require("theme")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local ScrollView = InputContainer:extend{
    dimen = nil,
    rows = nil,
    offset = 0,
    show_parent = nil,
    on_scroll = nil, -- function(offset)
}

local FRAME = 1 / 60
local FRICTION = 0.94      -- velocity kept per frame
local MIN_VELOCITY = 40    -- px/s below which a fling stops

function ScrollView:init()
    self.rows = self.rows or {}
    self.live = {}
    local range = function() return self.dimen end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        Touch = { GestureRange:new{ ges = "touch", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
    }
    self.fling_step = function() self:flingStep() end
    self:layout()
end

function ScrollView:layout()
    local y = 0
    for _, row in ipairs(self.rows) do
        row.y = y
        y = y + row.h
    end
    self.content_h = y
    self:clamp()
end

function ScrollView:maxOffset()
    return math.max(0, self.content_h - self.dimen.h)
end

function ScrollView:clamp()
    self.offset = math.max(0, math.min(self.offset, self:maxOffset()))
end

function ScrollView:setRows(rows, keep_offset)
    self:stopFling()
    self:releaseRows()
    self.rows = rows
    if not keep_offset then self.offset = 0 end
    self:layout()
end

-- Free everything the current rows hold.
function ScrollView:releaseRows()
    for _, row in ipairs(self.rows) do
        if row.free then row:free() end
        if row.destroy then row:destroy() end
    end
    self.live = {}
end

function ScrollView:getSize()
    return self.dimen
end

function ScrollView:redraw()
    UIManager:setDirty(self.show_parent or self, function()
        return "ui", self.dimen
    end)
end

function ScrollView:scrollTo(offset)
    local before = self.offset
    self.offset = offset
    self:clamp()
    if self.offset ~= before then
        if self.on_scroll then self.on_scroll(self.offset) end
        self:redraw()
        return true
    end
    return false
end

function ScrollView:rowAt(y_content)
    -- binary search: rows are sorted by y
    local lo, hi = 1, #self.rows
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local row = self.rows[mid]
        if y_content < row.y then
            hi = mid - 1
        elseif y_content >= row.y + row.h then
            lo = mid + 1
        else
            return row, mid
        end
    end
end

function ScrollView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, Theme.BG)
    local _, first = self:rowAt(self.offset)
    if first then
        for i = first, #self.rows do
            local row = self.rows[i]
            local row_y = row.y - self.offset
            if row_y >= h then break end
            row.w_hint = w
            row:paint(bb, x, y + row_y, w)
            self.live[row] = true
        end
    end
    -- release rows that are now far from the viewport
    for row in pairs(self.live) do
        if row.y + row.h < self.offset - 2 * h or row.y > self.offset + 3 * h then
            if row.free then row:free() end
            self.live[row] = nil
        end
    end
    -- position indicator, only while content is moving
    if self.moving and self.content_h > h then
        local bar_h = math.max(Theme.dp(24), math.floor(h * h / self.content_h))
        local bar_y = math.floor((h - bar_h) * self.offset / self:maxOffset())
        bb:paintRect(x + w - Theme.dp(4), y + bar_y, Theme.dp(3), bar_h, Theme.FAINT)
    end
end

-- Gestures ----------------------------------------------------------------

function ScrollView:localPos(ges)
    local y_content = ges.pos.y - self.dimen.y + self.offset
    local row = self:rowAt(y_content)
    if row then
        return row, ges.pos.x - self.dimen.x, y_content - row.y
    end
end

function ScrollView:onTap(_, ges)
    if self.flinging then
        self:stopFling()
        return true
    end
    local row, x, y = self:localPos(ges)
    if row and row.tap then
        row:tap(x, y)
    end
    return true
end

function ScrollView:onHold(_, ges)
    local row, x, y = self:localPos(ges)
    if row and row.hold then
        row:hold(x, y)
    end
    return true
end

function ScrollView:onTouch(_, ges)
    self:stopFling()
    self.pan_start_offset = nil
    return false
end

function ScrollView:onPan(_, ges)
    if not self.pan_start_offset then
        self.pan_start_offset = self.offset
        self.samples = {}
    end
    self.moving = true
    -- remember recent positions to work out the release velocity
    local samples = self.samples
    samples[#samples + 1] = { t = time.to_s(ges.time or time.now()), y = ges.relative.y }
    if #samples > 6 then table.remove(samples, 1) end
    if not self:scrollTo(self.pan_start_offset - ges.relative.y) then
        self:redraw()
    end
    return true
end

function ScrollView:releaseVelocity()
    local samples = self.samples
    if not samples or #samples < 2 then return 0 end
    local first, last = samples[1], samples[#samples]
    local dt = last.t - first.t
    if dt <= 0.001 then return 0 end
    return -(last.y - first.y) / dt
end

function ScrollView:endPan()
    local velocity = self:releaseVelocity()
    self.pan_start_offset = nil
    self.samples = nil
    if math.abs(velocity) > MIN_VELOCITY * 4 then
        self:fling(velocity)
    else
        self.moving = false
        self:redraw()
    end
end

function ScrollView:onPanRelease(_, ges)
    if ges.from_mousewheel and ges.relative then
        self:scrollTo(self.offset - ges.relative.y * Theme.dp(1))
        return true
    end
    self:endPan()
    return true
end

function ScrollView:onSwipe(_, ges)
    if self.pan_start_offset then
        -- a quick flick: pan events came first, the release arrives as a swipe
        self:endPan()
        return true
    end
    local distance = ges.distance * 3
    if ges.direction == "north" then
        self:fling(distance * 4)
    elseif ges.direction == "south" then
        self:fling(-distance * 4)
    else
        return false -- let the parent use horizontal swipes
    end
    return true
end

function ScrollView:fling(velocity)
    self:stopFling()
    local limit = self.dimen.h * 12
    self.velocity = math.max(-limit, math.min(limit, velocity))
    self.flinging = true
    self.moving = true
    UIManager:scheduleIn(FRAME, self.fling_step)
end

function ScrollView:flingStep()
    if not self.flinging then return end
    local moved = self:scrollTo(self.offset + self.velocity * FRAME)
    self.velocity = self.velocity * FRICTION
    if moved and math.abs(self.velocity) > MIN_VELOCITY then
        UIManager:scheduleIn(FRAME, self.fling_step)
    else
        self.flinging = false
        self.moving = false
        self:redraw()
    end
end

function ScrollView:stopFling()
    if self.flinging then
        UIManager:unschedule(self.fling_step)
        self.flinging = false
        self.moving = false
    end
end

function ScrollView:onCloseWidget()
    self:stopFling()
    self:releaseRows()
end

return ScrollView
