--[[--
Reading dashboard: the "today" card on the home tab and the Stats tab.

@module koplugin.maca.statsview
--]]--

local Library = require("maca/library")
local Rows = require("maca/rows")
local Stats = require("maca/stats")
local Theme = require("maca/theme")
local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template
local dp = Theme.dp
local keep = Rows.keep
local M = Rows.MARGIN

local StatsView = {}

local function weekdayLetter(ts)
    local name = datetime.shortDayOfWeekToLongTranslation
        and datetime.shortDayOfWeekTranslation[os.date("%a", ts)] or os.date("%a", ts)
    return (name or ""):match("[%z\1-\127\194-\244][\128-\191]*") or ""
end

-- Bars sharing a baseline. values: array of numbers; labels optional.
local function paintBars(bb, x, y, w, h, values, opts)
    opts = opts or {}
    local n = #values
    local gap = opts.gap or dp(6)
    local bar_w = math.floor((w - (n - 1) * gap) / n)
    local max = opts.max or 0
    for _, v in ipairs(values) do
        if v > max then max = v end
    end
    for i, v in ipairs(values) do
        local bx = x + (i - 1) * (bar_w + gap)
        local bh = max > 0 and math.floor(h * v / max + 0.5) or 0
        local radius = math.min(dp(4), math.floor(bar_w / 2))
        if bh < dp(3) then
            Theme.fillRect(bb, bx, y + h - dp(3), bar_w, dp(3), Theme.TRACK, 0)
        else
            local color = (opts.highlight == i or not opts.highlight) and Theme.accent() or Theme.accentTint(0.45)
            Theme.fillRect(bb, bx, y + h - bh, bar_w, bh, color, math.min(radius, math.floor(bh / 2)))
        end
    end
    return bar_w, gap
end

--- Card summarising today: time read against the goal, streak, last 7 days.
function StatsView.todayCard(home, w, on_tap)
    local goal = home:goalSeconds()
    local overview = Stats:overview(goal)
    local pad = dp(16)
    local card_h = dp(188)
    local ring_size = dp(64)
    return Rows.custom{
        h = card_h + dp(8),
        paint = function(row, bb, x, y)
            local card_x, card_w = x + M, w - 2 * M
            Theme.fillRect(bb, card_x, y, card_w, card_h, Theme.CARD, dp(14))
            local tw = card_w - 2 * pad - ring_size - dp(8)
            if not row.built then
                local today = overview.today
                row.label = keep(row, Theme.text(_("TODAY"), 11.5, { bold = true, color = Theme.MUTED }))
                row.value = keep(row, Theme.text(Theme.duration(today.seconds), 28, { bold = true, max_width = tw }))
                local sub
                if today.seconds >= goal then
                    sub = T(_("Goal of %1 reached"), Theme.duration(goal))
                else
                    sub = T(_("%1 to reach your goal"), Theme.duration(goal - today.seconds))
                end
                row.sub = keep(row, Theme.text(sub, 13, { color = Theme.MUTED, max_width = tw }))
                local streak = overview.streak
                row.flame = keep(row, Theme.icon("flame", dp(18), streak == 0))
                row.streak = keep(row, Theme.text(streak > 0
                    and T(N_("%1-day streak", "%1-day streak", streak), streak) or _("No streak yet"),
                    13, { bold = streak > 0, color = streak > 0 and Theme.FG or Theme.MUTED }))
                row.days = {}
                for i, day in ipairs(overview.week) do
                    row.days[i] = keep(row, Theme.text(weekdayLetter(day.ts), 11, { color = Theme.MUTED }))
                end
                row.ring = Theme.ringBitmap(ring_size, dp(7), today.seconds / goal, Theme.CARD)
                row.built = true
            end
            local tx, ty = card_x + pad, y + pad
            row.label:paintTo(bb, tx, ty)
            ty = ty + row.label:getSize().h + dp(4)
            row.value:paintTo(bb, tx, ty)
            ty = ty + row.value:getSize().h
            row.sub:paintTo(bb, tx, ty)
            bb:blitFrom(row.ring, card_x + card_w - pad - ring_size, y + pad, 0, 0, ring_size, ring_size)
            -- last seven days, today highlighted, with the streak beside it
            local letters_h = row.days[1]:getSize().h
            local bars_h = dp(36)
            local bars_y = y + card_h - pad - letters_h - dp(4) - bars_h
            local bars_w = math.min(dp(190), math.floor(card_w * 0.5))
            local values = {}
            for i, day in ipairs(overview.week) do values[i] = day.seconds end
            local bar_w, gap = paintBars(bb, tx, bars_y, bars_w, bars_h, values, { highlight = 7, max = goal })
            for i, widget in ipairs(row.days) do
                widget:paintTo(bb, tx + (i - 1) * (bar_w + gap) + math.floor((bar_w - widget:getSize().w) / 2),
                    bars_y + bars_h + dp(4))
            end
            local sw = row.streak:getSize().w
            local sx = card_x + card_w - pad - sw
            local sy = y + card_h - pad - row.streak:getSize().h
            row.streak:paintTo(bb, sx, sy)
            row.flame:paintTo(bb, sx - dp(22), sy - dp(1))
        end,
        tap = function() if on_tap then on_tap() end end,
        free = function(row)
            if row.ring then row.ring:free() row.ring = nil end
            if row.widgets then
                for _, widget in ipairs(row.widgets) do widget:free() end
            end
            row.widgets, row.built = nil, false
        end,
    }
