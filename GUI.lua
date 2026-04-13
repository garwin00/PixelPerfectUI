-- =============================================================================
-- PixelPerfectUI - GUI.lua
-- Settings window + minimap button
-- =============================================================================

local ADDON_NAME, ns    = ...
local PPUI              = ns.PPUI
local GetCVarSafe       = ns.GetCVarSafe
local atan2             = ns.atan2

-- =============================================================================
-- THEME
-- =============================================================================

local T = {
    bg        = { 0.08, 0.08, 0.09, 0.97 },
    hdrBg     = { 0.05, 0.05, 0.06, 1.00 },
    tabBg     = { 0.06, 0.06, 0.07, 1.00 },
    border    = { 0.22, 0.22, 0.25, 1.00 },
    accent    = { 0.49, 0.78, 0.89 },   -- #7EC8E3 — blue
    good      = { 0.20, 0.84, 0.40 },   -- green
    warn      = { 1.00, 0.62, 0.12 },   -- orange
    bad       = { 0.88, 0.24, 0.24 },   -- red
    text      = { 0.90, 0.90, 0.90 },
    dim       = { 0.52, 0.52, 0.55 },
    white     = { 1.00, 1.00, 1.00 },
}

-- Color hex strings for use in WoW markup  (|cAARRGGBB)
local C = {
    good    = "ff33dd55",
    warn    = "ffff9933",
    bad     = "ffdd3333",
    white   = "ffffffff",
    dim     = "ff888888",
    accent  = "ff7ec8e3",
}

-- Layout constants
local WIN_W       = 480
local WIN_H       = 444
local HDR_H       = 38
local TAB_H       = 28
local BOT_H       = 34
local PAD         = 12
local ROW_H       = 18
local GAP         = 10

-- =============================================================================
-- WIDGET HELPERS
-- =============================================================================

local function NewBackdrop(parent, name)
    return CreateFrame("Frame", name, parent, "BackdropTemplate")
end

local function SetBD(f, bgR, bgG, bgB, bgA, brR, brG, brB, brA)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(bgR, bgG, bgB, bgA or 1)
    f:SetBackdropBorderColor(
        brR or T.border[1], brG or T.border[2],
        brB or T.border[3], brA or T.border[4])
end

local function FS(parent, size, flags)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFont("Fonts\\FRIZQT__.TTF", size or 12, flags or "")
    return f
end

local function HLine(parent, yOfs)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetHeight(1)
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",  PAD,  yOfs)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, yOfs)
    t:SetColorTexture(T.border[1], T.border[2], T.border[3], 0.8)
    return t
end

local function SectionTitle(parent, text, yOfs)
    local fs = FS(parent, 10)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD + 2, yOfs)
    fs:SetText(text:upper())
    fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    return fs
end

local function RowLabel(parent, text, yOfs)
    local fs = FS(parent, 11)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD + 4, yOfs)
    fs:SetText(text)
    fs:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
    return fs
end

local function RowValue(parent, yOfs)
    local fs = FS(parent, 11)
    fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(PAD + 4), yOfs)
    fs:SetJustifyH("RIGHT")
    return fs
end

--- Checkbox. xOfs/yOfs are offsets from parent TOPLEFT.
local function MakeCheckbox(parent, text, xOfs, yOfs)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", xOfs, yOfs)
    local lbl = FS(cb, 12)
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetText(text)
    lbl:SetTextColor(T.text[1], T.text[2], T.text[3])
    cb._lbl = lbl
    return cb
end

local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 110, h or 22)
    b:SetText(text)
    return b
end

local function MakeSlider(parent)
    local f = CreateFrame("Slider", nil, parent)
    f:SetOrientation("HORIZONTAL")
    f:SetMinMaxValues(0.20, 1.20)
    f:SetValueStep(0.0001)
    f:SetObeyStepOnDrag(true)
    f:SetHeight(16)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    bg:SetPoint("LEFT",  f, "LEFT",  4, 0)
    bg:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    bg:SetHeight(8)

    f:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    f:GetThumbTexture():SetSize(16, 16)

    f._enabled = true
    function f:SetSliderEnabled(state)
        f._enabled = state
        f:SetAlpha(state and 1.0 or 0.35)
    end

    return f
