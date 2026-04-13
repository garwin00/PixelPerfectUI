-- =============================================================================
-- PixelPerfectUI - Alignment.lua
-- Visual alignment aids: pixel grid, draggable guide lines, center crosshair.
--
-- Public API (also exposed on PPUI):
--   AlignTools:ToggleGrid()
--   AlignTools:SetGridSize(px)
--   AlignTools:AddHGuide([px])     -- px from bottom; defaults to cursor Y
--   AlignTools:AddVGuide([px])     -- px from left;   defaults to cursor X
--   AlignTools:ClearGuides()
--   AlignTools:ToggleCenter()
--   AlignTools:RebuildAll()        -- call after scale change
-- =============================================================================

local ADDON_NAME, ns = ...
local PPUI = ns.PPUI

-- =============================================================================
-- THEME
-- =============================================================================

local T = {
    border  = { 0.22, 0.22, 0.25, 1.00 },
    accent  = { 0.49, 0.78, 0.89 },
    dim     = { 0.52, 0.52, 0.55 },
}
local C = {
    good   = "ff33dd55",
    warn   = "ffff9933",
    white  = "ffffffff",
    dim    = "ff888888",
    accent = "ff7ec8e3",
}

-- =============================================================================
-- STATE
-- =============================================================================

local AlignTools   = {}
ns.AlignTools      = AlignTools

local _gridCanvas  = nil    -- parent Frame for grid line objects
local _gridLines   = {}     -- array of Line objects
local _guideFrames = {}     -- array of { data={type,px}, frame, line, label }
local _centerH     = nil    -- center horizontal line
local _centerV     = nil    -- center vertical line
local _centerLabel = nil

-- =============================================================================
-- HELPERS
-- =============================================================================

local function FS(parent, size, flags)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFont("Fonts\\FRIZQT__.TTF", size or 10, flags or "")
    return f
end

-- Convert physical pixels (from screen bottom-left) to UIParent region units.
-- Uses the same formula as PPUI:PixelsToRegionUnits() but always uses UIParent.
local function PxToUnits(px)
    local _, physH = PPUI:GetPhysicalSize()
    local scale    = UIParent:GetEffectiveScale()
    return (px * 768) / (scale * physH)
end

-- Convert UIParent region units back to physical pixels.
local function UnitsToPx(units)
    local _, physH = PPUI:GetPhysicalSize()
    local scale    = UIParent:GetEffectiveScale()
    return (units * scale * physH) / 768
end

-- Snap a pixel value to the nearest N-pixel boundary.
local function SnapPx(px)
    local N = PPUI:GetPixelMultiplier()
    return math.floor(px / N + 0.5) * N
end

-- Ensure db sub-tables exist.
local function EnsureDB()
    if not PPUI.db.guides   then PPUI.db.guides   = {} end
    if not PPUI.db.gridSize then PPUI.db.gridSize  = 32 end
    if PPUI.db.gridEnabled == nil  then PPUI.db.gridEnabled  = false end
    if PPUI.db.gridAlpha   == nil  then PPUI.db.gridAlpha    = 0.15  end
    if PPUI.db.showCenter  == nil  then PPUI.db.showCenter   = false end
end

-- =============================================================================
-- GRID OVERLAY
-- =============================================================================
-- Uses WoW's CreateLine() API (available since 8.2 / Shadowlands).
-- Lines live on a BACKGROUND canvas so they never occlude UI elements.
-- The grid is in physical-pixel intervals converted to region units.

local function TeardownGrid()
    for _, ln in ipairs(_gridLines) do
        ln:Hide()
    end
    _gridLines = {}
end

