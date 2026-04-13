-- =============================================================================
-- PixelPerfectUI - Core.lua
-- =============================================================================
-- ROOT PROBLEM:
--   WoW's virtual coordinate space is always 768 units tall. For 1 unit to
--   equal 1 physical pixel, UIParent must be scaled to (768 / physicalHeight).
--
--   At 4K (3840×2160): ideal scale = 768/2160 = 0.3556
--   BUT: the uiScale CVar has a hard floor of 0.64 — anything lower is silently
--   ignored. This means every resolution above ~1200px vertical is broken by
--   default: pixel positions aren't whole numbers, borders bleed, and components
--   refuse to line up no matter how you nudge them.
--
-- FIX:
--   UIParent:SetScale() bypasses the CVar floor entirely. This addon calls it
--   at login, on display changes, and optionally hooks ElvUI so it can't fight
--   back and re-apply its own (clamped) scale.
--
-- PUBLIC API (usable by other addons):
--   PixelPerfectUI:SnapToPixel(val [, frame])     -> round to nearest pixel boundary
--   PixelPerfectUI:PixelsToRegionUnits(n [, f])   -> convert pixel count to region units
--   PixelPerfectUI:RegionUnitsToPixels(n [, f])   -> convert region units to pixels
--   PixelPerfectUI:GetPixelPerfectScale()          -> ideal UIParent scale for this screen
--   PixelPerfectUI:IsPixelPerfect()                -> true when currently aligned
--   PixelPerfectUI:ApplyScale([scale])             -> apply pixel-perfect scale now
-- =============================================================================

local ADDON_NAME, ns = ...

-- Main addon object, also a Frame so it can receive events
local PPUI = CreateFrame("Frame", "PixelPerfectUI", UIParent)
PPUI.version = "1.0.0"
ns.PPUI = PPUI
_G["PixelPerfectUI"] = PPUI   -- Public API

-- ---------------------------------------------------------------------------
-- Saved-variable defaults
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    enabled        = true,
    hookElvUI      = true,
    autoApply      = true,
    useManualScale = false,
    manualScale    = 0.5,
    minimapAngle   = 225,
    windowX        = nil,
    windowY        = nil,
    -- Alignment tools
    guides         = {},
    gridEnabled    = false,
    gridSize       = 32,
    gridAlpha      = 0.15,
    showCenter     = false,
}

-- ---------------------------------------------------------------------------
-- CVar shim  (C_CVar arrived in Dragonflight; older clients use globals)
-- ---------------------------------------------------------------------------
local function GetCVarSafe(key)
    if C_CVar then return C_CVar.GetCVar(key) end
    return GetCVar(key)
end

local function SetCVarSafe(key, val)
    if C_CVar then return C_CVar.SetCVar(key, tostring(val)) end
    return SetCVar(key, tostring(val))
end

-- Share with GUI.lua via the addon namespace
ns.GetCVarSafe = GetCVarSafe
ns.SetCVarSafe = SetCVarSafe

-- atan2 shim (Lua 5.1 style; LuaJIT used by WoW)
ns.atan2 = math.atan2 or math.atan

-- =============================================================================
-- SCALE ENGINE
-- =============================================================================

--- Returns the true physical screen dimensions in pixels.
function PPUI:GetPhysicalSize()
    return GetPhysicalScreenSize()
end

--- The ideal UIParent scale for pixel-perfect rendering at a comfortable size.
---
--- KEY INSIGHT:
---   "Pixel perfect" does NOT require 1 unit = 1 pixel.
---   It requires: scale × physH / 768 = N   (any positive integer N)
---   When this holds, every unit maps to exactly N whole pixels — no sub-pixel
---   rounding, no drift, no unexplained 1px misalignment.
---
---   The base (N=1) scale is 768/physH. We multiply by the integer N that
---   brings the resulting scale closest to a comfortable reference size
---   (the 1080p default of 768/1080 ≈ 0.7111).
---
---   Resolution examples:
---     1080p  → N=1  → scale=0.7111  (1 px/unit)  within CVar range
---     1440p  → N=1  → scale=0.5333  (1 px/unit)  requires SetScale bypass
---     4K     → N=2  → scale=0.7111  (2 px/unit)  within CVar range ← no bypass needed!
---     5K     → N=3  → scale=0.8000  (3 px/unit)  within CVar range
---
---   At 4K with N=2 the UI is the same proportional size as 1080p — comfortable
---   and fully pixel-aligned. Frame widths must be even integers in region units
---   (or use SnapToPixel), but that is trivially achieved and solves the drift.
---
--- Critical limitation of the CVar:  floor is 0.64 (sub-1440p is fine without bypass).
--- For 1440p N=1 (0.5333) we still use SetScale() to bypass the floor.
function PPUI:GetPixelPerfectScale()
    local _, physH = self:GetPhysicalSize()
    local base = 768 / physH      -- N=1 scale (1 px per region unit)
    local REF  = 768 / 1080       -- 0.7111 — comfortable 1080p reference

    -- Find integer multiplier N whose scale is closest to REF.
    -- Cap search at N=8 and scale <= 1.6 to avoid absurdly large UIs.
    local bestScale = base
    local bestDelta = math.abs(base - REF)
    for n = 2, 8 do
        local s = base * n
        if s > 1.6 then break end
        local delta = math.abs(s - REF)
        if delta < bestDelta then
            bestDelta = delta
            bestScale = s
        end
    end
    return bestScale
