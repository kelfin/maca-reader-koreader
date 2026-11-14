--[[--
Row building blocks for the Maca screens (see scrollview.lua for the row
contract). Rows build their text widgets on first paint and release them
when scrolled far away.

@module koplugin.maca.rows
--]]--

local Covers = require("covers")
local Theme = require("theme")
local dp = Theme.dp

local Rows = {}

Rows.MARGIN = dp(16)
local M = Rows.MARGIN

local function keep(row, widget)
    row.widgets = row.widgets or {}
    table.insert(row.widgets, widget)
    return widget
end

local function release(row)
    if row.widgets then
        for _, widget in ipairs(row.widgets) do
            widget:free()
        end
    end
    row.widgets = nil
    row.built = false
end

Rows.keep = keep

local function new(row)
    row.free = release
    return row
end

local function paintCentered(widget, bb, x, y, h)
    widget:paintTo(bb, x, y + math.floor((h - widget:getSize().h) / 2))
end

function Rows.spacer(h)
    return { h = h, paint = function() end }
end

--- Free-form row: { h =, paint =, tap =, hold = }.
function Rows.custom(row)
    return new(row)
end

--- Section title with an optional action on the right.
function Rows.section(title, action, on_action)
    return new{
        h = dp(48),
        paint = function(row, bb, x, y, w)
            if not row.built then
                row.title = keep(row, Theme.text(title, 18, { bold = true, max_width = w - 2 * M }))
                if action then
                    row.action = keep(row, Theme.text(action, 14, { color = Theme.MUTED }))
                end
                row.built = true
            end
            paintCentered(row.title, bb, x + M, y + dp(6), row.h - dp(6))
            if row.action then
                paintCentered(row.action, bb, x + w - M - row.action:getSize().w, y + dp(6), row.h - dp(6))
            end
        end,
        tap = function(row, tx)
            if on_action and row.action and tx > row.w_hint - M * 2 - row.action:getSize().w then
                on_action()
            end
        end,
        w_hint = 0,
    }
end

--- Plain wrapped text.
function Rows.paragraph(w, str, size, opts)
    opts = opts or {}
    local pad = opts.pad or M
    local box = Theme.textBox(str, size, w - 2 * pad, opts.max_lines,
        { color = opts.color, bold = opts.bold, alignment = opts.alignment, line_height = opts.line_height })
    local row = new{
        h = box:getSize().h + (opts.gap or dp(8)),
        paint = function(row, bb, x, y)
            row.box:paintTo(bb, x + pad, y)
        end,
        tap = opts.on_tap and function() opts.on_tap() end,
    }
    row.box = box
    row.free = function(r) end -- sized at creation; lives as long as the list
    row.destroy = function() box:free() end
    return row
end

--- "Continue reading" card.
-- opts: label, detail (line under the progress bar), on_tap, on_hold
function Rows.hero(w, entry, opts)
    local pad = dp(16)
    local cover_w = dp(104)
    local cover_h = dp(156)
    local card_h = cover_h + 2 * pad
    return new{
        h = card_h + dp(8),
        paint = function(row, bb, x, y)
            local card_x, card_w = x + M, w - 2 * M
            Theme.fillRect(bb, card_x, y, card_w, card_h, Theme.CARD, dp(14))
            Covers:paint(bb, card_x + pad, y + pad, cover_w, cover_h, entry)
            local tx = card_x + pad + cover_w + pad
            local tw = card_w - cover_w - 3 * pad
            if not row.built then
                row.label = keep(row, Theme.text(opts.label, 11.5, { bold = true, color = Theme.MUTED, max_width = tw }))
                row.title = keep(row, Theme.textBox(entry.title or "", 19, tw, 3, { bold = true, bgcolor = Theme.CARD }))
                if entry.author then
                    row.author = keep(row, Theme.text(entry.author, 14.5, { color = Theme.MUTED, max_width = tw }))
                end
                if opts.detail then
                    row.detail = keep(row, Theme.text(opts.detail, 13, { color = Theme.MUTED, max_width = tw }))
                end
                row.built = true
            end
            local ty = y + pad
            row.label:paintTo(bb, tx, ty)
            ty = ty + row.label:getSize().h + dp(6)
            row.title:paintTo(bb, tx, ty)
            ty = ty + row.title:getSize().h + dp(4)
            if row.author then row.author:paintTo(bb, tx, ty) end
            local by = y + card_h - pad
            if row.detail then
                by = by - row.detail:getSize().h
                row.detail:paintTo(bb, tx, by)
                by = by - dp(8)
            end
            Theme.progress(bb, tx, by - dp(6), tw, dp(6), entry.percent)
        end,
        tap = function() if opts.on_tap then opts.on_tap(entry) end end,
        hold = function() if opts.on_hold then opts.on_hold(entry) end end,
    }