end

-- =============================================================================
-- TAB SYSTEM
-- =============================================================================

--- Build a simple tab bar. Returns an ActivateTab(idx) function.
local function BuildTabs(win, tabBar, pages, labels)
    local TAB_W = math.floor(WIN_W / #labels)
    local tabs  = {}

    local function ActivateTab(idx)
        for i, t in ipairs(tabs) do
            local active = (i == idx)
            t._ul:SetShown(active)
            t._lbl:SetTextColor(
                active and T.accent[1] or T.dim[1],
                active and T.accent[2] or T.dim[2],
                active and T.accent[3] or T.dim[3])
            pages[i]:SetShown(active)
        end
        win._activeTab = idx
    end

    for i, label in ipairs(labels) do
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetSize(TAB_W, TAB_H)
        btn:SetPoint("TOPLEFT", tabBar, "TOPLEFT", (i - 1) * TAB_W, 0)

        local lbl = FS(btn, 11)
        lbl:SetPoint("CENTER", btn, "CENTER", 0, 1)
        lbl:SetText(label)
        lbl:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        btn._lbl = lbl

        local ul = btn:CreateTexture(nil, "OVERLAY")
        ul:SetHeight(2)
        ul:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  6, 1)
        ul:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -6, 1)
        ul:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
        ul:Hide()
        btn._ul = ul

        local idx = i
        btn:SetScript("OnClick", function() ActivateTab(idx) end)
        tabs[i] = btn
    end

    ActivateTab(1)
    return ActivateTab
end

-- =============================================================================
-- MAIN WINDOW
-- =============================================================================

