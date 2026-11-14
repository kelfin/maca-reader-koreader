--[[--
Read aloud. The page's text is queued sentence by sentence on the Android
text-to-speech engine; when the engine has finished the page, the page is
turned and the next one queued.

The engine sits behind five functions of the `android` module (speechStart,
speechSay, speechStop, speechSetRate, speechDone), so another engine can
take its place later without changing this file.

Limits: reading stops when the app is no longer in front (there is no
background service yet), and a sentence that runs over a page break is
spoken in two parts.

@module koplugin.maca.speech
--]]--

local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Speech = {
    active = false,
    next_id = 1,
    page_last_id = 0,
}

local POLL = 0.25
local MAX_CHUNK = 280 -- engines refuse very long utterances

local function engine()
    if not Device:isAndroid() then return nil end
    local ok, android = pcall(require, "android")
    if ok and android.speechStart then return android end
end

function Speech.available()
    return engine() ~= nil
end

Speech.rates = { { 80, "0.8×" }, { 100, "1×" }, { 120, "1.2×" }, { 150, "1.5×" }, { 200, "2×" } }

function Speech.rate()
    return G_reader_settings:readSetting("maca_speech_rate") or 100
end

function Speech.setRate(percent)
    G_reader_settings:saveSetting("maca_speech_rate", percent)
    local android = engine()
    if android then pcall(android.speechSetRate, percent) end
end

--- Split text into speakable pieces: sentences, cut further if very long.
function Speech.split(text)
    local pieces = {}
    text = (text or ""):gsub("%s+", " ")
    local function add(piece)
        piece = piece:match("^%s*(.-)%s*$")
        while #piece > MAX_CHUNK do
            -- cut at the last space before the limit
            local cut = piece:sub(1, MAX_CHUNK):match("^.*()%s") or MAX_CHUNK
            pieces[#pieces + 1] = piece:sub(1, cut)
            piece = piece:sub(cut + 1)
        end
        if piece ~= "" then pieces[#pieces + 1] = piece end
    end
    local start = 1
    while true do
        -- sentence end: . ! ? … followed by optional closing quotes/brackets, then a space
        local s, e = text:find("[%.!%?]['\"%)%]]*%s", start)
        local s2, e2 = text:find("…%s", start, false)
        if s2 and (not s or s2 < s) then e = e2 end
        if not e then break end
        add(text:sub(start, e))
        start = e + 1
    end
    add(text:sub(start))
    return pieces
end

--- Text of the page on screen. `self` needs only a `ui` field.
function Speech.pageText(self)
    local ui = self.ui
    local doc = ui.document
    if ui.rolling then
        local range = doc:getTextFromPositions({ x = 0, y = 0 },
            { x = Screen:getWidth(), y = Screen:getHeight() }, true)
        return range and range.text or ""
    end
    local page = ui:getCurrentPage()
    local ok, lines = pcall(doc.getPageText, doc, page)
    if not ok or type(lines) ~= "table" then return "" end
    local words = {}
    for _, block in ipairs(lines) do
        for _, line in ipairs(block) do
            if type(line) == "table" then
                if line.word then
                    words[#words + 1] = line.word
                else
                    for _, word in ipairs(line) do
                        if type(word) == "table" and word.word then words[#words + 1] = word.word end
                    end
                end
            end
        end
    end
    return table.concat(words, " ")
end

function Speech:queuePage()
    local android = engine()
    local pieces = Speech.split(self:pageText())
    for _, piece in ipairs(pieces) do
        android.speechSay(piece, self.next_id)
        self.next_id = self.next_id + 1
    end
    self.page_last_id = self.next_id - 1
    self.page_empty = #pieces == 0
end

function Speech:poll()
    if not self.active then return end
    local android = engine()
    local ok, done = pcall(android.speechDone)
    if ok and (self.page_empty or done >= self.page_last_id) then
        local ui = self.ui
        local before = ui:getCurrentPage()
        ui:handleEvent(Event:new("GotoViewRel", 1))
        if ui:getCurrentPage() == before then
            self:stop() -- end of the book
            return
        end
        self:queuePage()
    end
    UIManager:scheduleIn(POLL, self.poll_task)
end

--- Start reading from the page on screen.
function Speech:start(ui)
    local android = engine()
    if not android then return false end
    self:stop()
    self.ui = ui
    self.poll_task = function() self:poll() end
    local tries = 0
    -- the engine starts in the background; wait for it briefly
    local function begin()
        local ok, ready = pcall(android.speechStart)
        if ok and ready then
            pcall(android.speechSetRate, Speech.rate())
            self.active = true
            -- ids only ever grow, so "done" from an earlier session cannot be mistaken for ours
            local ok_done, done = pcall(android.speechDone)
            self.next_id = math.max(self.next_id, (ok_done and done or 0) + 1)
            self:queuePage()
            UIManager:scheduleIn(POLL, self.poll_task)
        elseif tries < 20 then
            tries = tries + 1
            UIManager:scheduleIn(0.25, begin)
        else
            logger.warn("Maca speech: engine did not start")
            UIManager:show(InfoMessage:new{
                text = _("Could not start a text-to-speech voice. Check that one is installed in Android's settings."),
            })
        end
    end
    begin()
    return true
end

function Speech:stop()
    if self.poll_task then UIManager:unschedule(self.poll_task) end
    if self.active then
        local android = engine()
        if android then pcall(android.speechStop) end
    end
    self.active = false
end

--- The reader moved by hand: read from the new page.
function Speech:restart()
    if not self.active then return end
    local android = engine()
    pcall(android.speechStop)
    UIManager:unschedule(self.poll_task)
    self:queuePage()
    UIManager:scheduleIn(POLL, self.poll_task)
end

return Speech