end

--- Returns N, the pixel density multiplier used for the current resolution.
--- N=1 means 1 physical pixel per region unit; N=2 means 2 pixels per unit, etc.
--- Frame sizes set to multiples of N in region units will always be pixel-exact.
function PPUI:GetPixelMultiplier()
    local _, physH = self:GetPhysicalSize()
    local base  = 768 / physH
    local scale = self:GetPixelPerfectScale()
    return math.max(1, math.floor(scale / base + 0.5))
end

--- Convert N physical pixels to region units at the given frame's effective scale.
--- Use this when you want to express a pixel-exact size as a SetWidth/SetHeight value.
--- @param pixels  number   How many physical pixels
--- @param frame   Frame?   Defaults to UIParent
function PPUI:PixelsToRegionUnits(pixels, frame)
    local _, physH = self:GetPhysicalSize()
    local scale    = (frame or UIParent):GetEffectiveScale()
    return (pixels * 768) / (scale * physH)
end

--- Convert region units to physical pixels at the given frame's effective scale.
--- @param units   number
--- @param frame   Frame?   Defaults to UIParent
function PPUI:RegionUnitsToPixels(units, frame)
    local _, physH = self:GetPhysicalSize()
    local scale    = (frame or UIParent):GetEffectiveScale()
    return (units * scale * physH) / 768
end

--- Snap a region-unit value to the nearest whole physical pixel boundary.
---
--- This is the key utility for eliminating the "off by 1 pixel" drift.
--- At non-pixel-perfect scales, fractional pixel positions cause the engine
--- to round inconsistently, which is why nudging by 1 "unit" sometimes fixes
--- alignment and sometimes doesn't — you're fighting floating-point rounding.
---
--- After calling SnapToPixel() on all your frame sizes and positions, each
--- value will land on an exact pixel boundary every time.
---
--- @param val    number   Value in region units
--- @param frame  Frame?   Defaults to UIParent
function PPUI:SnapToPixel(val, frame)
    local _, physH   = self:GetPhysicalSize()
    local scale      = (frame or UIParent):GetEffectiveScale()
    local pixelSize  = 768 / (scale * physH)   -- 1 physical pixel in region units
    return math.floor(val / pixelSize + 0.5) * pixelSize
end

--- Returns true when UIParent is at pixel-perfect scale (within floating-point epsilon).
function PPUI:IsPixelPerfect()
    local current = UIParent:GetScale()
    local target  = self.db.useManualScale and self.db.manualScale
                    or self:GetPixelPerfectScale()
    return math.abs(current - target) < 0.000005
end

-- =============================================================================
-- SCALE APPLICATION
-- =============================================================================

--- Apply a scale value.
--- With ElvUI: writes into E.global.general.UIScale and calls E:UIScale()
--- so ElvUI owns the change and recalculates E.mult correctly.
--- Without ElvUI: UIParent:SetScale() directly.
--- NOTE: no enabled/disabled guard here — always works when called explicitly.
--- @param scale  number?   Defaults to auto pixel-perfect for this resolution
function PPUI:ApplyScale(scale)
    scale = scale or (self.db and self.db.useManualScale and self.db.manualScale
                      or self:GetPixelPerfectScale())

    local E = self:E()
    if E and type(E.UIScale) == "function" then
        if E.global and E.global.general then
            E.global.general.UIScale = scale
        end
        E:UIScale()
        if type(E.UIMult) == "function" then E:UIMult() end
    else
        UIParent:SetScale(scale)
        SetCVarSafe("useUiScale", "1")
        SetCVarSafe("uiScale", string.format("%.6f", math.max(0.64, math.min(2.0, scale))))
    end

    if self.GUI and self.GUI:IsShown() then
        self.GUI:Refresh()
    end
end