end

-- A line of equal cards, each with a big value and a caption.
local function tiles(w, items)
    local gap = dp(10)
    local n = #items
    local tile_w = math.floor((w - 2 * M - (n - 1) * gap) / n)
    local tile_h = dp(78)
    return Rows.custom{
        h = tile_h + gap,
        paint = function(row, bb, x, y)
            if not row.built then
                row.values, row.captions = {}, {}
                for i, item in ipairs(items) do
                    row.values[i] = keep(row, Theme.text(item[1], 20, { bold = true, max_width = tile_w - dp(24) }))
                    row.captions[i] = keep(row, Theme.text(item[2], 12.5, { color = Theme.MUTED, max_width = tile_w - dp(24) }))
                end
                row.built = true
            end
            for i = 1, n do
                local tx = x + M + (i - 1) * (tile_w + gap)
                Theme.fillRect(bb, tx, y, tile_w, tile_h, Theme.CARD, dp(12))
                row.values[i]:paintTo(bb, tx + dp(12), y + dp(14))
                row.captions[i]:paintTo(bb, tx + dp(12), y + dp(14) + row.values[i]:getSize().h + dp(2))
            end
        end,
    }
end

-- Calendar heat map of the last weeks, one column per week.
local function heatmap(w, daily, goal)
    local cell, gap = dp(15), dp(4)
    local avail = w - 2 * M
    local weeks = math.min(26, math.floor((avail + gap) / (cell + gap)))
    local today = Stats.dayStart() + 12 * 3600
    -- column of the current week ends at today; weeks start on Monday
    local weekday = (tonumber(os.date("%w", today)) + 6) % 7 -- 0 = Monday
    local total_w = weeks * (cell + gap) - gap
    return Rows.custom{
        h = 7 * (cell + gap) + dp(8),
        paint = function(row, bb, x, y)
            local ox = x + M + math.floor((avail - total_w) / 2)
            for col = 0, weeks - 1 do
                for line = 0, 6 do
                    local days_ago = (weeks - 1 - col) * 7 + (weekday - line)
                    if days_ago >= 0 then
                        local seconds = (daily[Stats.dayKey(today - days_ago * 86400)] or {}).seconds or 0
                        local color = Theme.CARD
                        if seconds >= goal then color = Theme.accent()
                        elseif seconds >= goal * 0.5 then color = Theme.accentTint(0.65)
                        elseif seconds >= 60 then color = Theme.accentTint(0.32) end
                        Theme.fillRect(bb, ox + col * (cell + gap), y + line * (cell + gap), cell, cell, color, dp(3))
                    end
                end
            end
        end,
    }
end

