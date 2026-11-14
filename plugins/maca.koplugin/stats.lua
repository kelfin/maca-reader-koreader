--[[--
Read-only queries on the reading statistics database kept by the Statistics
plugin (settings/statistics.sqlite3).

@module koplugin.maca.stats
--]]--

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Stats = {
    db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3",
    md5_cache = {},
}

local DAY = 86400

function Stats:available()
    return lfs.attributes(self.db_path, "mode") == "file"
end

-- Run fn(conn) with a read connection; returns nil if there is no database
-- or a query fails (an old or half-written database must not break the UI).
function Stats:with(fn)
    if not self:available() then return nil end
    local ok_open, conn = pcall(SQ3.open, self.db_path, "ro")
    if not ok_open then return nil end
    local ok, a, b, c = pcall(fn, conn)
    conn:close()
    if not ok then
        logger.warn("Maca stats query failed:", a)
        return nil
    end
    return a, b, c
end

local function rows(conn, sql)
    local res, n = conn:exec(sql)
    local out = {}
    if not res then return out end
    n = tonumber(n) or 0
    for i = 1, n do
        local row = {}
        for col = 1, #res do
            local v = res[col][i]
            row[col] = type(v) == "cdata" and tonumber(v) or v
        end
        out[i] = row
    end
    return out
end

--- Midnight (local time) of the day containing `ts`.
function Stats.dayStart(ts)
    local t = os.date("*t", ts or os.time())
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

function Stats.dayKey(ts)
    return os.date("%Y-%m-%d", ts)
end

--- Seconds and pages read per day since `from_ts`.
-- Returns a map "YYYY-MM-DD" -> { seconds =, pages = }.
function Stats:daily(from_ts)
    return self:with(function(conn)
        local out = {}
        for _, row in ipairs(rows(conn, string.format([[
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day,
                   sum(duration), count(DISTINCT id_book || '-' || page)
            FROM page_stat_data WHERE start_time >= %d GROUP BY day;]], from_ts or 0))) do
            out[row[1]] = { seconds = row[2] or 0, pages = row[3] or 0 }
        end
        return out
    end) or {}
end