end

--- How many tiles of at least `min_tile` fit in `w`, and their exact width.
function Rows.columns(w, min_tile, gap)
    local avail = w - 2 * M
    local n = math.max(2, math.floor((avail + gap) / (min_tile + gap)))
    return n, math.floor((avail - (n - 1) * gap) / n)
end

local function tileIndex(tx, tile_w, gap, count)
    local rel = tx - M
    if rel < 0 then return nil end
    local i = math.floor(rel / (tile_w + gap))
    if rel - i * (tile_w + gap) > tile_w then return nil end
    return i < count and i + 1 or nil
end

--- One row of book covers (no titles), for "recently read" style shelves.
function Rows.shelf(w, entries, opts)
    local gap = dp(12)
    local n, tile_w = Rows.columns(w, opts.min_tile or dp(92), gap)
    local cover_h = math.floor(tile_w * 1.5)
    local count = math.min(n, #entries)
    return new{
        h = cover_h + dp(18),
        paint = function(row, bb, x, y)
            for i = 1, count do
                local entry = entries[i]
                local cx = x + M + (i - 1) * (tile_w + gap)
                Covers:paint(bb, cx, y, tile_w, cover_h, entry)
                if entry.status == "reading" or entry.status == "abandoned" then
                    Theme.progress(bb, cx, y + cover_h + dp(6), tile_w, dp(4), entry.percent)
                end
            end
        end,
        tap = function(row, tx, ty)
            local i = ty <= cover_h and tileIndex(tx, tile_w, gap, count)
            if i and opts.on_tap then opts.on_tap(entries[i]) end
        end,
        hold = function(row, tx, ty)
            local i = ty <= cover_h and tileIndex(tx, tile_w, gap, count)
            if i and opts.on_hold then opts.on_hold(entries[i]) end
        end,
    }
end

local status_marks = { complete = "check", abandoned = "clock" }

--- One row of the library grid: covers with title and author underneath.
function Rows.grid(w, entries, n, tile_w, gap, opts)
    local cover_h = math.floor(tile_w * 1.5)
    local text_h = dp(58)
    return new{
        h = cover_h + text_h + dp(14),
        paint = function(row, bb, x, y)
            if not row.built then
                row.titles, row.authors = {}, {}
                for i, entry in ipairs(entries) do
                    row.titles[i] = keep(row, Theme.textBox(entry.title or "", 13, tile_w, 2, { bold = true }))
                    if entry.author then
                        row.authors[i] = keep(row, Theme.text(entry.author, 12, { color = Theme.MUTED, max_width = tile_w }))
                    end
                end
                row.built = true
            end
            for i, entry in ipairs(entries) do
                local cx = x + M + (i - 1) * (tile_w + gap)
                Covers:paint(bb, cx, y, tile_w, cover_h, entry)
                local ty = y + cover_h + dp(6)
                if entry.status == "reading" or entry.status == "abandoned" then
                    Theme.progress(bb, cx, ty, tile_w, dp(4), entry.percent)
                    ty = ty + dp(9)
                elseif entry.status == "complete" then
                    Theme.fillRect(bb, cx, ty, tile_w, dp(4), Theme.accent(), dp(2))
                    ty = ty + dp(9)
                end
                row.titles[i]:paintTo(bb, cx, ty)
                if row.authors[i] then
                    row.authors[i]:paintTo(bb, cx, ty + row.titles[i]:getSize().h + dp(1))
                end
            end
        end,
        tap = function(row, tx)
            local i = tileIndex(tx, tile_w, gap, #entries)
            if i and opts.on_tap then opts.on_tap(entries[i]) end
        end,
        hold = function(row, tx)
            local i = tileIndex(tx, tile_w, gap, #entries)
            if i and opts.on_hold then opts.on_hold(entries[i]) end
        end,
    }
end

--- One book as a list line: small cover, title, author, progress.
function Rows.book(w, entry, opts)
    local cover_w, cover_h = dp(52), dp(78)
    local pad = dp(10)
    return new{
        h = cover_h + 2 * pad,
        paint = function(row, bb, x, y)
            local tx = x + M + cover_w + dp(14)
            local tw = w - (tx - x) - M
            if not row.built then
                row.title = keep(row, Theme.textBox(entry.title or "", 15.5, tw, 2, { bold = true }))
                if entry.author then
                    row.author = keep(row, Theme.text(entry.author, 13.5, { color = Theme.MUTED, max_width = tw }))
                end
                row.status = keep(row, Theme.text(opts.status_text(entry), 12.5, { color = Theme.MUTED, max_width = tw }))
                row.built = true
            end
            Covers:paint(bb, x + M, y + pad, cover_w, cover_h, entry)
            local ty = y + pad
            row.title:paintTo(bb, tx, ty)
            ty = ty + row.title:getSize().h + dp(2)
            if row.author then row.author:paintTo(bb, tx, ty) end
            local by = y + pad + cover_h - row.status:getSize().h
            row.status:paintTo(bb, tx, by)
            if entry.status == "reading" or entry.status == "abandoned" then
                Theme.progress(bb, tx, by - dp(9), math.min(tw, dp(220)), dp(4), entry.percent)
            end
            bb:paintRect(tx, y + row.h - 1, w - (tx - x), 1, Theme.LINE)
        end,
        tap = function() if opts.on_tap then opts.on_tap(entry) end end,
        hold = function() if opts.on_hold then opts.on_hold(entry) end end,
    }
end

--- Wrapping row of selectable chips. items: { { key, label }, ... }
function Rows.chips(w, items, active, on_select)
    local chip_h, gap, pad = dp(34), dp(8), dp(14)
    local widgets, rects = {}, {}
    local cx, cy = M, 0
    for i, item in ipairs(items) do
        local is_active = item[1] == active
        local text = Theme.text(item[2], 13.5, { bold = is_active, color = is_active and Theme.gray(255) or Theme.FG })
        local cw = text:getSize().w + 2 * pad
        if cx + cw > w - M and cx > M then
            cx, cy = M, cy + chip_h + gap
        end
        widgets[i] = text
        rects[i] = { x = cx, y = cy, w = cw, active = is_active, key = item[1] }
        cx = cx + cw + gap
    end
    return {
        h = cy + chip_h + dp(10),
        paint = function(row, bb, x, y)
            for i, rect in ipairs(rects) do
                Theme.fillRect(bb, x + rect.x, y + rect.y, rect.w, chip_h,
                    rect.active and Theme.accent() or Theme.CARD, math.floor(chip_h / 2))
                paintCentered(widgets[i], bb, x + rect.x + pad, y + rect.y, chip_h)
            end
        end,
        tap = function(row, tx, ty)
            for _, rect in ipairs(rects) do
                if tx >= rect.x and tx <= rect.x + rect.w and ty >= rect.y and ty <= rect.y + chip_h then
                    on_select(rect.key)
                    return
                end
            end
        end,
        destroy = function()
            for _, widget in ipairs(widgets) do widget:free() end
        end,
    }
end

--- Summary text on the left, icon+label buttons on the right.
-- buttons: { { icon =, label =, on_tap = }, ... }
function Rows.toolbar(w, summary, buttons)
    local icon_size = dp(20)
    return new{
        h = dp(44),
        paint = function(row, bb, x, y)
            if not row.built then
                row.summary = keep(row, Theme.text(summary, 13.5, { color = Theme.MUTED }))
                row.items = {}
                local bx = w - M
                for i = #buttons, 1, -1 do
                    local button = buttons[i]
                    local label = button.label and keep(row, Theme.text(button.label, 13.5)) or nil
                    local bw = icon_size + (label and label:getSize().w + dp(6) or 0)
                    bx = bx - bw
                    row.items[i] = { x = bx, w = bw, label = label, icon = keep(row, Theme.icon(button.icon, icon_size)) }
                    bx = bx - dp(18)
                end
                row.built = true
            end
            paintCentered(row.summary, bb, x + M, y, row.h)
            for _, item in ipairs(row.items) do
                paintCentered(item.icon, bb, x + item.x, y, row.h)
                if item.label then
                    paintCentered(item.label, bb, x + item.x + icon_size + dp(6), y, row.h)
                end
            end
        end,
        tap = function(row, tx)
            if not row.items then return end
            for i, item in ipairs(row.items) do
                if tx >= item.x - dp(9) and tx <= item.x + item.w + dp(9) then
                    buttons[i].on_tap()
                    return
                end
            end
        end,
    }
end

--- Settings-style line: icon, label, optional value, chevron.
function Rows.item(w, icon, label, value, on_tap, opts)
    opts = opts or {}
    local icon_size = dp(24)
    return new{
        h = opts.sub and dp(68) or dp(56),
        paint = function(row, bb, x, y)
            if not row.built then
                local lx = M + (icon and icon_size + dp(18) or 0)
                row.lx = lx
                if icon then row.icon = keep(row, Theme.icon(icon, icon_size)) end
                if on_tap and not opts.no_chevron then
                    row.chevron = keep(row, Theme.icon("forward", dp(18), true))
                end
                local right = M + (row.chevron and dp(22) or 0)
                if value then
                    row.value = keep(row, Theme.text(value, 14, { color = Theme.MUTED, max_width = math.floor(w * 0.45) }))
                    right = right + row.value:getSize().w + dp(8)
                end
                row.label = keep(row, Theme.text(label, 16, { max_width = w - lx - right }))
                if opts.sub then
                    row.sub = keep(row, Theme.text(opts.sub, 13, { color = Theme.MUTED, max_width = w - lx - right }))
                end
                row.built = true
            end
            if row.icon then paintCentered(row.icon, bb, x + M, y, row.h) end
            if row.sub then
                local lh, sh = row.label:getSize().h, row.sub:getSize().h
                local ty = y + math.floor((row.h - lh - sh - dp(2)) / 2)
                row.label:paintTo(bb, x + row.lx, ty)
                row.sub:paintTo(bb, x + row.lx, ty + lh + dp(2))
            else
                paintCentered(row.label, bb, x + row.lx, y, row.h)
            end
            local rx = x + w - M
            if row.chevron then
                rx = rx - dp(18)
                paintCentered(row.chevron, bb, rx, y, row.h)
                rx = rx - dp(4)
            end
            if row.value then
                paintCentered(row.value, bb, rx - row.value:getSize().w, y, row.h)
            end
            if not opts.no_line then
                bb:paintRect(x + row.lx, y + row.h - 1, w - row.lx, 1, Theme.LINE)
            end
        end,
        tap = function() if on_tap then on_tap() end end,
    }
end

--- Centred message with an optional button, for empty states.
function Rows.message(w, title, body, button, on_tap)
    local tw = math.min(w - 4 * M, dp(420))
    local button_h = dp(44)
    return new{
        h = dp(250),
        paint = function(row, bb, x, y)
            if not row.built then
                row.title = keep(row, Theme.textBox(title, 19, tw, 2, { bold = true, alignment = "center" }))
                row.body = keep(row, Theme.textBox(body, 14.5, tw, 5, { color = Theme.MUTED, alignment = "center" }))
                if button then
                    row.button = keep(row, Theme.text(button, 15, { bold = true, color = Theme.gray(255) }))
                end
                row.built = true
            end
            local tx = x + math.floor((w - tw) / 2)
            local ty = y + dp(40)
            row.title:paintTo(bb, tx, ty)
            ty = ty + row.title:getSize().h + dp(8)
            row.body:paintTo(bb, tx, ty)
            ty = ty + row.body:getSize().h + dp(20)
            if row.button then
                local bw = row.button:getSize().w + dp(48)
                local bx = x + math.floor((w - bw) / 2)
                Theme.fillRect(bb, bx, ty, bw, button_h, Theme.accent(), math.floor(button_h / 2))
                paintCentered(row.button, bb, bx + dp(24), ty, button_h)
                row.button_rect = { x = bx - x, y = ty - y, w = bw }
            end
        end,
        tap = function(row, tx, ty)
            local rect = row.button_rect
            if rect and on_tap and tx >= rect.x and tx <= rect.x + rect.w
                    and ty >= rect.y - dp(8) and ty <= rect.y + button_h + dp(8) then
                on_tap()
            end
        end,
    }
end

--- Row of buttons sharing the width. buttons: { { label =, primary =, on_tap = }, ... }
function Rows.buttons(w, buttons, opts)
    opts = opts or {}
    local button_h = opts.height or dp(46)
    local gap = dp(10)
    local bw = math.floor((w - 2 * M - (#buttons - 1) * gap) / #buttons)
    return new{
        h = button_h + dp(12),
        paint = function(row, bb, x, y)
            if not row.built then
                row.labels = {}
                for i, button in ipairs(buttons) do
                    row.labels[i] = keep(row, Theme.text(button.label, 15, {
                        bold = true, max_width = bw - dp(16),
                        color = button.primary and Theme.gray(255) or Theme.FG,
                    }))
                end
                row.built = true
            end
            for i, button in ipairs(buttons) do
                local bx = x + M + (i - 1) * (bw + gap)
                Theme.fillRect(bb, bx, y, bw, button_h, button.primary and Theme.accent() or Theme.CARD,
                    math.floor(button_h / 2))
                local label = row.labels[i]
                paintCentered(label, bb, bx + math.floor((bw - label:getSize().w) / 2), y, button_h)
            end
        end,
        tap = function(row, tx, ty)
            if ty > button_h then return end
            local i = tileIndex(tx, bw, gap, #buttons)
            if i and buttons[i].on_tap then buttons[i].on_tap() end
        end,
    }
end

--- Two rows side by side (for wide screens). Children are built for half width.
function Rows.split(w, build_left, build_right)
    local half = math.floor(w / 2)
    local left, right = build_left(half), build_right(w - half)
    local function side(tx)
        if tx < half then return left, tx end
        return right, tx - half
    end
    return {
        h = math.max(left.h, right.h),
        paint = function(row, bb, x, y)
            left:paint(bb, x, y, half)
            right:paint(bb, x + half, y, w - half)
        end,
        tap = function(row, tx, ty)
            local child, cx = side(tx)
            if child.tap and ty <= child.h then child:tap(cx, ty) end
        end,
        hold = function(row, tx, ty)
            local child, cx = side(tx)
            if child.hold and ty <= child.h then child:hold(cx, ty) end
        end,
        free = function()
            if left.free then left:free() end
            if right.free then right:free() end
        end,
        destroy = function()
            if left.destroy then left:destroy() end
            if right.destroy then right:destroy() end
        end,
    }
end

return Rows