local function BuildGrid()
    EnsureDB()
    TeardownGrid()

    if not PPUI.db.gridEnabled then return end

    if not _gridCanvas then
        _gridCanvas = CreateFrame("Frame", "PPUIGridCanvas", UIParent)
        _gridCanvas:SetAllPoints(UIParent)
        _gridCanvas:SetFrameStrata("BACKGROUND")
        _gridCanvas:SetFrameLevel(1)
    end

    local gridPx  = math.max(4, PPUI.db.gridSize or 32)
    local alpha   = PPUI.db.gridAlpha or 0.15
    local _, physH = PPUI:GetPhysicalSize()
    local physW    = select(1, PPUI:GetPhysicalSize())
    local screenH  = UIParent:GetHeight()   -- always 768
    local screenW  = UIParent:GetWidth()

    local intervalUnits = PxToUnits(gridPx)

    local function MakeLine(r, g, b, a)
        local ln = _gridCanvas:CreateLine()
        ln:SetThickness(1)
        ln:SetColorTexture(r, g, b, a)
        return ln
    end

    -- Horizontal lines (constant Y, full width)
    local y = intervalUnits
    while y < screenH do
        local ln = MakeLine(T.accent[1], T.accent[2], T.accent[3], alpha)
        ln:SetStartPoint("BOTTOMLEFT", _gridCanvas, 0, y)
        ln:SetEndPoint("BOTTOMRIGHT", _gridCanvas, 0, y)
        _gridLines[#_gridLines + 1] = ln
        y = y + intervalUnits
    end

    -- Vertical lines (constant X, full height)
    local x = intervalUnits
    while x < screenW do
        local ln = MakeLine(T.accent[1], T.accent[2], T.accent[3], alpha)
        ln:SetStartPoint("BOTTOMLEFT", _gridCanvas, x, 0)
        ln:SetEndPoint("TOPLEFT", _gridCanvas, x, 0)
        _gridLines[#_gridLines + 1] = ln
        x = x + intervalUnits
    end
end

function AlignTools:ToggleGrid()
    EnsureDB()
    PPUI.db.gridEnabled = not PPUI.db.gridEnabled
    BuildGrid()
    PPUI:Log(PPUI.db.gridEnabled
        and string.format("Grid ON — %dpx intervals", PPUI.db.gridSize)
        or  "Grid OFF")
end

function AlignTools:SetGridSize(px)
    EnsureDB()
    PPUI.db.gridSize = math.max(4, math.floor(px + 0.5))
    if PPUI.db.gridEnabled then BuildGrid() end
end

function AlignTools:SetGridAlpha(a)
    EnsureDB()
    PPUI.db.gridAlpha = math.max(0.02, math.min(1.0, a))
    if PPUI.db.gridEnabled then BuildGrid() end
end

-- =============================================================================
-- GUIDE LINES
-- =============================================================================
-- Guides are full-screen 1px lines (H or V) that snap to pixel boundaries.
-- Each guide has:
--   • A Frame (hit target, EnableMouse, drag handler)
--   • A thin colored texture drawn inside
--   • A label showing its pixel position (visible on hover)
--
-- Persistence: guide pixel positions are stored in PPUI.db.guides.

local GUIDE_COLOR = { 1.0, 0.55, 0.10, 0.90 }   -- orange
local GUIDE_LOCKED_COLOR = { 0.49, 0.78, 0.89, 0.90 }  -- cyan when snapped

local function RemoveGuideFrame(entry)
    if entry.frame then
        entry.frame:Hide()
        entry.frame:SetScript("OnUpdate", nil)
        entry.frame:SetScript("OnMouseDown", nil)
        entry.frame:SetScript("OnMouseUp", nil)
        entry.frame:SetParent(nil)
    end
end

local function FindGuideEntry(frameRef)
    for i, entry in ipairs(_guideFrames) do
        if entry.frame == frameRef then return i, entry end
    end
end

function AlignTools:RemoveGuide(frameRef)
    local idx, entry = FindGuideEntry(frameRef)
    if not idx then return end
    RemoveGuideFrame(entry)
    table.remove(_guideFrames, idx)
    AlignTools:SaveGuides()
end

function AlignTools:SaveGuides()
    EnsureDB()
    PPUI.db.guides = {}
    for _, entry in ipairs(_guideFrames) do
        PPUI.db.guides[#PPUI.db.guides + 1] = {
            type = entry.data.type,
            px   = entry.data.px,
        }
    end
end

local function PositionGuide(entry)
    local data  = entry.data
    local f     = entry.frame
    local units = PxToUnits(data.px)
    f:ClearAllPoints()
    if data.type == "H" then
        -- Full-width horizontal strip
        f:SetPoint("BOTTOMLEFT",  UIParent, "BOTTOMLEFT",  0, units - 1)
        f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, units - 1)
        f:SetHeight(3)   -- 3-unit hit target centred on the 1px line
    else
        -- Full-height vertical strip
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", units - 1, 0)
        f:SetPoint("TOPLEFT",    UIParent, "TOPLEFT",    units - 1, 0)
        f:SetWidth(3)
    end
    if entry.label then
        local snapped = (data.px == SnapPx(data.px))
        local col = snapped and GUIDE_LOCKED_COLOR or GUIDE_COLOR
        entry.label:SetTextColor(col[1], col[2], col[3], 1)
        entry.label:SetText(data.type .. ": " .. data.px .. "px"
            .. (snapped and "  ✓" or ""))
    end
    if entry.lineTex then
        entry.lineTex:SetColorTexture(
            GUIDE_COLOR[1], GUIDE_COLOR[2], GUIDE_COLOR[3], GUIDE_COLOR[4])
    end
end

local function CreateGuideFrame(data)
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(90)
    f:EnableMouse(true)

    -- Thin colored line texture (1px thick, centered in the hit frame)
    local tex = f:CreateTexture(nil, "OVERLAY")
    if data.type == "H" then
        tex:SetHeight(1)
        tex:SetPoint("LEFT",  f, "LEFT",  0, 0)
        tex:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    else
        tex:SetWidth(1)
        tex:SetPoint("TOP",    f, "TOP",    0, 0)
        tex:SetPoint("BOTTOM", f, "BOTTOM", 0, 0)
    end
    tex:SetColorTexture(GUIDE_COLOR[1], GUIDE_COLOR[2], GUIDE_COLOR[3], GUIDE_COLOR[4])

    -- Position label (shows on hover, always slightly offset from the line)
    local lbl = f:CreateFontString(nil, "OVERLAY")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    lbl:SetTextColor(1, 0.9, 0.6, 1)
    lbl:SetAlpha(0)   -- hidden until hover
    if data.type == "H" then
        lbl:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 4, 2)
    else
        lbl:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 2, 4)
    end

    local entry = { data = data, frame = f, lineTex = tex, label = lbl }

    f:SetScript("OnEnter", function() lbl:SetAlpha(1) end)
    f:SetScript("OnLeave", function() lbl:SetAlpha(0) end)

    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then
            self._dragging = true
        end
    end)

    f:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" then
            self._dragging = false
            data.px = self._currentPx or data.px
            AlignTools:SaveGuides()
        elseif btn == "RightButton" then
            AlignTools:RemoveGuide(self)
        end
    end)

    f:SetScript("OnUpdate", function(self)
        if not self._dragging then return end
        local cx, cy = GetCursorPosition()
        local rawPx = data.type == "H" and cy or cx
        local px    = SnapPx(math.floor(rawPx + 0.5))
        if px ~= data.px then
            data.px        = px
            self._currentPx = px
            PositionGuide(entry)
        end
    end)

    PositionGuide(entry)
    return entry
