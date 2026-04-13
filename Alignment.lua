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

-- Ensure db sub-tables exist.
local function EnsureDB()
    if not PPUI.db then return end   -- guard: called before PLAYER_LOGIN in edge cases
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
    -- NOTE: intentionally keep _gridLines populated so BuildGrid can reuse them.
    -- WoW Line objects cannot be destroyed; reusing avoids unbounded accumulation.
end

local _gridLinesUsed = 0   -- how many entries in _gridLines are live this pass

local function BuildGrid()
    EnsureDB()
    TeardownGrid()

    if not PPUI.db.gridEnabled then _gridLinesUsed = 0; return end

    if not _gridCanvas then
        _gridCanvas = CreateFrame("Frame", "PPUIGridCanvas", UIParent)
        _gridCanvas:SetAllPoints(UIParent)
        _gridCanvas:SetFrameStrata("BACKGROUND")
        _gridCanvas:SetFrameLevel(1)
    end

    local gridPx  = math.max(4, PPUI.db.gridSize or 32)
    local alpha   = PPUI.db.gridAlpha or 0.15
    local physW, physH = PPUI:GetPhysicalSize()
    local screenH = UIParent:GetHeight()   -- always 768
    local screenW = UIParent:GetWidth()

    local intervalUnits = PxToUnits(gridPx)
    if intervalUnits <= 0 then return end   -- guard: avoid infinite loop

    local poolIdx = 0

    local function GetOrMakeLine()
        poolIdx = poolIdx + 1
        if _gridLines[poolIdx] then
            _gridLines[poolIdx]:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], alpha)
            _gridLines[poolIdx]:Show()
            return _gridLines[poolIdx]
        end
        local ln = _gridCanvas:CreateLine()
        ln:SetThickness(1)
        ln:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], alpha)
        _gridLines[poolIdx] = ln
        return ln
    end

    -- Horizontal lines (constant Y, full width)
    local y = intervalUnits
    while y < screenH do
        local ln = GetOrMakeLine()
        ln:SetStartPoint("BOTTOMLEFT", _gridCanvas, 0, y)
        ln:SetEndPoint("BOTTOMRIGHT", _gridCanvas, 0, y)
        y = y + intervalUnits
    end

    -- Vertical lines (constant X, full height)
    local x = intervalUnits
    while x < screenW do
        local ln = GetOrMakeLine()
        ln:SetStartPoint("BOTTOMLEFT", _gridCanvas, x, 0)
        ln:SetEndPoint("TOPLEFT", _gridCanvas, x, 0)
        x = x + intervalUnits
    end

    _gridLinesUsed = poolIdx
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
-- Each guide consists of two frames:
--   1. Guide frame  — full-screen strip (hit target + 1px line texture)
--   2. Handle badge — small pill anchored at the screen centre of the guide's
--                     axis; shows pixel position + drag-direction arrow.
--                     This is the primary visual affordance.
--
-- Dragging snaps to the nearest individual physical pixel (not N-boundaries).
-- Persistence: guide pixel positions are stored in PPUI.db.guides.

local GUIDE_COL     = { 1.00, 0.55, 0.10, 0.90 }   -- orange
local GUIDE_COL_HOV = { 1.00, 0.75, 0.30, 1.00 }   -- brighter orange on hover

-- Handle badge dimensions (region units).
-- At 4K/scale=0.7111: 1 unit ≈ 2px, so these are ~100×22 physical pixels.
local HANDLE_LONG = 52
local HANDLE_THIN = 11

local function SetGuideHighlight(entry, on)
    local c = on and GUIDE_COL_HOV or GUIDE_COL
    if entry.lineTex then
        entry.lineTex:SetColorTexture(c[1], c[2], c[3], c[4])
    end
    if entry.handle then
        entry.handle:SetBackdropBorderColor(c[1], c[2], c[3], on and 1.0 or 0.85)
        entry.handle:SetBackdropColor(0.05, 0.05, 0.07, on and 0.97 or 0.88)
    end
end

local function RemoveGuideFrame(entry)
    if entry.frame then
        entry.frame:SetScript("OnUpdate",    nil)
        entry.frame:SetScript("OnMouseDown", nil)
        entry.frame:SetScript("OnMouseUp",   nil)
        entry.frame:SetScript("OnEnter",     nil)
        entry.frame:SetScript("OnLeave",     nil)
        entry.frame:Hide()
        entry.frame:SetParent(nil)
    end
    if entry.handle then
        entry.handle:SetScript("OnMouseDown", nil)
        entry.handle:SetScript("OnMouseUp",   nil)
        entry.handle:SetScript("OnEnter",     nil)
        entry.handle:SetScript("OnLeave",     nil)
        entry.handle:Hide()
        entry.handle:SetParent(nil)
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
    local units = PxToUnits(data.px)

    -- Guide line frame (full-screen strip)
    entry.frame:ClearAllPoints()
    if data.type == "H" then
        entry.frame:SetPoint("BOTTOMLEFT",  UIParent, "BOTTOMLEFT",  0, units - 1)
        entry.frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, units - 1)
        entry.frame:SetHeight(3)
    else
        entry.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", units - 1, 0)
        entry.frame:SetPoint("TOPLEFT",    UIParent, "TOPLEFT",    units - 1, 0)
        entry.frame:SetWidth(3)
    end

    -- Handle badge: sits on the guide, centred on the perpendicular axis
    if entry.handle then
        entry.handle:ClearAllPoints()
        if data.type == "H" then
            entry.handle:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
                UIParent:GetWidth() / 2, units)
        else
            entry.handle:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
                units, UIParent:GetHeight() / 2)
        end
    end

    -- Update position label in handle
    if entry.handleLbl then
        entry.handleLbl:SetText(data.px .. " px")
    end
