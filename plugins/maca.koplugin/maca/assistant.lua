--[[--
Optional reading assistant: ask a question about the page on screen.

Off until the user enters their own Anthropic API key. Each question sends
the text of the current page and the question to the Claude API; nothing is
sent at any other time.

@module koplugin.maca.assistant
--]]--

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Assistant = {}

local API_URL = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2026-10-21"
local DEFAULT_MODEL = "claude-opus-5-5"

function Assistant.key()
    local key = G_reader_settings:readSetting("maca_ai_key")
    return key and key ~= "" and key or nil
end

function Assistant.configured()
    return Assistant.key() ~= nil
end

function Assistant.model()
    return G_reader_settings:readSetting("maca_ai_model") or DEFAULT_MODEL
end

--- Ask for the API key (empty clears it).
function Assistant.setup(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Reading assistant"),
        description = _("Enter your Anthropic API key to ask questions about the page you are reading. The page text and your question are sent to the Claude API when you ask; usage is billed to your key. Leave empty to turn the assistant off."),
        input = Assistant.key() or "",
        input_hint = "sk-ant-…",
        text_type = "password",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local key = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if key == "" then
                    G_reader_settings:delSetting("maca_ai_key")
                else
                    G_reader_settings:saveSetting("maca_ai_key", key)
                end
                if on_done then on_done() end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Send one question. Returns the answer text, or nil and a message.
function Assistant.request(system, user_text)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local body = JSON.encode{
        model = Assistant.model(),
        max_tokens = 16000,
        system = system,
        -- if a safety check declines, let the API retry on its default fallback model
        fallbacks = "default",
        messages = { { role = "user", content = user_text } },
    }
    local chunks = {}
    socketutil:set_timeout(20, 120)
    local code, headers, status = socket.skip(1, http.request{
        url = API_URL,
        method = "POST",
        headers = {
            ["content-type"] = "application/json",
            ["content-length"] = tostring(#body),
            ["x-api-key"] = Assistant.key(),
            ["anthropic-version"] = API_VERSION,
            ["anthropic-beta"] = "server-side-fallback-2026-07-01",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    local ok, data = pcall(JSON.decode, table.concat(chunks))
    if code ~= 200 then
        local detail = ok and type(data) == "table" and data.error and data.error.message
        logger.warn("Maca assistant: request failed", code, status, detail)
        if code == 401 then return nil, _("The API key was not accepted.") end
        if code == 429 then return nil, _("Too many requests or out of credit. Try again later.") end
        return nil, detail or T(_("The request failed (%1)."), tostring(status or code or headers))
    end
    if not ok or type(data) ~= "table" then
        return nil, _("The reply could not be read.")
    end
    if data.stop_reason == "refusal" then
        return nil, _("The assistant declined to answer this.")
    end
    local parts = {}
    for _, block in ipairs(data.content or {}) do
        if block.type == "text" and block.text then parts[#parts + 1] = block.text end
    end
    if #parts == 0 then return nil, _("The reply was empty.") end
    return table.concat(parts, "\n")
end

local function pageText(ui)
    if ui.rolling then
        local range = ui.document:getTextFromPositions({ x = 0, y = 0 },
            { x = Screen:getWidth(), y = Screen:getHeight() }, true)
        return range and range.text or ""
    end
    return require("maca/speech").pageText({ ui = ui })
end

--- Ask a question about the page on screen.
function Assistant.askAboutPage(ui)
    local dialog
    dialog = InputDialog:new{
        title = _("Ask about this page"),
        input = "",
        input_hint = _("For example: explain this passage in simple words"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Ask"), is_enter_default = true, callback = function()
                local question = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if question == "" then question = "Explain what happens on this page in simple words." end
                NetworkMgr:runWhenOnline(function()
                    local waiting = InfoMessage:new{ text = _("Asking…") }
                    UIManager:show(waiting)
                    UIManager:forceRePaint()
                    local props = ui.doc_props or {}
                    local system = "You help a reader understand the book they are reading. "
                        .. "Answer from the page text provided. Do not reveal events from later in the book. "
                        .. "Answer in the language of the question, in plain text without Markdown."
                    local user_text = string.format("Book: %s%s\n\nPage text:\n%s\n\nQuestion: %s",
                        props.display_title or "unknown",
                        props.authors and (" by " .. props.authors:gsub("\n", ", ")) or "",
                        pageText(ui), question)
                    local answer, err = Assistant.request(system, user_text)
                    UIManager:close(waiting)
                    if answer then
                        UIManager:show(TextViewer:new{ title = question, text = answer })
                    else
                        UIManager:show(InfoMessage:new{ text = err })
                    end
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Assistant