--- Returns the ElvUI engine object (E), or nil if ElvUI is not loaded.
function PPUI:E()
    return ElvUI and ElvUI[1] or nil
end

--- Returns a diagnostic snapshot of ElvUI's internal scale state.
function PPUI:GetElvUIInfo()
    local E = self:E()
    if not E then return nil end
    local _, physH  = self:GetPhysicalSize()
    local curScale  = UIParent:GetScale()
    local idealMult = 768 / (physH * curScale)
    return {
        uiScale   = (E.global and E.global.general and E.global.general.UIScale) or E.uiscale or 0,
        mult      = E.mult    or 0,
        idealMult = idealMult,
        scaleOK   = E.uiscale and math.abs(E.uiscale - curScale) < 0.000005,
        multOK    = E.mult    and math.abs(E.mult - idealMult)   < 0.000005,
    }
end

--- Alias kept for slash command compatibility.
function PPUI:SyncElvUI() self:ApplyScale() end

-- =============================================================================
-- EVENTS
-- =============================================================================

PPUI:RegisterEvent("ADDON_LOADED")
PPUI:RegisterEvent("PLAYER_LOGIN")

PPUI:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        PixelPerfectUIDB = PixelPerfectUIDB or {}
        self.db          = setmetatable(PixelPerfectUIDB, { __index = DEFAULTS })

    elseif event == "PLAYER_LOGIN" then
        if not self.db then
            PixelPerfectUIDB = PixelPerfectUIDB or {}
            self.db          = setmetatable(PixelPerfectUIDB, { __index = DEFAULTS })
        end

        -- Init alignment tools after UI settles.
        C_Timer.After(0.3, function()
            if ns.AlignTools then ns.AlignTools:Init() end
        end)

        -- Auto-apply at 2s — after ElvUI's own login sequence finishes.
        -- User can always hit Apply Now manually from the GUI.
        if self.db.enabled and self.db.autoApply then
            C_Timer.After(2.0, function()
                self:ApplyScale()
                C_Timer.After(0.3, function()
                    if ns.AlignTools then ns.AlignTools:RebuildAll() end
                end)
            end)
        end
    end
end)

-- =============================================================================
-- LOGGING / CHAT OUTPUT
-- =============================================================================

local PREFIX = "|cff7ec8e3[Pixel|r|cffffffffPerfect|r|cff7ec8e3UI]|r "

function PPUI:Log(msg)
    print(PREFIX .. msg)
end

--- One-line status summary printed to chat.
function PPUI:PrintStatus()
    local physW, physH = self:GetPhysicalSize()
    local cur    = UIParent:GetScale()
    local target = self:GetPixelPerfectScale()
    local dot    = self:IsPixelPerfect() and "|cff33dd55●|r" or "|cffff9933●|r"
    print(string.format(
        "%s%s  |cffaaaaaa%dx%d|r  scale=|cfffffff0%.6f|r  target=|cfffffff0%.6f|r  1px=|cfffffff0%.6f|r units",
        PREFIX, dot, physW, physH, cur, target, self:PixelsToRegionUnits(1)))
end

--- Full diagnostic dump to chat.
function PPUI:PrintFullInfo()
    local physW, physH = self:GetPhysicalSize()
    local cur       = UIParent:GetScale()
    local target    = self:GetPixelPerfectScale()
    local N         = self:GetPixelMultiplier()
    local pixelU    = self:PixelsToRegionUnits(1)
    local pxPerU    = self:RegionUnitsToPixels(1)
    local cvarScale = tonumber(GetCVarSafe("uiScale"))  or 0
    local cvarUse   = GetCVarSafe("useUiScale")          or "0"
    local frac      = pxPerU - math.floor(pxPerU)

    print(PREFIX .. "|cff7ec8e3━━━  Full Diagnostics  ━━━|r")
    print(string.format("  Physical resolution   : |cfffffff0%d × %d|r  (%.4f:1)",
        physW, physH, physW / physH))
    print(string.format("  UIParent scale (live) : |cfffffff0%.6f|r", cur))
    print(string.format("  Pixel-perfect target  : |cfffffff0%.6f|r  (N=%d, %d px per unit)%s",
        target, N, N,
        target < 0.64
            and "  |cffff9933← SetScale bypass active|r"
            or  "  |cff33dd55← within CVar range|r"))
    print(string.format("  uiScale CVar          : |cfffffff0%.6f|r  (useUiScale=%s)",
        cvarScale, cvarUse))
    print(string.format("  1 pixel               : |cfffffff0%.6f|r region units", pixelU))
    print(string.format("  Pixels per unit       : |cfffffff0%.6f|r  (ideal %d.0, frac=%.5f)",
        pxPerU, N, frac))
    print("  Status                : " .. (self:IsPixelPerfect()
        and "|cff33dd55PIXEL PERFECT|r"
        or  "|cffff4444NOT pixel perfect|r"))
    print(string.format("  Sub-pixel drift       : %s",
        frac < 0.0001
            and "|cff33dd55None — borders will be crisp|r"
            or  string.format("|cffff9933%.4f px drift — source of 1px misalignment|r", frac)))
    if N > 1 then
        print(string.format("  ⚠  N=%d density       : Use multiples of %d for frame sizes (e.g. SetWidth(100) not SetWidth(101))",
            N, N))
    end

    local ei = self:GetElvUIInfo()
    if ei then
        print(string.format("  ElvUI E.uiScale       : |cfffffff0%.6f|r  %s",
            ei.uiScale, ei.scaleOK and "|cff33dd55✓ synced|r" or "|cffff4444✗ mismatch|r"))
        print(string.format("  ElvUI E.mult          : |cfffffff0%.6f|r  (ideal %.6f)  %s",
            ei.mult, ei.idealMult,
            ei.multOK and "|cff33dd55✓ correct|r" or "|cffff4444✗ wrong — use Force Sync|r"))
    else
        print("  ElvUI                 : |cff888888not detected|r")
    end
    print(PREFIX .. "|cff555555/pp help  for all commands|r")
