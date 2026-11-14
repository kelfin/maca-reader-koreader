--[[--
Backup and restore of settings, reading history, collections and reading
statistics. Book files and the per-book files kept next to them (position,
highlights) are not part of it: they travel with the books.

@module koplugin.maca.backup
--]]--

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Backup = {}

-- Paths relative to the app's data directory.
local FILES = {
    "settings.reader.lua",
    "history.lua",
    "defaults.custom.lua",
    "settings/statistics.sqlite3",
    "settings/collection.lua",
    "settings/vocabulary_builder.sqlite3",
}

local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end

--- Copy the files into a new dated folder inside `dir`. Returns the folder
-- and the number of files copied.
function Backup.create(dir)
    local target = dir .. "/maca-backup-" .. os.date("%Y%m%d-%H%M%S")
    if not lfs.mkdir(target) then return nil, 0 end
    lfs.mkdir(target .. "/settings")
    G_reader_settings:flush()
    local data_dir = DataStorage:getDataDir()
    local copied = 0
    for _, name in ipairs(FILES) do
        local source = data_dir .. "/" .. name
        if exists(source) then
            ffiUtil.copyFile(source, target .. "/" .. name)
            copied = copied + 1
        end
    end
    return target, copied
end

--- True if `dir` looks like a folder made by Backup.create.
function Backup.isBackup(dir)
    return exists(dir .. "/settings.reader.lua")
end

--- Copy a backup's files over the current ones. The app must be restarted
-- afterwards, before anything saves the old settings again.
function Backup.restore(dir)
    local data_dir = DataStorage:getDataDir()
    local copied = 0
    for _, name in ipairs(FILES) do
        local source = dir .. "/" .. name
        if exists(source) then
            ffiUtil.copyFile(source, data_dir .. "/" .. name)
            copied = copied + 1
        end
    end
    return copied
end

return Backup
