--[[--
Send books to the library from a browser on the same network.

While the dialog is open, a tiny web server on this device serves one page
with a file picker and accepts the chosen files. There is no password: it
is meant for a home network, and it stops as soon as the dialog closes.

@module koplugin.maca.wifiupload
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Library = require("maca/library")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local WifiUpload = {
    port = 8085,
}

local PAGE = [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Send books to Maca</title>
<style>
body{font-family:system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1rem;color:#1b1b1b}
h1{font-size:1.4rem} .drop{border:2px dashed #1e7b5e;border-radius:16px;padding:2.5rem 1rem;text-align:center}
button{background:#1e7b5e;color:#fff;border:0;border-radius:999px;padding:.7rem 1.4rem;font-size:1rem}
li{margin:.3rem 0} .ok{color:#1e7b5e} .bad{color:#b3261e}
</style></head><body>
<h1>Send books to Maca</h1>
<div class="drop" id="drop"><p>Drop book files here, or</p>
<input type="file" id="files" multiple hidden>
<button onclick="document.getElementById('files').click()">Choose files</button></div>
<ul id="log"></ul>
<script>
const log = document.getElementById('log');
async function send(files) {
  for (const f of files) {
    const li = document.createElement('li'); li.textContent = f.name + ' …'; log.appendChild(li);
    try {
      const r = await fetch('/upload?name=' + encodeURIComponent(f.name), {method: 'PUT', body: f});
      const t = await r.text();
      li.textContent = f.name + ' — ' + t; li.className = r.ok ? 'ok' : 'bad';
    } catch (e) { li.textContent = f.name + ' — failed'; li.className = 'bad'; }
  }
}
document.getElementById('files').onchange = e => send(e.target.files);
const drop = document.getElementById('drop');
drop.ondragover = e => e.preventDefault();
drop.ondrop = e => { e.preventDefault(); send(e.dataTransfer.files); };
</script></body></html>]]

local function localAddress()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    -- no packet is sent; this only asks the system which interface would be used
    udp:setpeername("10.255.255.255", 1)
    local ip = udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" then return ip end
end

local function respond(client, status, text, content_type)
    client:send(string.format(
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        status, content_type or "text/plain; charset=utf-8", #text, text))
    client:close()
end

local function urlDecode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Receive one PUT body into the library folder. Returns a message for the browser.
function WifiUpload:receive(client, raw_name, length)
    local name = urlDecode(raw_name or ""):gsub("[/\\]", "_")
    if name == "" or name:sub(1, 1) == "." or not Library.isBook(name) then
        return "400 Bad Request", "not a book format Maca reads"
    end
    if not length or length <= 0 then
        return "411 Length Required", "empty file"
    end
    local dir = Library:getFolders()[1]
    name = util.getSafeFilename(name, dir)
    local path = dir .. "/" .. name
    if lfs.attributes(path, "mode") then
        return "409 Conflict", "already in the library"
    end
    local tmp = path .. ".part"
    local out, err = io.open(tmp, "wb")
    if not out then return "500 Internal Server Error", "cannot write: " .. tostring(err) end
    client:settimeout(15)
    local left = length
    while left > 0 do
        local chunk, cerr, partial = client:receive(math.min(left, 65536))
        chunk = chunk or partial
        if not chunk or #chunk == 0 then
            out:close()
            os.remove(tmp)
            logger.warn("Maca upload: connection lost", cerr)
            return "400 Bad Request", "upload interrupted"
        end
        out:write(chunk)
        left = left - #chunk
    end
    out:close()
    os.rename(tmp, path)
    self.received = self.received + 1
    return "200 OK", "added"
end

function WifiUpload:serve(client)
    client:settimeout(2)
    local request = client:receive("*l")
    if not request then return client:close() end
    local method, target = request:match("^(%u+)%s+(%S+)")
    local length
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key and key:lower() == "content-length" then length = tonumber(value) end
    end
    if method == "GET" and (target == "/" or target == "/index.html") then
        return respond(client, "200 OK", PAGE, "text/html; charset=utf-8")
    elseif method == "PUT" and target and target:match("^/upload%?") then
        local status, text = self:receive(client, target:match("[?&]name=([^&]*)"), length)
        return respond(client, status, text)
    end
    respond(client, "404 Not Found", "not found")
end

function WifiUpload:poll()
    if not self.server then return end
    local client = self.server:accept()
    while client do
        local ok, err = pcall(self.serve, self, client)
        if not ok then
            logger.warn("Maca upload: request failed", err)
            pcall(client.close, client)
        end
        client = self.server:accept()
    end
    UIManager:scheduleIn(0.25, self.poll_task)
end

function WifiUpload:stop()
    if self.poll_task then UIManager:unschedule(self.poll_task) end
    if self.server then
        self.server:close()
        self.server = nil
    end
end

--- Start the server and show its address until the user is done.
function WifiUpload:show(on_done)
    NetworkMgr:runWhenOnline(function()
        local socket = require("socket")
        local server, err = socket.bind("*", self.port)
        if not server then
            UIManager:show(InfoMessage:new{ text = T(_("Could not start receiving books: %1"), tostring(err)) })
            return
        end
        server:settimeout(0)
        self.server = server
        self.received = 0
        self.poll_task = function() self:poll() end
        UIManager:scheduleIn(0.25, self.poll_task)
        local address = localAddress()
        local where = address and string.format("http://%s:%d", address, self.port)
            or T(_("this device's address, port %1"), self.port)
        local function finish()
            self:stop()
            if self.received > 0 then
                Library:scan()
                UIManager:show(InfoMessage:new{
                    text = T(N_("%1 book added.", "%1 books added.", self.received), self.received),
                    timeout = 3,
                })
            end
            if on_done then on_done(self.received) end
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("On a computer or phone on the same Wi-Fi, open\n\n%1\n\nand choose the books to send. Keep this message open while sending.\n\nAnyone on this network can send files while it is open."), where),
            ok_text = _("Done"),
            no_ok_button = false,
            cancel_text = _("Stop"),
            ok_callback = finish,
            cancel_callback = finish,
        })
    end)
end

return WifiUpload
