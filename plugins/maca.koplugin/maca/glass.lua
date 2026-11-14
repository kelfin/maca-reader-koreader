--[[--
Frosted-glass panels: a blurred, lightened copy of whatever is already
painted behind a floating bar or sheet.

There is no GPU here, so the blur is a cheap trick: shrink the area to a
handful of pixels and stretch it back with smooth scaling.

@module koplugin.maca.glass
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Theme = require("maca/theme")

local Glass = {}

local SHRINK = 14

function Glass.enabled()
    return G_reader_settings:nilOrTrue("maca_glass")
end

--- Copy `src` to (x, y) on `dst`, cutting the corners to radius `r`.
function Glass.blitRounded(dst, src, x, y, w, h, r)
    r = math.max(0, math.min(r or 0, math.floor(h / 2), math.floor(w / 2)))
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = math.ceil(r - math.sqrt(r * r - dy * dy))
        local span = w - 2 * inset
        if span > 0 then
            dst:blitFrom(src, x + inset, y + i, inset, i, span, 1)
            dst:blitFrom(src, x + inset, y + h - 1 - i, inset, h - 1 - i, span, 1)
        end
    end
    if h - 2 * r > 0 then
        dst:blitFrom(src, x, y + r, 0, r, w, h - 2 * r)
    end
end

--- Paint a glass panel over what `bb` already shows in the given area.
-- opts.strength: how milky the glass is, 0 (clear) to 1 (opaque); default 0.6
-- opts.border: false to leave out the hairline edge
function Glass.panel(bb, x, y, w, h, r, opts)
    opts = opts or {}
    if w <= 0 or h <= 0 then return end
    if not Glass.enabled() then
        Theme.fillRect(bb, x, y, w, h, Theme.BG, r)
    else
        local crop = Blitbuffer.new(w, h, bb:getType())
        crop:fill(Theme.BG)
        crop:blitFrom(bb, 0, 0, x, y, w, h)
        local small = RenderImage:scaleBlitBuffer(crop,
            math.max(2, math.floor(w / SHRINK)), math.max(2, math.floor(h / SHRINK)))
        local blurred = RenderImage:scaleBlitBuffer(small, w, h)
        -- white veil; in night mode the screen is inverted, so this reads as dark glass
        blurred:lightenRect(0, 0, w, h, opts.strength or 0.6)
        Glass.blitRounded(bb, blurred, x, y, w, h, r)
        blurred:free()
    end
    if opts.border ~= false then
        bb:paintBorder(x, y, w, h, 1, Theme.LINE, r and r > 0 and r or nil)
    end
end

return Glass
