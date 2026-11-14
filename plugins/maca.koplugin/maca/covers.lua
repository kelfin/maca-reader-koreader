--[[--
Scaled book cover bitmaps, kept in a small least-recently-used cache so that
scrolling a grid does not decode and rescale the same covers every frame.

@module koplugin.maca.covers
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BookInfoManager = require("bookinfomanager")
local Device = require("device")
local RenderImage = require("ui/renderimage")
local Theme = require("maca/theme")
local Screen = Device.screen

local Covers = {
    cache = {},       -- key -> { bb =, used = }
    bytes = 0,
    tick = 0,
    max_bytes = 64 * 1024 * 1024,
}

-- Size asked of BookInfoManager when extracting: large enough for the
-- biggest cover we show, so one cached copy serves every screen.
function Covers.specs()
    local short = math.min(Screen:getWidth(), Screen:getHeight())
    local w = math.floor(short * 0.45)
    return { max_cover_w = w, max_cover_h = math.floor(w * 1.5) }
end

function Covers:evict()
    while self.bytes > self.max_bytes do
        local oldest_key, oldest
        for key, item in pairs(self.cache) do
            if not oldest or item.used < oldest.used then
                oldest_key, oldest = key, item
            end
        end
        if not oldest then break end
        self.bytes = self.bytes - oldest.size
        oldest.bb:free()
        self.cache[oldest_key] = nil
    end
end

function Covers:clear()
    for _, item in pairs(self.cache) do
        item.bb:free()
    end
    self.cache, self.bytes = {}, 0
end

--- Forget the cached bitmaps of one book (its cover just got extracted).
function Covers:forget(file)
    for key, item in pairs(self.cache) do
        if item.file == file then
            self.bytes = self.bytes - item.size
            item.bb:free()
            self.cache[key] = nil
        end
    end
end

local function placeholder(entry, w, h)
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Theme.CARD)
    local pad = math.floor(w * 0.1)
    local size = math.max(9, math.floor(w / Theme.dp(1) / 9))
    local title = Theme.textBox(entry.title or "", size, w - 2 * pad, 4,
        { bold = true, bgcolor = Theme.CARD, alignment = "center" })
    local th = title:getSize().h
    title:paintTo(bb, pad, math.floor(h * 0.18))
    title:free()
    if entry.author then
        local author = Theme.textBox(entry.author, size * 0.8, w - 2 * pad, 2,
            { color = Theme.MUTED, bgcolor = Theme.CARD, alignment = "center" })
        author:paintTo(bb, pad, math.floor(h * 0.18) + th + pad)
        author:free()
    end
    bb:paintBorder(0, 0, w, h, 1, Theme.LINE)
    return bb
end

local function render(entry, w, h)
    local info = entry.has_cover and BookInfoManager:getBookInfo(entry.file, true)
    local src = info and info.cover_bb
    if not src then
        return placeholder(entry, w, h)
    end
    local sw, sh = src:getWidth(), src:getHeight()
    local ratio = (sw / sh) / (w / h)
    if ratio > 0.85 and ratio < 1.18 then
        -- close enough to the tile's shape: fill it
        return RenderImage:scaleBlitBuffer(src, w, h, true)
    end
    -- unusual shape: fit inside the tile, centred on a card
    local scale = math.min(w / sw, h / sh)
    local nw, nh = math.max(1, math.floor(sw * scale)), math.max(1, math.floor(sh * scale))
    local scaled = RenderImage:scaleBlitBuffer(src, nw, nh, true)
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Theme.CARD)
    bb:blitFrom(scaled, math.floor((w - nw) / 2), math.floor((h - nh) / 2), 0, 0, nw, nh)
    scaled:free()
    return bb
end

--- Paint the cover of a book entry at (x, y), sized w x h.
function Covers:paint(bb, x, y, w, h, entry)
    local key = entry.file .. "|" .. w .. "x" .. h .. (entry.has_cover and "c" or "p")
    local item = self.cache[key]
    if not item then
        local cover = render(entry, w, h)
        item = { bb = cover, file = entry.file, size = w * h * 4 }
        self.cache[key] = item
        self.bytes = self.bytes + item.size
        self.tick = self.tick + 1
        item.used = self.tick
        self:evict()
    else
        self.tick = self.tick + 1
        item.used = self.tick
    end
    bb:blitFrom(item.bb, x, y, 0, 0, w, h)
    if Screen.night_mode then
        bb:invertRect(x, y, w, h)
    end
end

return Covers