-- Bar chart with a caption under selected bars.
local function chart(w, values, labels, opts)
    opts = opts or {}
    local bars_h = opts.height or dp(96)
    return Rows.custom{
        h = bars_h + dp(34),
        paint = function(row, bb, x, y)
            if not row.built then
                row.labels = {}
                for i, label in pairs(labels) do
                    row.labels[i] = keep(row, Theme.text(label, 11, { color = Theme.MUTED }))
                end
                row.built = true
            end
            local bar_w, gap = paintBars(bb, x + M, y, w - 2 * M, bars_h, values,
                { gap = opts.gap, highlight = opts.highlight })
            for i, widget in pairs(row.labels) do
                local lx = x + M + (i - 1) * (bar_w + gap) + math.floor((bar_w - widget:getSize().w) / 2)
                widget:paintTo(bb, math.max(x + M, lx), y + bars_h + dp(6))
            end
        end,
    }
end

-- Title on the left, value on the right, and a proportional bar beneath.
local function ranked(w, title, value, fraction)
    return Rows.custom{
        h = dp(50),
        paint = function(row, bb, x, y)
            if not row.built then
                row.value = keep(row, Theme.text(value, 13.5, { color = Theme.MUTED }))
                row.title = keep(row, Theme.text(title, 14.5, { max_width = w - 2 * M - row.value:getSize().w - dp(12) }))
                row.built = true
            end
            row.title:paintTo(bb, x + M, y + dp(4))
            row.value:paintTo(bb, x + w - M - row.value:getSize().w, y + dp(5))
            Theme.progress(bb, x + M, y + dp(30), w - 2 * M, dp(5), fraction, Theme.CARD)
        end,
    }
end

local function hourLabel(hour)
    return string.format("%02d", hour)
end

