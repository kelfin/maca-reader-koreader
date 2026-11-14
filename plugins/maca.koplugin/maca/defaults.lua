--[[--
First-run defaults for Maca. Applied once, early in startup, and only to
settings the user has not touched.

@module koplugin.maca.defaults
--]]--

local Defaults = {}

local VERSION = 2

function Defaults.apply()
    local settings = G_reader_settings
    if (settings:readSetting("maca_defaults_version") or 0) >= VERSION then return end
    local Device = require("device")
    local Screen = Device.screen
    local function default(key, value)
        if settings:hasNot(key) then settings:saveSetting(key, value) end
    end

    -- Maca has its own first screen; skip the KOReader quick-start guide.
    default("quickstart_shown_version", require("ui/quickstart").quickstart_force_show_version)

    -- Comfortable page margins: KOReader's default is tuned for small e-ink screens.
    local short_dp = math.min(Screen:getWidth(), Screen:getHeight()) * 160 / Screen:getDPI()
    local tablet = short_dp >= 600
    default("copt_h_page_margins", tablet and { 50, 50 } or { 25, 25 })
    -- Two pages side by side when a tablet is held in landscape.
    if tablet then default("copt_visible_pages", 2) end

    -- A quiet status line: page and time left in the chapter, no bar or clock.
    -- The reader takes this table as it is, so start from its complete defaults.
    if settings:hasNot("footer") then
        local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
        if ok and ReaderFooter.default_settings then
            local footer = require("util").tableDeepCopy(ReaderFooter.default_settings)
            footer.disable_progress_bar = true
            footer.all_at_once = true
            footer.page_progress = true
            footer.chapter_time_to_read = true
            footer.time = false
            footer.pages_left = false
            footer.battery = false
            footer.percentage = false
            footer.book_time_to_read = false
            footer.item_prefix = "compact_items"
            footer.text_font_size = 12
            settings:saveSetting("footer", footer)
        end
    end

    settings:saveSetting("maca_defaults_version", VERSION)
end

return Defaults