end

local function CreateGuideFrame(data)
    -- ── 1. Full-screen guide line + hit area ─────────────────────────────
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(90)
    f:EnableMouse(true)

    local lineTex = f:CreateTexture(nil, "OVERLAY")
    if data.type == "H" then
        lineTex:SetHeight(1)
        lineTex:SetPoint("LEFT",  f, "LEFT",  0, 0)
        lineTex:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    else
        lineTex:SetWidth(1)
        lineTex:SetPoint("TOP",    f, "TOP",    0, 0)
        lineTex:SetPoint("BOTTOM", f, "BOTTOM", 0, 0)
    end
    lineTex:SetColorTexture(GUIDE_COL[1], GUIDE_COL[2], GUIDE_COL[3], GUIDE_COL[4])

    -- ── 2. Handle badge (grab handle, centred on screen) ─────────────────
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("HIGH")
    handle:SetFrameLevel(95)   -- above guide line
    handle:EnableMouse(true)

    if data.type == "H" then
        handle:SetSize(HANDLE_LONG, HANDLE_THIN)
    else
        handle:SetSize(HANDLE_THIN, HANDLE_LONG)
    end

    handle:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    handle:SetBackdropColor(0.05, 0.05, 0.07, 0.88)
    handle:SetBackdropBorderColor(GUIDE_COL[1], GUIDE_COL[2], GUIDE_COL[3], 0.85)

    -- Drag-direction arrow
    local arrowFS = handle:CreateFontString(nil, "OVERLAY")
    arrowFS:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    arrowFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 0.90)

    -- Pixel position label
    local lblFS = handle:CreateFontString(nil, "OVERLAY")
    lblFS:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    lblFS:SetTextColor(1, 0.85, 0.45, 1)

    if data.type == "H" then
        -- Horizontal guide: handle is wide, items sit side by side
        arrowFS:SetPoint("LEFT", handle, "LEFT", 3, 0)
        arrowFS:SetText("↕")
        lblFS:SetPoint("LEFT",   arrowFS, "RIGHT", 3, 0)
    else
        -- Vertical guide: handle is tall, items stack vertically
        arrowFS:SetPoint("TOP",  handle, "TOP",  0, -2)
        arrowFS:SetText("↔")
        lblFS:SetPoint("TOP",    arrowFS, "BOTTOM", 0, -1)
    end

    local entry = {
        data      = data,
        frame     = f,
        lineTex   = lineTex,
        handle    = handle,
        handleLbl = lblFS,
    }

    -- ── Drag logic (OnUpdate on guide frame only; handle delegates) ───────
    -- Snaps to nearest individual physical pixel.
    -- _dragOffset: difference between cursor position and guide position at
    -- the moment dragging begins, so the guide doesn't jump to cursor on click.

    f:SetScript("OnUpdate", function(self)
        if not self._dragging then return end
        local cx, cy = GetCursorPosition()
        local rawPx  = data.type == "H" and cy or cx
        local px     = math.floor((rawPx - (self._dragOffset or 0)) + 0.5)
        if px ~= data.px then
            data.px = px
            PositionGuide(entry)
        end
    end)

    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then
            local cx, cy = GetCursorPosition()
            local rawPx  = data.type == "H" and cy or cx
            self._dragOffset = rawPx - data.px
            self._dragging   = true
            SetGuideHighlight(entry, true)
        end
    end)

    f:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" then
            self._dragging = false
            SetGuideHighlight(entry, not f._dragging)
            AlignTools:SaveGuides()
        elseif btn == "RightButton" then
            AlignTools:RemoveGuide(self)
        end
    end)

    f:SetScript("OnEnter", function() SetGuideHighlight(entry, true) end)
    f:SetScript("OnLeave", function()
        if not f._dragging then SetGuideHighlight(entry, false) end
    end)

    -- Handle delegates drag state to guide frame (single OnUpdate)
    handle:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then
            local cx, cy = GetCursorPosition()
            local rawPx  = data.type == "H" and cy or cx
            f._dragOffset = rawPx - data.px
            f._dragging   = true
            SetGuideHighlight(entry, true)
        end
    end)

    handle:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" then
            f._dragging = false
            SetGuideHighlight(entry, false)
            AlignTools:SaveGuides()
        elseif btn == "RightButton" then
            AlignTools:RemoveGuide(f)
        end
    end)

    handle:SetScript("OnEnter", function() SetGuideHighlight(entry, true) end)
    handle:SetScript("OnLeave", function()
        if not f._dragging then SetGuideHighlight(entry, false) end
    end)

    PositionGuide(entry)
    return entry
end

function AlignTools:AddHGuide(px)
    EnsureDB()
    if not px then
        local _, cy = GetCursorPosition()
        px = math.floor(cy + 0.5)
    end
    local entry = CreateGuideFrame({ type = "H", px = px })
    _guideFrames[#_guideFrames + 1] = entry
    AlignTools:SaveGuides()
    return entry
end

function AlignTools:AddVGuide(px)
    EnsureDB()
    if not px then
        local cx = GetCursorPosition()
        px = math.floor(cx + 0.5)
    end
    local entry = CreateGuideFrame({ type = "V", px = px })
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