function StatsView.rows(home, w)
    local rows = {}
    local goal = home:goalSeconds()
    if not Stats:available() then
        rows[#rows + 1] = Rows.message(w, _("No reading recorded yet"),
            _("Open a book and read for a while. Your time, pages and streak will show up here."))
        return rows
    end
    local overview = Stats:overview(goal)
    local totals = Stats:totals()
    local counts = Library:counts()
    local wide = w >= dp(700)

    rows[#rows + 1] = Rows.spacer(dp(4))
    local today = function(cw) return StatsView.todayCard(home, cw, function() home:setGoal() end) end
    local week_values, week_labels = {}, {}
    for i, day in ipairs(overview.week) do
        week_values[i] = day.seconds
        week_labels[i] = weekdayLetter(day.ts)
    end
    if wide then
        rows[#rows + 1] = Rows.split(w, today, function(cw)
            return tiles(cw, {
                { Theme.duration(overview.week_seconds), _("This week") },
                { tostring(overview.week_pages), _("Pages this week") },
            })
        end)
    else
        rows[#rows + 1] = today(w)
    end

    rows[#rows + 1] = Rows.section(_("This week"), Theme.duration(overview.week_seconds))
    rows[#rows + 1] = chart(w, week_values, week_labels, { highlight = 7, gap = dp(14) })

    rows[#rows + 1] = Rows.section(_("Overview"))
    local row_a = {
        { Theme.duration(overview.month_seconds), _("Last 30 days") },
        { tostring(overview.month_pages), _("Pages, last 30 days") },
    }
    local row_b = {
        { T(N_("%1 day", "%1 days", overview.best_streak), overview.best_streak), _("Longest streak") },
        { tostring(counts.complete or 0), _("Books finished") },
    }
    local row_c = {
        { Theme.duration(totals.seconds), _("Total reading time") },
        { tostring(totals.days), _("Days with reading") },
    }
    if wide then
        rows[#rows + 1] = tiles(w, { row_a[1], row_a[2], row_b[1], row_b[2] })
        rows[#rows + 1] = tiles(w, { row_c[1], row_c[2],
            { tostring(totals.pages), _("Pages read") }, { tostring(totals.books), _("Books opened") } })
    else
        rows[#rows + 1] = tiles(w, row_a)
        rows[#rows + 1] = tiles(w, row_b)
        rows[#rows + 1] = tiles(w, row_c)
    end

    rows[#rows + 1] = Rows.section(_("Reading days"))
    rows[#rows + 1] = heatmap(w, overview.daily, goal)

    rows[#rows + 1] = Rows.section(_("When you read"), _("Last 30 days"))
    local hours = Stats:byHour(Stats.dayStart() - 30 * 86400)
    local hour_labels = {}
    for _, hour in ipairs{ 0, 6, 12, 18 } do hour_labels[hour + 1] = hourLabel(hour) end
    rows[#rows + 1] = chart(w, hours, hour_labels, { gap = dp(3), height = dp(72) })

    local top = Stats:topBooks(Stats.dayStart() - 30 * 86400, nil, 5)
    if #top > 0 then
        rows[#rows + 1] = Rows.section(_("Most read"), _("Last 30 days"))
        for _, book in ipairs(top) do
            rows[#rows + 1] = ranked(w, book.title or _("Unknown"), Theme.duration(book.seconds),
                book.seconds / top[1].seconds)
        end
    end

    rows[#rows + 1] = Rows.spacer(dp(12))
    local year = tonumber(os.date("%Y"))
    rows[#rows + 1] = Rows.item(w, "star", T(_("%1 in review"), year), nil, function()
        StatsView.showYear(home, year)
    end)
    rows[#rows + 1] = Rows.item(w, "target", _("Daily reading goal"), Theme.duration(goal), function()
        home:setGoal()
    end)
    return rows
end

function StatsView.yearRows(w, year)
    local rows = {}
    local data = Stats:year(year)
    rows[#rows + 1] = Rows.spacer(dp(4))
    if data.seconds == 0 then
        rows[#rows + 1] = Rows.message(w, T(_("Nothing read in %1"), year), _("Reading you do this year will be summed up here."))
        return rows
    end
    rows[#rows + 1] = tiles(w, {
        { Theme.duration(data.seconds), _("Time read") },
        { tostring(data.pages), _("Pages") },
    })
    rows[#rows + 1] = tiles(w, {
        { tostring(data.books), _("Books opened") },
        { tostring(data.days), _("Days with reading") },
    })
    if data.best_day then
        local y, m, d = data.best_day:match("(%d+)-(%d+)-(%d+)")
        local ts = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
        rows[#rows + 1] = tiles(w, {
            { os.date("%d %b", ts), _("Best day") },
            { Theme.duration(data.best_day_seconds), _("Read that day") },
        })
    end
    rows[#rows + 1] = Rows.section(_("Month by month"))
    local labels = {}
    for month = 1, 12 do
        labels[month] = os.date("%b", os.time{ year = year, month = month, day = 1, hour = 12 }):sub(1, 1)
    end
    rows[#rows + 1] = chart(w, data.months, labels, { gap = dp(8) })
    if #data.top > 0 then
        rows[#rows + 1] = Rows.section(_("Most read books"))
        for _, book in ipairs(data.top) do
            rows[#rows + 1] = ranked(w, book.title or _("Unknown"), Theme.duration(book.seconds),
                book.seconds / data.top[1].seconds)
        end
    end
    return rows
end

function StatsView.showYear(home, year)
    local MacaScreen = require("maca/screen")
    local UIManager = require("ui/uimanager")
    local screen
    local function load(y)
        year = y
        local actions = {}
        if Stats:year(y - 1).seconds > 0 then
            actions[#actions + 1] = { icon = "back", on_tap = function() load(y - 1) end }
        end
        if y < tonumber(os.date("%Y")) then
            actions[#actions + 1] = { icon = "forward", on_tap = function() load(y + 1) end }
        end
        screen:setHeader(T(_("%1 in review"), y), actions, function() UIManager:close(screen) end)
        local rows = StatsView.yearRows(screen:width(), y)
        rows[#rows + 1] = Rows.spacer(dp(24))
        screen.scroll.offset = 0
        screen.scroll:setRows(rows)
        screen:redraw()
    end
    screen = MacaScreen:new{}
    load(year)
    UIManager:show(screen)
end

return StatsView