function PPUI:CreateGUI()
    if self.GUI then return end

    -- ── Outer window ─────────────────────────────────────────────────────────
    local win = NewBackdrop(UIParent, "PixelPerfectUIWindow")
    win:SetSize(WIN_W, WIN_H)
    win:SetFrameStrata("HIGH")
    win:SetFrameLevel(100)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetClampedToScreen(true)
    SetBD(win, T.bg[1], T.bg[2], T.bg[3], T.bg[4])

    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", function(w)
        w:StopMovingOrSizing()
        PPUI.db.windowX = w:GetLeft()
        PPUI.db.windowY = w:GetTop() - UIParent:GetHeight()
    end)

    if self.db.windowX then
        win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", self.db.windowX, self.db.windowY)
    else
        win:SetPoint("CENTER")
    end
    win:Hide()

    -- ── Header ───────────────────────────────────────────────────────────────
    local hdr = NewBackdrop(win)
    hdr:SetHeight(HDR_H)
    hdr:SetPoint("TOPLEFT")
    hdr:SetPoint("TOPRIGHT")
    SetBD(hdr, T.hdrBg[1], T.hdrBg[2], T.hdrBg[3], T.hdrBg[4], 0, 0, 0, 0)

    local titleFS = FS(hdr, 14, "OUTLINE")
    titleFS:SetPoint("LEFT", hdr, "LEFT", PAD, 0)
    titleFS:SetText("|cff7ec8e3Pixel|r|cffffffffPerfect|r|cffaaaaaaUI|r")

    -- Version sits to the right of the title, well clear of the close button
    local verFS = FS(hdr, 10)
    verFS:SetPoint("LEFT", titleFS, "RIGHT", 8, -1)
    verFS:SetText("v" .. PPUI.version)
    verFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])

    local closeBtn = CreateFrame("Button", nil, hdr, "UIPanelCloseButton")
    closeBtn:SetSize(26, 26)
    closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -2, 0)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- ── Tab bar ───────────────────────────────────────────────────────────────
    local tabBar = NewBackdrop(win)
    tabBar:SetHeight(TAB_H)
    tabBar:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, -HDR_H)
    tabBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -HDR_H)
    SetBD(tabBar, T.tabBg[1], T.tabBg[2], T.tabBg[3], 1, 0, 0, 0, 0)

    -- ── Content pages ────────────────────────────────────────────────────────
    local CONTENT_TOP = -(HDR_H + TAB_H + 4)
    local CONTENT_BOT = BOT_H + 2

    local function MakePage()
        local p = CreateFrame("Frame", nil, win)
        p:SetPoint("TOPLEFT",     win, "TOPLEFT",     0, CONTENT_TOP)
        p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 0, CONTENT_BOT)
        p:Hide()
        return p
    end

    local pageScale = MakePage()
    local pageElvUI = MakePage()
    local pageTools = MakePage()
    local pageDiag  = MakePage()

    BuildTabs(win, tabBar,
        { pageScale, pageElvUI, pageTools, pageDiag },
        { "Scale", "ElvUI", "Tools", "Diagnostics" })

    -- =========================================================================
    -- TAB 1 — SCALE
    -- =========================================================================
    do
        local p = pageScale
        local Y = -8

        -- Big status indicator
        local statusDot = p:CreateTexture(nil, "ARTWORK")
        statusDot:SetSize(10, 10)
        statusDot:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y - 4)
        statusDot:SetColorTexture(T.bad[1], T.bad[2], T.bad[3], 1)

        local statusFS = FS(p, 13, "OUTLINE")
        statusFS:SetPoint("LEFT", statusDot, "RIGHT", 6, 1)
        win._statusDot = statusDot
        win._statusFS  = statusFS
        Y = Y - 22

        win._vPhysRes = RowValue(p, Y); RowLabel(p, "Physical Resolution",    Y); Y = Y - ROW_H
        win._vAspect  = RowValue(p, Y); RowLabel(p, "Aspect Ratio",            Y); Y = Y - ROW_H
        win._vScale   = RowValue(p, Y); RowLabel(p, "UIParent Scale",          Y); Y = Y - ROW_H
        win._vTarget  = RowValue(p, Y); RowLabel(p, "Pixel-Perfect Target",    Y); Y = Y - ROW_H
        win._vPixelU  = RowValue(p, Y); RowLabel(p, "1 Pixel (region units)",  Y); Y = Y - ROW_H

        Y = Y - 4;  HLine(p, Y);  Y = Y - GAP
        SectionTitle(p, "Scale Controls", Y);  Y = Y - 20

        local cbEnable = MakeCheckbox(p, "Enable Pixel Perfect Mode", PAD + 2, Y)
        cbEnable:SetScript("OnClick", function(self)
            PPUI.db.enabled = self:GetChecked()
            if PPUI.db.enabled then PPUI:ApplyScale() else PPUI:ResetScale() end
            win:Refresh()
        end)
        win._cbEnable = cbEnable;  Y = Y - 24

        local cbAuto = MakeCheckbox(p, "Auto-apply on login and display changes", PAD + 2, Y)
        cbAuto:SetScript("OnClick", function(self) PPUI.db.autoApply = self:GetChecked() end)
        win._cbAuto = cbAuto;  Y = Y - 24

        local cbManual = MakeCheckbox(p, "Override with manual scale value", PAD + 2, Y)
        cbManual:SetScript("OnClick", function(self)
            PPUI.db.useManualScale = self:GetChecked()
            win._slider:SetSliderEnabled(self:GetChecked())
            if PPUI.db.enabled then PPUI:ApplyScale() end
            win:Refresh()
        end)
        win._cbManual = cbManual;  Y = Y - 28

        RowLabel(p, "Manual Scale:", Y)
        win._sliderValFS = RowValue(p, Y);  Y = Y - ROW_H

        local slider = MakeSlider(p)
        slider:SetPoint("TOPLEFT",  p, "TOPLEFT",  PAD + 2, Y)
        slider:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(PAD + 2), Y)
        slider:SetScript("OnValueChanged", function(self, val)
            PPUI.db.manualScale = val
            win._sliderValFS:SetText(string.format("|c%s%.4f|r", C.white, val))
            if self._enabled and PPUI.db.enabled and PPUI.db.useManualScale
                    and not win._refreshing then
                PPUI:ApplyScale(val)
            end
        end)
        win._slider = slider;  Y = Y - 22

        win._optimalHintFS = FS(p, 10)
        win._optimalHintFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        win._optimalHintFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        Y = Y - 16

        -- Button row
        local btnApply = MakeButton(p, "Apply Now", 108, 22)
        btnApply:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, Y)
        btnApply:SetScript("OnClick", function()
            PPUI:ApplyScale(); PPUI:Log("Scale applied."); win:Refresh()
        end)

        local btnOptimal = MakeButton(p, "Set Optimal", 108, 22)
        btnOptimal:SetPoint("LEFT", btnApply, "RIGHT", 6, 0)
        btnOptimal:SetScript("OnClick", function()
            PPUI.db.useManualScale = false
            win._cbManual:SetChecked(false)
            win._slider:SetSliderEnabled(false)
            PPUI:ApplyScale()
            win:Refresh()
            PPUI:Log(string.format("Optimal scale %.6f applied.", PPUI:GetPixelPerfectScale()))
        end)

        local btnReset = MakeButton(p, "Reset Default", 108, 22)
        btnReset:SetPoint("LEFT", btnOptimal, "RIGHT", 6, 0)
        btnReset:SetScript("OnClick", function()
            PPUI.db.enabled = false
            win._cbEnable:SetChecked(false)
            PPUI:ResetScale()
            win:Refresh()
            PPUI:Log("Scale reset to WoW default.")
        end)
    end

    -- =========================================================================
    -- TAB 2 — ELVUI
    -- =========================================================================
    do
        local p = pageElvUI
        local Y = -8

        win._elvStatusFS = FS(p, 11)
        win._elvStatusFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        Y = Y - ROW_H

        win._vElvScale = RowValue(p, Y); RowLabel(p, "E.uiScale",       Y); Y = Y - ROW_H
        win._vElvMult  = RowValue(p, Y); RowLabel(p, "E.mult",          Y); Y = Y - ROW_H
        win._vElvIdeal = RowValue(p, Y); RowLabel(p, "E.mult (ideal)",  Y); Y = Y - ROW_H
        win._vElvMatch = RowValue(p, Y); RowLabel(p, "Sync status",     Y); Y = Y - ROW_H + 2

        local elvNoteFS = FS(p, 10)
        elvNoteFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        elvNoteFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        elvNoteFS:SetText("E.mult drives 1px borders and padding — wrong value = blurry edges and gaps")
        Y = Y - 22

        HLine(p, Y);  Y = Y - GAP

        local cbHook = MakeCheckbox(p, "Hook UpdateUIScale (prevent ElvUI overriding scale)", PAD + 2, Y)
        cbHook:SetScript("OnClick", function(self)
            PPUI.db.hookElvUI = self:GetChecked()
            if PPUI.db.hookElvUI then PPUI:HookElvUI() end
        end)
        win._cbHookElvUI = cbHook;  Y = Y - 30

        local btnSync = MakeButton(p, "Force Sync ElvUI", 148, 22)
        btnSync:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, Y)
        btnSync:SetScript("OnClick", function()
            PPUI:SyncElvUI(); win:Refresh()
        end)
        win._btnSync = btnSync

        local btnReload = MakeButton(p, "ReloadUI", 90, 22)
        btnReload:SetPoint("LEFT", btnSync, "RIGHT", 6, 0)
        btnReload:SetScript("OnClick", ReloadUI)
        Y = Y - 30

        local elvHintFS = FS(p, 10)
        elvHintFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        elvHintFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        elvHintFS:SetText("A ReloadUI is sometimes needed after syncing to repaint all borders correctly.")
    end

    -- =========================================================================
    -- TAB 3 — TOOLS
    -- =========================================================================
    do
        local p = pageTools
        local Y = -8

        SectionTitle(p, "Pixel Grid", Y);  Y = Y - 20

        -- Checkbox on the left; interval label + size buttons on the right
        local cbGrid = MakeCheckbox(p, "Enable grid overlay", PAD + 2, Y)
        cbGrid:SetScript("OnClick", function(self)
            PPUI:ToggleGrid()
            self:SetChecked(PPUI.db.gridEnabled)
        end)
        win._cbGrid = cbGrid

        local gridSizeFS = FS(p, 11)
        gridSizeFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 178, Y + 1)
        gridSizeFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        gridSizeFS:SetText("Interval:")

        local gridX = PAD + 234
        for _, sz in ipairs({ 8, 16, 32, 64 }) do
            local gb = MakeButton(p, tostring(sz), 32, 18)
            gb:SetPoint("TOPLEFT", p, "TOPLEFT", gridX, Y + 1)
            local szCapture = sz
            gb:SetScript("OnClick", function()
                PPUI.db.gridSize = szCapture
                -- force a rebuild if the grid is currently on
                if PPUI.db.gridEnabled then PPUI:ToggleGrid(); PPUI:ToggleGrid() end
            end)
            gridX = gridX + 36
        end

        Y = Y - 26;  HLine(p, Y);  Y = Y - GAP
        SectionTitle(p, "Guide Lines", Y);  Y = Y - 20

        local btnHGuide = MakeButton(p, "Add H Guide", 108, 22)
        btnHGuide:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, Y)
        btnHGuide:SetScript("OnClick", function() PPUI:AddHGuide() end)

        local btnVGuide = MakeButton(p, "Add V Guide", 108, 22)
        btnVGuide:SetPoint("LEFT", btnHGuide, "RIGHT", 6, 0)
        btnVGuide:SetScript("OnClick", function() PPUI:AddVGuide() end)

        local btnClearGuides = MakeButton(p, "Clear All", 90, 22)
        btnClearGuides:SetPoint("LEFT", btnVGuide, "RIGHT", 6, 0)
        btnClearGuides:SetScript("OnClick", function() PPUI:ClearGuides() end)

        Y = Y - 14

        local guideHintFS = FS(p, 10)
        guideHintFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        guideHintFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        guideHintFS:SetText("Drag to reposition  ·  right-click to remove  ·  /pp hguide  /pp vguide")
        Y = Y - 22

        HLine(p, Y);  Y = Y - GAP
        SectionTitle(p, "Other", Y);  Y = Y - 20

        local cbCenter = MakeCheckbox(p, "Screen centre crosshair", PAD + 2, Y)
        cbCenter:SetScript("OnClick", function(self)
            PPUI:ToggleCenterIndicator()
            self:SetChecked(PPUI.db.showCenter)
        end)
        win._cbCenter = cbCenter;  Y = Y - 30

        local btnInspect = MakeButton(p, "Open Frame Inspector", 160, 22)
        btnInspect:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, Y)
        btnInspect:SetScript("OnClick", function() PPUI:ToggleInspector() end)

        local inspHintFS = FS(p, 10)
        inspHintFS:SetPoint("LEFT", btnInspect, "RIGHT", 8, 0)
        inspHintFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        inspHintFS:SetText("or  /pp inspect")
    end

    -- =========================================================================
    -- TAB 4 — DIAGNOSTICS
    -- =========================================================================
    do
        local p = pageDiag
        local Y = -8

        SectionTitle(p, "Scale Diagnostics", Y);  Y = Y - 20

        win._vCvarScale = RowValue(p, Y); RowLabel(p, "uiScale CVar",         Y); Y = Y - ROW_H
        win._vCvarUse   = RowValue(p, Y); RowLabel(p, "useUiScale CVar",      Y); Y = Y - ROW_H
        win._vEffScale  = RowValue(p, Y); RowLabel(p, "Effective Scale",      Y); Y = Y - ROW_H
        win._vDensity   = RowValue(p, Y); RowLabel(p, "Pixel Density (N)",    Y); Y = Y - ROW_H
        win._vPxPerU    = RowValue(p, Y); RowLabel(p, "Pixels per unit",      Y); Y = Y - ROW_H
        win._vDrift     = RowValue(p, Y); RowLabel(p, "Sub-pixel drift",      Y); Y = Y - ROW_H
        win._vBypass    = RowValue(p, Y); RowLabel(p, "CVar bypass needed",   Y); Y = Y - ROW_H

        Y = Y - 6;  HLine(p, Y);  Y = Y - GAP
        SectionTitle(p, "Pixel Snap Calculator", Y);  Y = Y - 20

        local snapLabelFS = FS(p, 11)
        snapLabelFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        snapLabelFS:SetText("Region units:")
        snapLabelFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])

        local snapEB = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
        snapEB:SetSize(76, 22)
        snapEB:SetPoint("LEFT", snapLabelFS, "RIGHT", 8, -1)
        snapEB:SetAutoFocus(false)
        snapEB:SetMaxLetters(10)
        snapEB:SetText("100")
        snapEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        snapEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        local snapBtn = MakeButton(p, "Snap", 52, 22)
        snapBtn:SetPoint("LEFT", snapEB, "RIGHT", 8, 0)

        local snapResFS = FS(p, 11)
        snapResFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y - 24)
        win._snapResFS = snapResFS

        snapBtn:SetScript("OnClick", function()
            local v = tonumber(snapEB:GetText())
            if not v then
                win._snapResFS:SetText("|cffff4444invalid|r")
                return
            end
            local snapped   = PPUI:SnapToPixel(v)
            local pxIn      = PPUI:RegionUnitsToPixels(v)
            local pxSnapped = PPUI:RegionUnitsToPixels(snapped)
            local exact     = math.abs(pxSnapped - math.floor(pxSnapped + 0.5)) < 0.001
            win._snapResFS:SetText(string.format(
                "→ |c%s%.4f|r  (%.3f → |c%s%.0f|r px)",
                C.white, snapped, pxIn,
                exact and C.good or C.warn, pxSnapped))
        end)

        Y = Y - 46

        local snapHintFS = FS(p, 10)
        snapHintFS:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 4, Y)
        snapHintFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        snapHintFS:SetText("Enter any region-unit value to see its snapped equivalent and exact pixel count.")
    end

    -- =========================================================================
    -- BOTTOM BAR  (always visible)
    -- =========================================================================
    local botBar = NewBackdrop(win)
    botBar:SetHeight(BOT_H)
    botBar:SetPoint("BOTTOMLEFT")
    botBar:SetPoint("BOTTOMRIGHT")
    SetBD(botBar, T.hdrBg[1], T.hdrBg[2], T.hdrBg[3], T.hdrBg[4], 0, 0, 0, 0)

    local btnInfo = MakeButton(botBar, "Print Info", 100, 22)
    btnInfo:SetPoint("LEFT", botBar, "LEFT", PAD, 0)
    btnInfo:SetScript("OnClick", function() PPUI:PrintFullInfo() end)

    local helpFS = FS(botBar, 10)
    helpFS:SetPoint("RIGHT", botBar, "RIGHT", -PAD, 0)
    helpFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
    helpFS:SetText("/pp help  for all commands")

    -- =========================================================================
    -- REFRESH — updates every displayed field
    -- =========================================================================
    function win:Refresh()
        self._refreshing = true

        local physW, physH = PPUI:GetPhysicalSize()
        local cur     = UIParent:GetScale()
        local target  = PPUI:GetPixelPerfectScale()
        local N       = PPUI:GetPixelMultiplier()
        local perfect = PPUI:IsPixelPerfect()
        local pxPerU  = PPUI:RegionUnitsToPixels(1)
        local pixelU  = PPUI:PixelsToRegionUnits(1)
        local frac    = pxPerU - math.floor(pxPerU + 0.00001)

        -- ── Status indicator ───────────────────────────────────────────────
        if not PPUI.db.enabled then
            self._statusDot:SetColorTexture(T.bad[1],  T.bad[2],  T.bad[3],  1)
            self._statusFS:SetText("|cffdd3333● DISABLED|r")
        elseif perfect then
            self._statusDot:SetColorTexture(T.good[1], T.good[2], T.good[3], 1)
            local density = N == 1 and "1px/unit"
                or string.format("%dpx/unit  (×%d density)", N, N)
            self._statusFS:SetText(
                string.format("|cff33dd55● PIXEL PERFECT  |r|cff888888%s|r", density))
        else
            self._statusDot:SetColorTexture(T.warn[1], T.warn[2], T.warn[3], 1)
            self._statusFS:SetText("|cffff9933● ENABLED — SCALE MISMATCH|r")
        end

        -- ── Scale tab values ──────────────────────────────────────────────
        self._vPhysRes:SetText(string.format("|c%s%d × %d|r", C.white, physW, physH))
        self._vAspect:SetText(string.format("|c%s%.4f : 1|r", C.white, physW / physH))
        local scaleCol = perfect and C.good or C.warn
        self._vScale:SetText(string.format("|c%s%.6f|r", scaleCol, cur))
        self._vTarget:SetText(string.format("|c%s%.6f|r%s",
            C.white, target,
            target < 0.64 and "  |cffff9933(bypass active)|r" or ""))
        self._vPixelU:SetText(string.format("|c%s%.6f|r", C.white, pixelU))

        -- ── Scale controls ────────────────────────────────────────────────
        self._cbEnable:SetChecked(PPUI.db.enabled)
        self._cbAuto:SetChecked(PPUI.db.autoApply)
        self._cbManual:SetChecked(PPUI.db.useManualScale)

        local sv = math.max(0.20, math.min(1.20, PPUI.db.manualScale or target))
        self._slider:SetValue(sv)
        self._slider:SetSliderEnabled(PPUI.db.useManualScale)
        self._sliderValFS:SetText(string.format("|c%s%.4f|r", C.white, sv))
        self._optimalHintFS:SetText(string.format(
            "Optimal: |c%s%.6f|r  (N=%d, %dpx/unit, ≈%dpx screen)",
            C.accent, target, N, N, math.floor(768 / target + 0.5)))

        -- ── Diagnostics tab values ────────────────────────────────────────
        local cvarV = tonumber(GetCVarSafe("uiScale")) or 0
        local cvarU = GetCVarSafe("useUiScale") or "0"

        self._vCvarScale:SetText(string.format("|c%s%.6f|r", C.white, cvarV))
        self._vCvarUse:SetText(cvarU == "1"
            and "|cff33dd55ON|r" or "|cffff4444OFF|r")
        self._vEffScale:SetText(string.format("|c%s%.6f|r", C.white,
            UIParent:GetEffectiveScale()))

        local densityCol = (math.abs(pxPerU - N) < 0.0001) and C.good or C.warn
        self._vDensity:SetText(string.format(
            "|c%sN=%d|r  (%d physical pixel%s per region unit)",
            densityCol, N, N, N == 1 and "" or "s"))

        local fracCol = frac < 0.0001 and C.good or C.warn
        self._vPxPerU:SetText(string.format(
            "|c%s%.6f|r  |c%s(frac %.5f)|r", C.white, pxPerU, fracCol, frac))

        if frac < 0.0001 then
            self._vDrift:SetText("|cff33dd55None — crisp pixel boundaries|r")
        else
            self._vDrift:SetText(string.format(
                "|cffff9933%.5f px — source of 1px misalignment|r", frac))
        end

        self._vBypass:SetText(target < 0.64
            and string.format("|cffff9933Yes (target %.4f < CVar floor 0.64)|r", target)
            or  "|cff33dd55No — CVar range sufficient|r")

        -- ── ElvUI tab values ──────────────────────────────────────────────
        local ei = PPUI:GetElvUIInfo()
        if ei then
            self._elvStatusFS:SetText("|cff33dd55ElvUI detected|r")
            self._vElvScale:SetText(string.format("|c%s%.6f|r", C.white, ei.uiScale))
            self._vElvMult:SetText(string.format("|c%s%.6f|r  %s",
                C.white, ei.mult,
                ei.multOK and "|cff33dd55✓|r" or "|cffff4444✗|r"))
            self._vElvIdeal:SetText(string.format("|c%s%.6f|r", C.accent, ei.idealMult))
            self._vElvMatch:SetText(ei.scaleOK
                and "|cff33dd55✓ Synced|r"
                or  "|cffff4444✗ Mismatch — press Force Sync ElvUI|r")
            self._cbHookElvUI:Enable()
            self._btnSync:Enable()
        else
            self._elvStatusFS:SetText("|cff555555ElvUI not detected|r")
            self._vElvScale:SetText("|cff444444—|r")
            self._vElvMult:SetText("|cff444444—|r")
            self._vElvIdeal:SetText("|cff444444—|r")
            self._vElvMatch:SetText("|cff444444—|r")
            self._cbHookElvUI:Disable()
            self._btnSync:Disable()
        end
        self._cbHookElvUI:SetChecked(PPUI.db.hookElvUI)

        -- ── Tools tab checkboxes ──────────────────────────────────────────
        if self._cbGrid   then self._cbGrid:SetChecked(PPUI.db.gridEnabled or false) end
        if self._cbCenter then self._cbCenter:SetChecked(PPUI.db.showCenter or false) end

        self._refreshing = false
    end

    win:SetScript("OnShow", function(self) self:Refresh() end)

    -- Gentle 2.5s periodic refresh while open
    win:SetScript("OnUpdate", (function()
        local t = 0
        return function(self, dt)
            t = t + dt
            if t >= 2.5 then t = 0; self:Refresh() end
        end
    end)())

    self.GUI = win