end

-- =============================================================================
-- SLASH COMMANDS
-- =============================================================================

--- Toggle the settings GUI. Defined fully in GUI.lua; stubbed here so Core.lua
--- can reference it from the slash handler before GUI.lua is evaluated.
function PPUI:ToggleGUI()
    self:Log("GUI not yet initialized.")
end

SLASH_PIXELPERFECTUI1 = "/pp"
SLASH_PIXELPERFECTUI2 = "/pixelperfect"

SlashCmdList["PIXELPERFECTUI"] = function(msg)
    local cmd = ((msg or ""):lower():match("^%s*(%S*)") or "")

    if     cmd == "apply"  then PPUI:ApplyScale();                       PPUI:Log("Scale applied.")
    elseif cmd == "reset"  then PPUI:ResetScale();                       PPUI:Log("Scale reset to default.")
    elseif cmd == "sync"   then PPUI:SyncElvUI()
    elseif cmd == "info"   then PPUI:PrintFullInfo()
    elseif cmd == "status" then PPUI:PrintStatus()
    elseif cmd == "toggle" then
        PPUI.db.enabled = not PPUI.db.enabled
        if PPUI.db.enabled then PPUI:ApplyScale() else PPUI:ResetScale() end
        PPUI:Log(PPUI.db.enabled and "Enabled." or "Disabled.")
    elseif cmd == "inspect" then PPUI:ToggleInspector()
    elseif cmd == "grid"    then PPUI:ToggleGrid()
    elseif cmd == "center"  then PPUI:ToggleCenterIndicator()
    elseif cmd == "hguide"  then PPUI:AddHGuide()
    elseif cmd == "vguide"  then PPUI:AddVGuide()
    elseif cmd == "guides"  then
        local sub = (msg:lower():match("%S+%s+(%S+)") or "")
        if sub == "clear" then PPUI:ClearGuides()
        else PPUI:Log("Usage: /pp guides clear") end
    elseif cmd == "help"   then
        print(PREFIX .. "Available commands:")
        print("  |cfffffff0/pp|r              — Open/close the settings window")
        print("  |cfffffff0/pp apply|r         — Apply pixel-perfect scale now")
        print("  |cfffffff0/pp reset|r         — Reset UIParent to WoW default")
        print("  |cfffffff0/pp sync|r          — Force-sync ElvUI E.uiScale and E.mult")
        print("  |cfffffff0/pp toggle|r        — Enable / disable without opening UI")
        print("  |cfffffff0/pp info|r          — Full diagnostic dump to chat")
        print("  |cfffffff0/pp status|r        — One-line status summary")
        print("  |cfffffff0/pp inspect|r       — Toggle frame inspector")
        print("  |cfffffff0/pp grid|r          — Toggle pixel grid overlay")
        print("  |cfffffff0/pp hguide|r        — Add horizontal guide at cursor")
        print("  |cfffffff0/pp vguide|r        — Add vertical guide at cursor")
        print("  |cfffffff0/pp guides clear|r  — Remove all guides")
        print("  |cfffffff0/pp center|r        — Toggle screen centre crosshair")
    else
        PPUI:ToggleGUI()
    end
end