--- Summary used by the home screen and the dashboard.
function Stats:overview(goal_seconds)
    local now = os.time()
    local today = Stats.dayStart(now)
    local daily = self:daily(today - 400 * DAY)
    local function day(offset)
        -- noon avoids daylight-saving edges when stepping by whole days
        return daily[Stats.dayKey(today + 12 * 3600 - offset * DAY)] or { seconds = 0, pages = 0 }
    end
    local out = { today = day(0), week = {}, daily = daily }
    local week_seconds, week_pages = 0, 0
    for i = 6, 0, -1 do
        local d = day(i)
        out.week[#out.week + 1] = { ts = today - i * DAY + 12 * 3600, seconds = d.seconds, pages = d.pages }
        week_seconds, week_pages = week_seconds + d.seconds, week_pages + d.pages
    end
    out.week_seconds, out.week_pages = week_seconds, week_pages
    local month_seconds, month_pages = 0, 0
    for i = 0, 29 do
        local d = day(i)
        month_seconds, month_pages = month_seconds + d.seconds, month_pages + d.pages
    end
    out.month_seconds, out.month_pages = month_seconds, month_pages
    -- A day counts towards the streak once the goal is met (or any reading
    -- when there is no goal). Today not being done yet does not break it.
    local needed = math.max(60, goal_seconds or 0)
    local streak, i = 0, 0
    if day(0).seconds < needed then i = 1 end
    while day(i).seconds >= needed do
        streak = streak + 1
        i = i + 1
    end
    out.streak = streak
    local best, run = 0, 0
    for offset = 399, 0, -1 do
        if day(offset).seconds >= needed then
            run = run + 1
            if run > best then best = run end
        else
            run = 0
        end
    end
    out.best_streak = best
    return out
end

function Stats:totals()
    return self:with(function(conn)
        local r = rows(conn, [[
            SELECT sum(duration), count(DISTINCT id_book || '-' || page), count(DISTINCT id_book),
                   count(DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')),
                   min(start_time)
            FROM page_stat_data;]])[1] or {}
        return { seconds = r[1] or 0, pages = r[2] or 0, books = r[3] or 0, days = r[4] or 0, since = r[5] }
    end) or { seconds = 0, pages = 0, books = 0, days = 0 }
end

--- Seconds read per hour of the day (index 1 = 00:00-00:59) since `from_ts`.
function Stats:byHour(from_ts)
    local out = {}
    for i = 1, 24 do out[i] = 0 end
    self:with(function(conn)
        for _, row in ipairs(rows(conn, string.format([[
            SELECT cast(strftime('%%H', start_time, 'unixepoch', 'localtime') AS integer) AS hour, sum(duration)
            FROM page_stat_data WHERE start_time >= %d GROUP BY hour;]], from_ts or 0))) do
            out[(row[1] or 0) + 1] = row[2] or 0
        end
    end)
    return out
end

--- Books with reading time in [from_ts, to_ts), most read first.
function Stats:topBooks(from_ts, to_ts, limit)
    return self:with(function(conn)
        local out = {}
        for _, row in ipairs(rows(conn, string.format([[
            SELECT book.title, book.authors, sum(page_stat_data.duration) AS seconds,
                   count(DISTINCT page_stat_data.page), book.md5
            FROM page_stat_data JOIN book ON book.id = page_stat_data.id_book
            WHERE start_time >= %d AND start_time < %d
            GROUP BY id_book ORDER BY seconds DESC LIMIT %d;]],
            from_ts or 0, to_ts or 2^40, limit or 10))) do
            out[#out + 1] = { title = row[1], authors = row[2], seconds = row[3] or 0, pages = row[4] or 0, md5 = row[5] }
        end
        return out
    end) or {}
end

--- Seconds per month for a year: array of 12 numbers.
function Stats:byMonth(year)
    local out = {}
    for i = 1, 12 do out[i] = 0 end
    local from_ts = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local to_ts = os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    self:with(function(conn)
        for _, row in ipairs(rows(conn, string.format([[
            SELECT cast(strftime('%%m', start_time, 'unixepoch', 'localtime') AS integer) AS month, sum(duration)
            FROM page_stat_data WHERE start_time >= %d AND start_time < %d GROUP BY month;]], from_ts, to_ts))) do
            if row[1] then out[row[1]] = row[2] or 0 end
        end
    end)
    return out
end

--- Totals for one calendar year.
function Stats:year(year)
    local from_ts = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local to_ts = os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    local out = self:with(function(conn)
        local r = rows(conn, string.format([[
            SELECT sum(duration), count(DISTINCT id_book || '-' || page), count(DISTINCT id_book),
                   count(DISTINCT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'))
            FROM page_stat_data WHERE start_time >= %d AND start_time < %d;]], from_ts, to_ts))[1] or {}
        local best = rows(conn, string.format([[
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day, sum(duration) AS seconds
            FROM page_stat_data WHERE start_time >= %d AND start_time < %d
            GROUP BY day ORDER BY seconds DESC LIMIT 1;]], from_ts, to_ts))[1]
        return {
            seconds = r[1] or 0, pages = r[2] or 0, books = r[3] or 0, days = r[4] or 0,
            best_day = best and best[1], best_day_seconds = best and best[2] or 0,
        }
    end) or { seconds = 0, pages = 0, books = 0, days = 0, best_day_seconds = 0 }
    out.year = year
    out.months = self:byMonth(year)
    out.top = self:topBooks(from_ts, to_ts, 5)
    return out
end

function Stats:md5(file)
    local cached = self.md5_cache[file]
    if cached == nil then
        cached = util.partialMD5(file) or false
        self.md5_cache[file] = cached
    end
    return cached or nil
end

--- Reading time, pages read and pace for one book file.
function Stats:book(file)
    local md5 = self:md5(file)
    if not md5 then return nil end
    return self:with(function(conn)
        local r = rows(conn, string.format([[
            SELECT book.id, book.pages, sum(d.duration), count(DISTINCT d.page),
                   min(d.start_time), max(d.start_time),
                   count(DISTINCT strftime('%%Y-%%m-%%d', d.start_time, 'unixepoch', 'localtime'))
            FROM book JOIN page_stat_data d ON d.id_book = book.id
            WHERE book.md5 = '%s' GROUP BY book.id ORDER BY 3 DESC LIMIT 1;]], md5))[1]
        if not r or not r[1] then return nil end
        local seconds, pages_read = r[3] or 0, r[4] or 0
        return {
            pages = r[2], seconds = seconds, pages_read = pages_read,
            first = r[5], last = r[6], days = r[7] or 0,
            seconds_per_page = pages_read > 0 and seconds / pages_read or nil,
        }
    end)
end

--- Estimated seconds needed to finish a book, or nil if unknown.
function Stats:timeLeft(file, percent, pages)
    local book = self:book(file)
    if not book or not book.seconds_per_page then return nil end
    local total = pages or book.pages
    if not total or total <= 0 then return nil end
    return math.max(0, (1 - (percent or 0)) * total * book.seconds_per_page)
end

return Stats
