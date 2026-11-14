--[[--
Sizes, fonts, colours and small drawing helpers shared by the Maca screens.

Everything is sized in density-independent pixels (dp), so a tablet shows
more content rather than a blown-up phone layout.

@module koplugin.maca.theme
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen

local Theme = {}

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/maca/[^/]*$") or "plugins/maca.koplugin"

function Theme.dp(n)
    return math.floor(n * Screen:getDPI() / 160 + 0.5)
end
local dp = Theme.dp

--- Font face at a size given in dp.
function Theme.face(size, name)
    -- Font:getFace() scales by screen size; undo that to get a dp-based size.
    local per_unit = Screen:scaleBySize(1000) / 1000
    return Font:getFace(name or "cfont", dp(size) / per_unit)
end

-- Greys work unchanged in night mode (the whole screen is inverted).
Theme.BG = Blitbuffer.COLOR_WHITE
Theme.FG = Blitbuffer.COLOR_BLACK
Theme.MUTED = Blitbuffer.Color8(0x6A)
Theme.FAINT = Blitbuffer.Color8(0x9A)
Theme.LINE = Blitbuffer.Color8(0xE2)
Theme.CARD = Blitbuffer.Color8(0xF2)
Theme.TRACK = Blitbuffer.Color8(0xDC)

local ACCENT = { 0x1E, 0x7B, 0x5E }

--- Colour that shows as (r, g, b) on screen, night mode included.
function Theme.rgb(r, g, b)
    if Screen.night_mode then
        return Blitbuffer.ColorRGB32(255 - r, 255 - g, 255 - b, 0xFF)
    end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

--- Grey level that shows as `v` on screen even in night mode.
function Theme.gray(v)
    if Screen.night_mode then v = 255 - v end
    return Blitbuffer.Color8(v)
end

function Theme.accent()
    return Theme.rgb(ACCENT[1], ACCENT[2], ACCENT[3])
end

--- Accent mixed with the background; `strength` 0 (background) to 1 (accent).
function Theme.accentTint(strength)
    if Screen.night_mode then
        -- mix towards black, then pre-invert so it survives the night-mode inversion
        local function mix(c) return 255 - math.floor(c * strength + 0.5) end
        return Blitbuffer.ColorRGB32(mix(ACCENT[1]), mix(ACCENT[2]), mix(ACCENT[3]), 0xFF)
    end
    local function mix(c) return math.floor(255 - (255 - c) * strength + 0.5) end
    return Blitbuffer.ColorRGB32(mix(ACCENT[1]), mix(ACCENT[2]), mix(ACCENT[3]), 0xFF)
end

--- (r, g, b) mixed with the background; strength 0 (background) to 1 (the colour).
function Theme.mix(r, g, b, strength)
    if Screen.night_mode then
        local function mix(c) return 255 - math.floor(c * strength * 0.6 + 0.5) end
        return Blitbuffer.ColorRGB32(mix(r), mix(g), mix(b), 0xFF)
    end
    local function mix(c) return math.floor(255 - (255 - c) * strength + 0.5) end
    return Blitbuffer.ColorRGB32(mix(r), mix(g), mix(b), 0xFF)
end

function Theme.fillRect(bb, x, y, w, h, color, radius)
    if Blitbuffer.isColor8(color) then
        if radius and radius > 0 then
            bb:paintRoundedRect(x, y, w, h, color, radius)
        else
            bb:paintRect(x, y, w, h, color)
        end
    else
        if radius and radius > 0 then
            bb:paintRoundedRectRGB32(x, y, w, h, color, radius)
        else
            bb:paintRectRGB32(x, y, w, h, color)
        end
    end
end

--- Single-line text widget.
function Theme.text(str, size, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = Theme.face(size, opts.font),
        bold = opts.bold,
        fgcolor = opts.color or Theme.FG,
        max_width = opts.max_width,
        truncate_with_ellipsis = true,
    }
end

--- Multi-line text widget limited to `max_lines`.
function Theme.textBox(str, size, width, max_lines, opts)
    opts = opts or {}
    local face = Theme.face(size, opts.font)
    local box = TextBoxWidget:new{
        text = str,
        face = face,
        width = width,
        bold = opts.bold,
        fgcolor = opts.color or Theme.FG,
        bgcolor = opts.bgcolor or Theme.BG,
        alignment = opts.alignment or "left",
        line_height = opts.line_height,
    }
    if max_lines then
        local line_h = box:getLineHeight()
        if box:getSize().h > line_h * max_lines then
            box:free()
            box = TextBoxWidget:new{
                text = str,
                face = face,
                width = width,
                height = line_h * max_lines,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                bold = opts.bold,
                fgcolor = opts.color or Theme.FG,
                bgcolor = opts.bgcolor or Theme.BG,
                alignment = opts.alignment or "left",
                line_height = opts.line_height,
            }
        end
    end
    return box
end

--- Word-wrapped text with a transparent background (TextBoxWidget is opaque).
-- Returns an object with paintTo(bb, x, y), getSize() and free().
function Theme.wrapped(str, size, width, max_lines, opts)
    opts = opts or {}
    local RenderText = require("ui/rendertext")
    local face = Theme.face(size, opts.font)
    local function measure(text)
        return RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, face, text, true, opts.bold).x
    end
    local lines, line = {}, nil
    for word in tostring(str or ""):gmatch("%S+") do
        local candidate = line and (line .. " " .. word) or word
        if line and measure(candidate) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line then lines[#lines + 1] = line end
    max_lines = max_lines or #lines
    if #lines > max_lines then
        -- keep what fits; the last line carries the rest and is cut with an ellipsis
        lines[max_lines] = table.concat(lines, " ", max_lines)
        for i = #lines, max_lines + 1, -1 do lines[i] = nil end
    end
    local widgets, height, line_h = {}, 0, 0
    for i, text in ipairs(lines) do
        widgets[i] = Theme.text(text, size, { bold = opts.bold, color = opts.color, font = opts.font, max_width = width })
        line_h = widgets[i]:getSize().h
        height = height + line_h
    end
    return {
        paintTo = function(_, bb, x, y)
            for i, widget in ipairs(widgets) do
                widget:paintTo(bb, x, y + (i - 1) * line_h)
            end
        end,
        getSize = function() return { w = width, h = height } end,
        free = function()
            for _, widget in ipairs(widgets) do widget:free() end
        end,
    }
end

--- Line icon from the plugin's icons folder, `size` in pixels.
function Theme.icon(name, size, dim)
    return ImageWidget:new{
        file = plugin_dir .. "/icons/" .. name .. ".svg",
        width = size,
        height = size,
        alpha = true,
        -- dimming lightens a rectangle, which shows as a box in night mode
        dim = dim and not Screen.night_mode,
        original_in_nightmode = false,
    }
end

--- Horizontal progress bar; `fraction` 0..1.
function Theme.progress(bb, x, y, w, h, fraction, track)
    local r = math.floor(h / 2)
    Theme.fillRect(bb, x, y, w, h, track or Theme.TRACK, r)
    fraction = math.max(0, math.min(1, fraction or 0))
    if fraction > 0 then
        local fw = math.max(h, math.floor(w * fraction + 0.5))
        Theme.fillRect(bb, x, y, fw, h, Theme.accent(), r)
    end
end

--- Progress ring rendered into its own bitmap (caller frees it).
function Theme.ringBitmap(size, thickness, fraction, bg)
    local bb = Blitbuffer.new(size, size, Screen.bb:getType())
    bb:fill(bg or Theme.BG)
    local r = (size - thickness) / 2
    local c = size / 2
    local half = math.floor(thickness / 2)
    local steps = math.ceil(2 * math.pi * r / math.max(1, thickness / 4))
    local function dot(i, color)
        local a = 2 * math.pi * i / steps
        Theme.fillRect(bb, math.floor(c + r * math.sin(a) - thickness / 2 + 0.5),
            math.floor(c - r * math.cos(a) - thickness / 2 + 0.5), thickness, thickness, color, half)
    end
    for i = 0, steps - 1 do dot(i, Theme.TRACK) end
    fraction = math.max(0, math.min(1, fraction or 0))
    if fraction > 0 then
        local accent = Theme.accent()
        for i = 0, math.floor(steps * fraction + 0.5) do dot(i, accent) end
    end
    return bb
end

--- Minutes as "45 min" or "2 h 05 min".
function Theme.duration(seconds)
    local _ = require("gettext")
    local T = require("ffi/util").template
    local minutes = math.floor((seconds or 0) / 60 + 0.5)
    if minutes < 60 then
        return T(_("%1 min"), minutes)
    end
    return T(_("%1 h %2 min"), math.floor(minutes / 60), string.format("%02d", minutes % 60))
end

return Theme