end

function AlignTools:AddHGuide(px)
    EnsureDB()
    if not px then
        local _, cy = GetCursorPosition()
        px = SnapPx(math.floor(cy + 0.5))
    end
    local data  = { type = "H", px = px }
    local entry = CreateGuideFrame(data)
    _guideFrames[#_guideFrames + 1] = entry
    AlignTools:SaveGuides()
    return entry
end

function AlignTools:AddVGuide(px)
    EnsureDB()
    if not px then
        local cx = GetCursorPosition()
        px = SnapPx(math.floor(cx + 0.5))
    end
    local data  = { type = "V", px = px }
    local entry = CreateGuideFrame(data)
    _guideFrames[#_guideFrames + 1] = entry
    AlignTools:SaveGuides()
    return entry
end

function AlignTools:ClearGuides()
    for _, entry in ipairs(_guideFrames) do
        RemoveGuideFrame(entry)
    end
    _guideFrames = {}
    AlignTools:SaveGuides()
    PPUI:Log("All guides cleared.")
end

-- Rebuild guides from saved db (called on login and after scale change)
function AlignTools:RebuildGuides()
    for _, entry in ipairs(_guideFrames) do
        RemoveGuideFrame(entry)
    end
    _guideFrames = {}
    EnsureDB()
    for _, saved in ipairs(PPUI.db.guides) do
        if saved.type == "H" then
            AlignTools:AddHGuide(saved.px)
        else
            AlignTools:AddVGuide(saved.px)
        end
    end
end

-- Reposition all existing guides after a scale change (px values are stable,
-- but the region-unit positions need recalculating).
function AlignTools:RefreshGuides()
    for _, entry in ipairs(_guideFrames) do
        PositionGuide(entry)
    end
end

-- =============================================================================
-- SCREEN CENTER INDICATOR
-- =============================================================================
-- Two full-screen lines (H + V) meeting at the exact physical screen centre.
-- Uses CreateLine() for pixel-accuracy.

local function BuildCenterIndicator()
    if not _centerH then
        local canvas = CreateFrame("Frame", "PPUICenterCanvas", UIParent)
        canvas:SetAllPoints(UIParent)
        canvas:SetFrameStrata("BACKGROUND")
        canvas:SetFrameLevel(2)

        _centerH = canvas:CreateLine()
        _centerH:SetThickness(1)
        _centerH:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.60)

        _centerV = canvas:CreateLine()
        _centerV:SetThickness(1)
        _centerV:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.60)

        _centerLabel = canvas:CreateFontString(nil, "OVERLAY")
        _centerLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        _centerLabel:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 0.85)
    end

    local physW, physH = PPUI:GetPhysicalSize()
    local cxPx = physW / 2
    local cyPx = physH / 2
    local cx   = PxToUnits(cxPx)
    local cy   = PxToUnits(cyPx)
    local sw   = UIParent:GetWidth()
    local sh   = UIParent:GetHeight()

    -- Horizontal centre line
    _centerH:SetStartPoint("BOTTOMLEFT", UIParent, 0, cy)
    _centerH:SetEndPoint("BOTTOMRIGHT",  UIParent, 0, cy)

    -- Vertical centre line
    _centerV:SetStartPoint("BOTTOMLEFT", UIParent, cx, 0)
    _centerV:SetEndPoint("TOPLEFT",      UIParent, cx, 0)

    -- Label at centre
    _centerLabel:ClearAllPoints()
    _centerLabel:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx + 2, cy + 2)
    _centerLabel:SetText(string.format("centre  %d × %d px", cxPx, cyPx))

    local show = PPUI.db.showCenter
    _centerH:SetShown(show)
    _centerV:SetShown(show)
    _centerLabel:SetShown(show)
