--[[--
Sync of highlights, notes and reading status through a shared folder.

The user points every device at the same folder and keeps that folder in
step with whatever they like (Syncthing, a cloud drive app, a WebDAV mount).
Each book gets one small JSON file named after the book's content hash, so
file names and locations may differ between devices.

Merging only adds: a highlight made on any device reaches the others, and a
highlight deleted on one device comes back from the others. Reading
position is left to the KOSync plugin.

@module koplugin.maca.syncfolder
--]]--

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local JSON = require("json")
local Stats = require("maca/stats")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local SyncFolder = {}

local FORMAT = 1

function SyncFolder.dir()
    local dir = G_reader_settings:readSetting("maca_sync_dir")
    if dir and lfs.attributes(dir, "mode") == "directory" then return dir end
end

function SyncFolder.enabled()
    return SyncFolder.dir() ~= nil
end

local function deviceId()
    return G_reader_settings:readSetting("device_id") or "unknown"
end

local function pathFor(file)
    local dir = SyncFolder.dir()
    local md5 = dir and Stats:md5(file)
    if not md5 then return nil end
    return dir .. "/" .. md5 .. ".json"
end

local function key(item)
    return tostring(item.datetime) .. "|" .. tostring(item.pos0 or item.page)
end

local function stamp(item)
    return item.datetime_updated or item.datetime or ""
end

local function readRemote(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local text = file:read("*all")
    file:close()
    local ok, data = pcall(JSON.decode, text)
    if ok and type(data) == "table" and data.format == FORMAT then return data end
    logger.warn("Maca sync: ignoring unreadable file", path)
end

--- Merge two annotation lists. Returns the merged list and how many items
-- of `theirs` were new or newer than ours.
function SyncFolder.merge(ours, theirs)
    local merged, index, gained = {}, {}, 0
    for _, item in ipairs(ours or {}) do
        merged[#merged + 1] = item
        index[key(item)] = #merged
    end
    for _, item in ipairs(theirs or {}) do
        local at = index[key(item)]
        if not at then
            merged[#merged + 1] = item
            index[key(item)] = #merged
            gained = gained + 1
        elseif stamp(item) > stamp(merged[at]) then
            merged[at] = item
            gained = gained + 1
        end
    end
    return merged, gained
end

--- Whether a list of annotations suits the document kind of `doc_settings`:
-- reflowable books address text by string pointers, fixed pages by numbers.
local function compatible(ours, theirs)
    local a, b = ours and ours[1], theirs and theirs[1]
    if not a or not b then return true end
    return type(a.page) == type(b.page)
end

--- Write this device's view of a book into the sync folder.
function SyncFolder.export(file, doc_settings)
    local path = pathFor(file)
    if not path then return false end
    doc_settings = doc_settings or (DocSettings:hasSidecarFile(file) and DocSettings:open(file))
    if not doc_settings then return false end
    local annotations = doc_settings:readSetting("annotations") or {}
    local summary = doc_settings:readSetting("summary") or {}
    local remote = readRemote(path)
    if remote and compatible(annotations, remote.annotations) then
        -- keep what other devices added since we last looked
        annotations = SyncFolder.merge(annotations, remote.annotations)
    end
    local data = {
        format = FORMAT,
        device = deviceId(),
        updated = os.time(),
        title = doc_settings:readSetting("doc_props") and doc_settings:readSetting("doc_props").title,
        status = summary.status,
        status_modified = summary.modified,
        rating = summary.rating,
        percent = doc_settings:readSetting("percent_finished"),
        annotations = annotations,
    }
    local ok, text = pcall(JSON.encode, data)
    if not ok then
        logger.warn("Maca sync: could not encode", file, text)
        return false
    end
    local tmp = path .. ".tmp"
    local out = io.open(tmp, "w")
    if not out then return false end
    out:write(text)
    out:close()
    os.rename(tmp, path)
    return true
end

--- Bring other devices' highlights and status into a book's settings.
-- Returns the number of highlights gained. With `in_memory` (the book is
-- being opened) the settings object is changed but not written; the reader
-- sorts and saves it.
function SyncFolder.import(file, doc_settings, in_memory)
    local path = pathFor(file)
    if not path then return 0 end
    local remote = readRemote(path)
    if not remote or remote.device == deviceId() then return 0 end
    doc_settings = doc_settings or DocSettings:open(file)
    local ours = doc_settings:readSetting("annotations") or {}
    local gained = 0
    if compatible(ours, remote.annotations) then
        local merged
        merged, gained = SyncFolder.merge(ours, remote.annotations)
        if gained > 0 then
            doc_settings:saveSetting("annotations", merged)
            -- tells the reader to re-sort and refresh page numbers on next open
            doc_settings:saveSetting("annotations_externally_modified", true)
        end
    end
    local summary = doc_settings:readSetting("summary") or {}
    local changed = gained > 0
    if remote.status and (remote.status_modified or "") > (summary.modified or "") then
        summary.status = remote.status
        summary.modified = remote.status_modified
        if remote.rating then summary.rating = remote.rating end
        doc_settings:saveSetting("summary", summary)
        changed = true
    end
    if changed and not in_memory then
        doc_settings:flush()
        BookList.resetBookInfoCache(file)
    end
    return gained
end

--- Sync every book in the library. Returns books touched and highlights gained.
function SyncFolder.syncAll(books)
    local touched, gained = 0, 0
    for _, entry in ipairs(books) do
        local has_sidecar = DocSettings:hasSidecarFile(entry.file)
        local path = pathFor(entry.file)
        local remote_exists = path and lfs.attributes(path, "mode") == "file"
        if remote_exists then
            local n = SyncFolder.import(entry.file)
            if n > 0 then touched, gained = touched + 1, gained + n end
        end
        if has_sidecar or remote_exists then
            SyncFolder.export(entry.file)
        end
    end
    return touched, gained
end

return SyncFolder