end

-- Override stub in Core.lua once GUI.lua is fully loaded
function PPUI:ToggleGUI()
    if not self.GUI then self:CreateGUI() end
    if self.GUI:IsShown() then
        self.GUI:Hide()
    else
        self.GUI:Show()
    end
end

-- =============================================================================
-- MINIMAP BUTTON
-- =============================================================================

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "PPUIMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Icon with circular alpha mask
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\spell_arcane_prismaticcloak")
    icon:SetAllPoints()

    local mask = btn:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    -- Standard minimap tracking border ring
    local ring = btn:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(54, 54)
    ring:SetPoint("CENTER", btn, "CENTER", 0, 0)

    -- Position helper: place btn at angle/radius around minimap centre
    local function UpdatePos()
        local angle  = math.rad(PPUI.db.minimapAngle or 225)
        local radius = 80
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * radius,
            math.sin(angle) * radius)
    end
    UpdatePos()

    -- Drag to reposition around the minimap
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s      = UIParent:GetEffectiveScale()
            PPUI.db.minimapAngle = math.deg(atan2(cy / s - my, cx / s - mx))
            UpdatePos()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    -- Clicks
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            PPUI:ToggleGUI()
        elseif button == "RightButton" then
            PPUI:PrintStatus()
        end
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff7ec8e3Pixel|r|cffffffffPerfect|r|cffaaaaaaUI|r")
        local physW, physH = PPUI:GetPhysicalSize()
        GameTooltip:AddLine(
            string.format("%d×%d   scale: %.4f", physW, physH, UIParent:GetScale()),
            T.dim[1], T.dim[2], T.dim[3])
        GameTooltip:AddLine(PPUI:IsPixelPerfect()
            and "|cff33dd55● Pixel Perfect Active|r"
            or  "|cffff9933● Not Pixel Perfect|r")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaa Left-click: |r Open settings")
        GameTooltip:AddLine("|cffaaaaaa Right-click:|r Print status to chat")
        GameTooltip:AddLine("|cffaaaaaa Drag:       |r Move around minimap")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return btn
end

-- Create the minimap button after the UI is fully loaded
local mmLoader = CreateFrame("Frame")
mmLoader:RegisterEvent("PLAYER_LOGIN")
mmLoader:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    C_Timer.After(1.0, CreateMinimapButton)
end)
