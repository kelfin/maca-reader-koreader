-- Fill the dev data directory with reading progress, history and statistics
-- for the books in $MACA_BOOKS, so the Maca screens have something to show.
local H = MacaHarness
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local dir = os.getenv("MACA_BOOKS")
local files = {}
for name in lfs.dir(dir) do
    if name:match("%.epub$") then files[#files + 1] = dir .. "/" .. name end
end
table.sort(files)

local now = os.time()
local plan = { -- status, percent, pages, days since last read
    { "reading", 0.42, 320, 0 },
    { "reading", 0.77, 280, 1 },
    { "reading", 0.12, 410, 3 },
    { "complete", 1.0, 190, 9 },
    { "complete", 1.0, 240, 30 },
    { "abandoned", 0.31, 520, 45 },
}

local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
conn:exec([[
    CREATE TABLE IF NOT EXISTS book (id integer PRIMARY KEY autoincrement, title text, authors text,
        notes integer, last_open integer, highlights integer, pages integer, series text, language text,
        md5 text, total_read_time integer, total_read_pages integer);
    CREATE TABLE IF NOT EXISTS page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
        start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0,
        total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
    DELETE FROM book; DELETE FROM page_stat_data; DELETE FROM sqlite_sequence;
]])

math.randomseed(7)
for i, item in ipairs(plan) do
    local file = files[i]
    if file then
        local status, percent, pages, days_ago = unpack(item)
        local settings = DocSettings:open(file)
        settings:saveSetting("percent_finished", percent)
        settings:saveSetting("doc_pages", pages)
        settings:saveSetting("summary", { status = status, modified = os.date("%Y-%m-%d", now - days_ago * 86400) })
        settings:flush()
        ReadHistory:addItem(file, now - days_ago * 86400 - 600)
        local md5 = util.partialMD5(file)
        conn:exec(string.format("INSERT INTO book (title, authors, pages, md5) VALUES ('Book %d', 'Author', %d, '%s');",
            i, pages, md5))
        local id = i
        -- spread the pages read over the days before the last read
        local read_pages = math.floor(pages * percent)
        local page = 1
        local day = days_ago + math.ceil(read_pages / 25)
        while page <= read_pages do
            local t = now - day * 86400 - math.random(0, 3) * 3600
            if t > now then t = now - 3600 end
            for _ = 1, math.random(12, 34) do
                if page > read_pages then break end
                local duration = math.random(35, 110)
                conn:exec(string.format("INSERT OR IGNORE INTO page_stat_data VALUES (%d, %d, %d, %d, %d);",
                    id, page, t, duration, pages))
                t = t + duration
                page = page + 1
            end
            day = math.max(days_ago, day - 1)
            if day == days_ago and page <= read_pages then
                -- finish what is left on the last day
                local t2 = now - days_ago * 86400 - 5400
                while page <= read_pages do
                    local duration = math.random(35, 110)
                    conn:exec(string.format("INSERT OR IGNORE INTO page_stat_data VALUES (%d, %d, %d, %d, %d);",
                        id, page, t2, duration, pages))
                    t2 = t2 + duration
                    page = page + 1
                end
            end
        end
    end
end
-- a session earlier today on the first book, so "today" is not empty
do
    local t = now - 4000
    for page = 400, 417 do
        conn:exec(string.format("INSERT OR IGNORE INTO page_stat_data VALUES (1, %d, %d, 70, 320);", page, t))
        t = t + 70
    end
end
conn:exec("UPDATE book SET total_read_time = (SELECT sum(duration) FROM page_stat_data WHERE id_book = book.id), total_read_pages = (SELECT count(DISTINCT page) FROM page_stat_data WHERE id_book = book.id);")
conn:close()
io.stderr:write("MACA seeded ", #files, " books\n")
H.quit()