end

function AlignTools:ToggleCenter()
    EnsureDB()
    PPUI.db.showCenter = not PPUI.db.showCenter
    BuildCenterIndicator()
    PPUI:Log(PPUI.db.showCenter and "Centre indicator ON" or "Centre indicator OFF")
end

-- =============================================================================
-- REBUILD ALL  (call after scale / display changes)
-- =============================================================================

function AlignTools:RebuildAll()
    BuildGrid()
    AlignTools:RefreshGuides()
    BuildCenterIndicator()
end

-- =============================================================================
-- INIT  (called by PLAYER_LOGIN in Core.lua via PPUI:InitAlignment)
-- =============================================================================

function AlignTools:Init()
    EnsureDB()
    AlignTools:RebuildGuides()
    BuildGrid()
    BuildCenterIndicator()
end

-- Expose on PPUI for slash commands and GUI buttons
function PPUI:ToggleGrid()           ns.AlignTools:ToggleGrid()       end
function PPUI:ToggleCenterIndicator() ns.AlignTools:ToggleCenter()    end
function PPUI:AddHGuide(px)          ns.AlignTools:AddHGuide(px)      end
function PPUI:AddVGuide(px)          ns.AlignTools:AddVGuide(px)      end
function PPUI:ClearGuides()          ns.AlignTools:ClearGuides()      end
function PPUI:GetAlignTools()        return ns.AlignTools             end
