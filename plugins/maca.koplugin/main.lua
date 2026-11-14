--[[--
Maca: home screen, book library and reading dashboard on top of KOReader.

@module koplugin.maca
--]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Maca = WidgetContainer:extend{
    name = "maca",
    is_doc_only = false,
}

function Maca:onDispatcherRegisterActions()
    Dispatcher:registerAction("maca_home", {
        category = "none", event = "MacaHome", title = _("Maca home screen"), general = true,
    })
end

function Maca:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.document then
        -- inside a book: remember it changed, so the library shows fresh progress
        self.opened_file = self.ui.document.file
        require("maca/reader").hookStyles(self.ui)
        -- highlights made on other devices, before the reader loads this book's settings
        local SyncFolder = require("maca/syncfolder")
        if SyncFolder.enabled() and self.ui.doc_settings then
            pcall(SyncFolder.import, self.opened_file, self.ui.doc_settings, true)
        end
        return
    end
    require("maca/animator").applyRefreshRate()
    local Home = require("maca/home")
    if G_reader_settings:nilOrTrue("maca_home_on_start") and not Home.State.browsing then
        -- the file manager is still being set up: show once it is on screen
        UIManager:nextTick(function() self:showHome() end)
    end
end

function Maca:showHome()
    if self.ui.document then
        -- from a book, go back to the file manager; Maca opens on top of it
        require("maca/home").State.browsing = false
        self.ui:onClose()
        self.ui:showFileManager()
        return
    end
    local Home = require("maca/home")
    if self.home and UIManager:isWidgetShown(self.home) then return end
    Home.State.browsing = false
    self.home = Home:new{ ui = self.ui }
    UIManager:show(self.home)
end

function Maca:onReaderReady()
    require("maca/reader").setup(self.ui)
end

function Maca:onMacaHome()
    self:showHome()
    return true
end

function Maca:onCloseDocument()
    require("maca/speech"):stop()
    if self.opened_file then
        local file = self.opened_file
        -- sidecar is written while closing; refresh once that is done
        UIManager:nextTick(function()
            local SyncFolder = require("maca/syncfolder")
            if SyncFolder.enabled() then pcall(SyncFolder.export, file) end
            require("maca/library"):refreshBook(file)
        end)
    end
end

function Maca:addToMainMenu(menu_items)
    menu_items.maca_home = {
        text = _("Maca home"),
        sorting_hint = "main",
        callback = function() self:showHome() end,
    }
end

return Maca
