--[[--
First-run defaults for Maca. Applied once, early in startup, and only to
settings the user has not touched.

@module koplugin.maca.defaults
--]]--

local Defaults = {}

local VERSION = 1

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

    settings:saveSetting("maca_defaults_version", VERSION)
end

return Defaults
