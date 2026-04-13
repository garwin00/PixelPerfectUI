-- =============================================================================
-- PixelPerfectUI - Inspector.lua
-- Click-to-inspect frame dimensions with pixel-perfect analysis.
--
-- Usage:
--   /pp inspect   — toggle picker mode
--   Hover over any frame → gold highlight + live info panel
--   Left-click  → lock on that frame (cyan highlight)
--   Left-click again (or "Unlock" button) → unlock, resume hovering
--   Right-click → close inspector
-- =============================================================================

local ADDON_NAME, ns = ...
local PPUI = ns.PPUI

-- =============================================================================
-- THEME  (matches GUI.lua)
-- =============================================================================

local T = {
    bg        = { 0.08, 0.08, 0.09, 0.97 },
    hdrBg     = { 0.05, 0.05, 0.06, 1.00 },
    border    = { 0.22, 0.22, 0.25, 1.00 },
    accent    = { 0.49, 0.78, 0.89 },
    good      = { 0.20, 0.84, 0.40 },
    warn      = { 1.00, 0.62, 0.12 },
    bad       = { 0.88, 0.24, 0.24 },
    text      = { 0.90, 0.90, 0.90 },
    dim       = { 0.52, 0.52, 0.55 },
    white     = { 1.00, 1.00, 1.00 },
    gold      = { 1.00, 0.82, 0.00, 1.00 },   -- hover highlight
    cyan      = { 0.49, 0.78, 0.89, 1.00 },   -- locked highlight
}

local C = {
    good   = "ff33dd55",
    warn   = "ffff9933",
    bad    = "ffdd3333",
    white  = "ffffffff",
    dim    = "ff888888",
    accent = "ff7ec8e3",
}

local PAD   = 10
local ROW_H = 18
local GAP   = 10          -- gap between sections
local DIV_H = GAP + 4     -- total height a divider takes
local PANEL_W = 390

-- =============================================================================
-- WIDGET HELPERS
-- =============================================================================

local function FS(parent, size, flags)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFont("Fonts\\FRIZQT__.TTF", size or 11, flags or "")
    return f
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

-- =============================================================================
-- STATE
-- =============================================================================

local Inspector = {}
ns.Inspector   = Inspector

local _active    = false    -- is picker mode on?
local _locked    = false    -- has user clicked to lock a frame?
local _hovered   = nil      -- frame currently under the mouse
local _target    = nil      -- hovered OR locked — the frame being displayed
local _intercept = nil      -- fullscreen mouse-capture overlay
local _hl        = {}       -- 4 border-line frames (the gold/cyan highlight)
local _hlB       = {}       -- 4 green border-line frames (gap mode: frame B)
local _panel     = nil      -- floating info panel
local _throttle  = 0        -- OnUpdate throttle accumulator
local _gapMode   = false    -- is gap-measurement mode active?

-- Frames to ignore when looking for mouse focus
local SKIP_NAMES = {
    WorldFrame               = true,
    UIParent                 = true,
    PPUIInspectorIntercept   = true,
    PPUIInspectorPanel       = true,
}

local function IsSkippable(f)
    if not f then return true end
    local name = f:GetName()
    if name and SKIP_NAMES[name] then return true end
    -- Ignore children of our own panel
    if _panel then
        local p = f.GetParent and f:GetParent()
        while p do
            if p == _panel then return true end
            p = p.GetParent and p:GetParent()
        end
    end
    return false
end

-- =============================================================================
-- HIGHLIGHT  (4 thin lines forming a rectangle around the target frame)
-- =============================================================================

local function CreateHighlight()
    for i = 1, 4 do
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("TOOLTIP")
        f:SetFrameLevel(500)
        local tex = f:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], T.gold[4])
        f._tex = tex
        f:Hide()
        _hl[i] = f
    end
    -- Second highlight set (green) used for frame B in gap mode
    for i = 1, 4 do
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("TOOLTIP")
        f:SetFrameLevel(501)
        local tex = f:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetColorTexture(T.good[1], T.good[2], T.good[3], 0.90)
        f._tex = tex
        f:Hide()
        _hlB[i] = f
    end
end

local function SetHighlightColor(r, g, b, a)
    for _, f in ipairs(_hl) do
        f._tex:SetColorTexture(r, g, b, a or 1)
    end
end

local function UpdateHighlight(target)
    if not target or not target.GetLeft then
        for _, f in ipairs(_hl) do f:Hide() end
        return
    end
    local l = target:GetLeft()
    local r = target:GetRight()
    local t = target:GetTop()
    local b = target:GetBottom()
    if not l then
        for _, f in ipairs(_hl) do f:Hide() end
        return
    end
    local thick = 1   -- 1 region-unit thick border lines
    -- Top
    _hl[1]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, t)
    _hl[1]:SetSize(r - l, thick)
    _hl[1]:Show()
    -- Bottom
    _hl[2]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b - thick)
    _hl[2]:SetSize(r - l, thick)
    _hl[2]:Show()
    -- Left
    _hl[3]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l - thick, b - thick)
    _hl[3]:SetSize(thick, t - b + 2 * thick)
    _hl[3]:Show()
    -- Right
    _hl[4]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", r, b - thick)
    _hl[4]:SetSize(thick, t - b + 2 * thick)
    _hl[4]:Show()
end

-- Green highlight for frame B in gap mode (same logic, uses _hlB)
local function UpdateHighlightB(target)
    if not target or not target.GetLeft then
        for _, f in ipairs(_hlB) do f:Hide() end
        return
    end
    local l = target:GetLeft()
    local r = target:GetRight()
    local t = target:GetTop()
    local b = target:GetBottom()
    if not l then
        for _, f in ipairs(_hlB) do f:Hide() end
        return
    end
    local thick = 1
    _hlB[1]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, t)
    _hlB[1]:SetSize(r - l, thick); _hlB[1]:Show()
    _hlB[2]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b - thick)
    _hlB[2]:SetSize(r - l, thick); _hlB[2]:Show()
    _hlB[3]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l - thick, b - thick)
    _hlB[3]:SetSize(thick, t - b + 2 * thick); _hlB[3]:Show()
    _hlB[4]:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", r, b - thick)
    _hlB[4]:SetSize(thick, t - b + 2 * thick); _hlB[4]:Show()
end

-- Compute gap/offset info between two frames. Returns a table or nil.
local function GetGapInfo(frameA, frameB)
    if not frameA or not frameB then return nil end
    local effScale = UIParent:GetEffectiveScale()
    local al = frameA:GetLeft();  if not al then return nil end
    local ar = frameA:GetRight()
    local at = frameA:GetTop()
    local ab = frameA:GetBottom()
    local bl = frameB:GetLeft();  if not bl then return nil end
    local br = frameB:GetRight()
    local bt = frameB:GetTop()
    local bb = frameB:GetBottom()
    -- Convert all to physical pixels
    al = al * effScale;  ar = ar * effScale
    at = at * effScale;  ab = ab * effScale
    bl = bl * effScale;  br = br * effScale
    bt = bt * effScale;  bb = bb * effScale
    -- Horizontal gap: positive = clear space, negative = overlap
    local hGap
    if ar <= bl then
        hGap = bl - ar    -- A is to the left of B
    elseif br <= al then
        hGap = al - br    -- B is to the left of A (reported as negative convention)
        hGap = -hGap
    else
        hGap = -(math.min(ar, br) - math.max(al, bl))  -- overlap
    end
    -- Vertical gap
    local vGap
    if at <= bb then
        vGap = bb - at    -- A is below B
    elseif bt <= ab then
        vGap = ab - bt
        vGap = -vGap
    else
        vGap = -(math.min(at, bt) - math.max(ab, bb))
    end
    -- Center offsets
    local aCX = (al + ar) / 2;  local bCX = (bl + br) / 2
    local aCY = (ab + at) / 2;  local bCY = (bb + bt) / 2
    local N   = PPUI:GetPixelMultiplier()
    return {
        hGap    = hGap,
        vGap    = vGap,
        cxDelta = bCX - aCX,
        cyDelta = bCY - aCY,
        N       = N,
        nameB   = frameB:GetName() or "(unnamed)",
    }
end

-- Return a string showing whether a pixel dimension is aligned to N.
local function AlignStr(px, N)
    local nearest  = math.floor(px / N + 0.5) * N
    local diff     = math.abs(px - nearest)
    if diff < 0.02 then
        return string.format("|c%s✓ divisible by N=%d|r", C.good, N)
    else
        return string.format(
            "|c%s✗ off by %.2f px  (nearest: %d px)|r",
            C.warn, px - nearest, math.floor(nearest + 0.5))
    end
end

local function GetFrameInfo(frame)
    if not frame or not frame.GetWidth then return nil end

    local N        = PPUI:GetPixelMultiplier()
    local effScale = UIParent:GetEffectiveScale()

    local w = frame:GetWidth()
    local h = frame:GetHeight()
    local l = frame:GetLeft()
    local r = frame:GetRight()
    local t = frame:GetTop()
    local b = frame:GetBottom()

    if not l then return nil end   -- frame is detached / off-screen

    -- Physical pixel dimensions (L/R/T/B are UIParent units; × effScale → px)
    local pxW = (r - l) * effScale
    local pxH = (t - b) * effScale
    local pxL = l * effScale     -- pixels from left edge of screen
    local pxB = b * effScale     -- pixels from bottom edge of screen

    -- Backdrop border size, if any
    local backdrop = frame.GetBackdrop and frame:GetBackdrop()
    local edgePx   = backdrop and ((backdrop.edgeSize or 0) * effScale) or 0

    -- Scan direct children for any that extend outside the frame rect.
    -- ElvUI and other addons often attach border frames as children.
    local minL, maxR, maxT, minB = l, r, t, b
    local hasOuterChildren = false
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            if child:IsShown() then
                local cl = child:GetLeft()
                local cr = child:GetRight()
                local ct = child:GetTop()
                local cb = child:GetBottom()
                if cl and cr and ct and cb then
                    if cl < minL - 0.01 or cr > maxR + 0.01
                    or ct > maxT + 0.01 or cb < minB - 0.01 then
                        hasOuterChildren = true
                    end
                    if cl < minL then minL = cl end
                    if cr > maxR then maxR = cr end
                    if ct > maxT then maxT = ct end
                    if cb < minB then minB = cb end
                end
            end
        end
    end

    local totalPxW = (maxR - minL) * effScale
    local totalPxH = (maxT - minB) * effScale

    return {
        name             = frame:GetName() or "(unnamed)",
        objType          = frame.GetObjectType and frame:GetObjectType() or "?",
        parentName       = frame.GetParent and frame:GetParent()
                           and (frame:GetParent():GetName() or "(unnamed)") or "none",
        strata           = frame.GetFrameStrata and frame:GetFrameStrata() or "?",
        level            = frame.GetFrameLevel and frame:GetFrameLevel() or 0,
        w                = w,
        h                = h,
        pxW              = pxW,
        pxH              = pxH,
        pxL              = pxL,
        pxB              = pxB,
        edgePx           = edgePx,
        N                = N,
        totalPxW         = totalPxW,
        totalPxH         = totalPxH,
        hasOuterChildren = hasOuterChildren,
    }
end

-- =============================================================================
-- INTERCEPT FRAME  (fullscreen overlay that captures mouse events)
-- =============================================================================

-- Retrieve the real frame under the cursor, bypassing our intercept overlay.
-- The hide/show within one OnUpdate tick is invisible — WoW renders after
-- all scripts in a frame have completed.
local function GetFocusedFrame()
    _intercept:Hide()
    local focused
    if GetMouseFoci then
        -- Dragonflight+ returns a list; take the topmost non-skip frame
        local foci = GetMouseFoci()
        if foci then
            for _, f in ipairs(foci) do
                if not IsSkippable(f) then
                    focused = f
                    break
                end
            end
        end
    end
    if not focused and GetMouseFocus then
        local f = GetMouseFocus()
        if not IsSkippable(f) then focused = f end
    end
    _intercept:Show()
    return focused
end

local function CreateIntercept()
    if _intercept then return end

    _intercept = CreateFrame("Frame", "PPUIInspectorIntercept", UIParent)
    _intercept:SetFrameStrata("TOOLTIP")
    _intercept:SetFrameLevel(499)   -- just below highlight lines at 500
    _intercept:SetAllPoints(UIParent)
    _intercept:EnableMouse(true)
    _intercept:Hide()

    _intercept:SetScript("OnUpdate", function(self, elapsed)
        if not _active then return end

        -- Throttle to ~20 fps
        _throttle = _throttle + elapsed
        if _throttle < 0.05 then return end
        _throttle = 0

        if _locked and not _gapMode then
            -- Keep highlight tracked to locked frame (it may move)
            if _target then UpdateHighlight(_target) end
            return
        end

        local f = GetFocusedFrame()
        if _locked and _gapMode then
            -- In gap mode: keep frame A locked, update hovered for frame B
            if _target then UpdateHighlight(_target) end
            if f and f ~= _hovered and f ~= _target then
                _hovered = f
                Inspector:RefreshPanel()
            end
            return
        end

        if f and f ~= _hovered then
            _hovered = f
            _target  = f
            UpdateHighlight(f)
            Inspector:RefreshPanel()
        end
    end)

    _intercept:SetScript("OnMouseDown", function(self, btn)
        if btn == "RightButton" then
            Inspector:Stop()
        elseif btn == "LeftButton" then
            if _locked then
                -- Unlock — resume hovering
                _locked = false
                _target = _hovered
                SetHighlightColor(T.gold[1], T.gold[2], T.gold[3], T.gold[4])
                Inspector:RefreshPanel()
            else
                -- Lock on whatever is currently hovered
                if _hovered then
                    _locked = true
                    SetHighlightColor(T.cyan[1], T.cyan[2], T.cyan[3], T.cyan[4])
                    Inspector:RefreshPanel()
                end
            end
        end
    end)
end

-- =============================================================================
-- INFO PANEL
-- =============================================================================

-- Row key order — "_divN" entries become visual dividers
local ROW_KEYS = {
    "name", "type", "parent", "strata",
    "_div1",
    "pxW", "pxH", "unitW", "unitH",
    "wAlign", "hAlign",
    "_div2",
    "pxL", "pxB",
    "_div3",
    "edge", "totalW", "totalH",
    "_div4",
    "suggestion",
    "_div5",
    "gapFrameB", "gapH", "gapV", "gapCX", "gapCY",
}

local ROW_LABELS = {
    name       = "Frame name",
    type       = "Type",
    parent     = "Parent",
    strata     = "Strata / Level",
    pxW        = "Width (px)",
    pxH        = "Height (px)",
    unitW      = "Width (units)",
    unitH      = "Height (units)",
    wAlign     = "  Width align",
    hAlign     = "  Height align",
    pxL        = "Left edge (px)",
    pxB        = "Bottom edge (px)",
    edge       = "Backdrop edge",
    totalW     = "Total W incl. borders",
    totalH     = "Total H incl. borders",
    suggestion = "Suggested correction",
    gapFrameB  = "Gap to frame",
    gapH       = "  H gap",
    gapV       = "  V gap",
    gapCX      = "  Center Δ X",
    gapCY      = "  Center Δ Y",
}

local function BuildPanel()
    if _panel then return end

    -- Pre-calculate height: header + rows + dividers + button bar
    local realRows = 0
    local divCount = 0
    for _, k in ipairs(ROW_KEYS) do
        if k:sub(1, 1) == "_" then divCount = divCount + 1 else realRows = realRows + 1 end
    end
    local panelH = 28 + PAD + realRows * ROW_H + divCount * DIV_H + PAD + 26 + PAD

    local win = CreateFrame("Frame", "PPUIInspectorPanel", UIParent, "BackdropTemplate")
    win:SetSize(PANEL_W, panelH)
    win:SetFrameStrata("HIGH")
    win:SetFrameLevel(200)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop",  win.StopMovingOrSizing)
    SetBD(win, T.bg[1], T.bg[2], T.bg[3], T.bg[4])
    win:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -200)
    win:Hide()
    _panel = win

    -- ── Header ────────────────────────────────────────────────────────────
    local hdr = CreateFrame("Frame", nil, win, "BackdropTemplate")
    hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
    hdr:SetHeight(28)
    SetBD(hdr, T.hdrBg[1], T.hdrBg[2], T.hdrBg[3], T.hdrBg[4])

    local title = FS(hdr, 12, "OUTLINE")
    title:SetPoint("LEFT", hdr, "LEFT", PAD, 0)
    title:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    title:SetText("Frame Inspector")
    win._title = title

    local lockFS = FS(hdr, 10)
    lockFS:SetPoint("RIGHT", hdr, "RIGHT", -30, 0)
    lockFS:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
    lockFS:SetText("HOVER")
    win._lockFS = lockFS

    local closeBtn = CreateFrame("Button", nil, hdr)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -4, 0)
    local closeTex = closeBtn:CreateTexture(nil, "OVERLAY")
    closeTex:SetAllPoints()
    closeTex:SetColorTexture(0.65, 0.18, 0.18, 0.9)
    local closeLabel = FS(closeBtn, 10, "OUTLINE")
    closeLabel:SetAllPoints()
    closeLabel:SetText("✕")
    closeLabel:SetJustifyH("CENTER")
    closeLabel:SetJustifyV("MIDDLE")
    closeLabel:SetTextColor(1, 1, 1)
    closeBtn:SetScript("OnClick", function() Inspector:Stop() end)

    -- ── Data rows ─────────────────────────────────────────────────────────
    local Y = -28 - PAD
    win._rows = {}

    local function MakeRow(key)
        local lbl = FS(win, 11)
        lbl:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, Y)
        lbl:SetWidth(140)
        lbl:SetJustifyH("LEFT")
        lbl:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
        if ROW_LABELS[key] then lbl:SetText(ROW_LABELS[key]) end

        local val = FS(win, 11)
        val:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + 145, Y)
        val:SetWidth(PANEL_W - PAD - 145 - PAD)
        val:SetJustifyH("LEFT")
        val:SetTextColor(T.white[1], T.white[2], T.white[3])

        win._rows[key] = { lbl = lbl, val = val }
        Y = Y - ROW_H
    end

    for _, key in ipairs(ROW_KEYS) do
        if key:sub(1, 1) == "_" then
            -- Divider line
            local div = win:CreateTexture(nil, "ARTWORK")
            div:SetHeight(1)
            div:SetPoint("TOPLEFT",  win, "TOPLEFT",  PAD,  Y - 4)
            div:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, Y - 4)
            div:SetColorTexture(T.border[1], T.border[2], T.border[3], 0.8)
            Y = Y - DIV_H
        else
            MakeRow(key)
        end
    end

    -- ── Action buttons ────────────────────────────────────────────────────
    Y = Y - PAD

    local function MakeBtn(label, w, ox)
        local btn = CreateFrame("Button", nil, win, "BackdropTemplate")
        btn:SetSize(w, 22)
        btn:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD + ox, PAD)
        SetBD(btn, 0.14, 0.14, 0.17, 1, 0.32, 0.32, 0.38, 1)
        local fs = FS(btn, 11)
        fs:SetAllPoints(); fs:SetJustifyH("CENTER"); fs:SetJustifyV("MIDDLE")
        fs:SetText(label); fs:SetTextColor(T.text[1], T.text[2], T.text[3])
        return btn
    end

    local copyBtn = MakeBtn("Copy to Chat", 120, 0)
    copyBtn:SetScript("OnClick", function() Inspector:PrintCurrentInfo() end)

    win._unlockBtn = MakeBtn("Unlock", 82, 128)
    win._unlockBtn:SetScript("OnClick", function()
        _locked = false
        _gapMode = false
        _target = _hovered
        SetHighlightColor(T.gold[1], T.gold[2], T.gold[3], T.gold[4])
        for _, f in ipairs(_hlB) do f:Hide() end
        Inspector:RefreshPanel()
    end)

    win._gapBtn = MakeBtn("Measure Gap", 104, 218)
    win._gapBtn:SetScript("OnClick", function()
        if not _locked then
            print("|cff7ec8e3PixelPerfectUI:|r Lock a frame first (left-click in picker mode), then use Measure Gap.")
            return
        end
        _gapMode = not _gapMode
        if not _gapMode then
            for _, f in ipairs(_hlB) do f:Hide() end
        end
        Inspector:RefreshPanel()
    end)
end

-- =============================================================================
-- PANEL REFRESH
-- =============================================================================

local function SetRow(key, text)
    if _panel and _panel._rows[key] then
        _panel._rows[key].val:SetText(text or "")
    end
end

function Inspector:RefreshPanel()
    if not _panel then return end
    local info = _target and GetFrameInfo(_target)
    if not info then
        _panel:Hide()
        return
    end
    _panel:Show()

    -- Header state
    if _locked then
        _panel._title:SetText("|c" .. C.accent .. "Frame Inspector  [LOCKED]|r")
        _panel._lockFS:SetText("|c" .. C.accent .. "LOCKED|r")
        _panel._unlockBtn:SetAlpha(1)
    else
        _panel._title:SetText("Frame Inspector")
        _panel._lockFS:SetText("|c" .. C.dim .. "HOVER|r")
        _panel._unlockBtn:SetAlpha(0.4)
    end

    -- Identity
    SetRow("name",   "|c" .. C.white .. info.name .. "|r")
    SetRow("type",   info.objType)
    SetRow("parent", info.parentName)
    SetRow("strata", string.format("%s  (level %d)", info.strata, info.level))

    -- Pixel dimensions (most actionable — show first)
    SetRow("pxW",   string.format("|c%s%.2f px|r", C.white, info.pxW))
    SetRow("pxH",   string.format("|c%s%.2f px|r", C.white, info.pxH))

    -- Region unit dimensions
    SetRow("unitW", string.format("%.4f units", info.w))
    SetRow("unitH", string.format("%.4f units", info.h))

    -- Alignment
    SetRow("wAlign", AlignStr(info.pxW, info.N))
    SetRow("hAlign", AlignStr(info.pxH, info.N))

    -- Screen position
    SetRow("pxL", string.format("%.2f px from left", info.pxL))
    SetRow("pxB", string.format("%.2f px from bottom", info.pxB))

    -- Backdrop edge
    if info.edgePx > 0 then
        SetRow("edge", string.format("%.2f px  (%.4f units)", info.edgePx,
            info.edgePx / UIParent:GetEffectiveScale()))
    else
        SetRow("edge", "|c" .. C.dim .. "none|r")
    end

    -- Total bounds including children
    if info.hasOuterChildren then
        SetRow("totalW", string.format("|c%s%.2f px|r  (frame alone: %.2f px)",
            C.warn, info.totalPxW, info.pxW))
        SetRow("totalH", string.format("|c%s%.2f px|r  (frame alone: %.2f px)",
            C.warn, info.totalPxH, info.pxH))
    else
        SetRow("totalW", string.format("|c%s%.2f px|r  (no outer borders)",
            C.good, info.totalPxW))
        SetRow("totalH", string.format("|c%s%.2f px|r  (no outer borders)",
            C.good, info.totalPxH))
    end

    -- Pixel-perfect correction suggestion
    local N      = info.N
    local nearW  = math.floor(info.pxW / N + 0.5) * N
    local nearH  = math.floor(info.pxH / N + 0.5) * N
    local wOk    = math.abs(info.pxW - nearW) < 0.02
    local hOk    = math.abs(info.pxH - nearH) < 0.02

    if wOk and hOk then
        SetRow("suggestion", "|c" .. C.good .. "Dimensions are pixel-perfect ✓|r")
    else
        local parts = {}
        if not wOk then
            parts[#parts + 1] = string.format(
                "W → %d px  (%.4f units)", nearW, PPUI:PixelsToRegionUnits(nearW))
        end
        if not hOk then
            parts[#parts + 1] = string.format(
                "H → %d px  (%.4f units)", nearH, PPUI:PixelsToRegionUnits(nearH))
        end
        SetRow("suggestion", "|c" .. C.warn .. table.concat(parts, "   |   ") .. "|r")
    end

    -- ── Gap measurement rows ───────────────────────────────────────────────
    -- Update Gap button colour: cyan when active, normal when off
    if _panel._gapBtn then
        local bd = _panel._gapBtn:GetBackdrop()
        if _gapMode then
            _panel._gapBtn:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1)
        else
            _panel._gapBtn:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
        end
    end

    if not _locked or not _gapMode then
        -- Gap section greyed out
        local hint = _locked
            and "|c" .. C.dim .. "click Measure Gap to compare with another frame|r"
            or  "|c" .. C.dim .. "lock a frame first, then use Measure Gap|r"
        SetRow("gapFrameB", hint)
        SetRow("gapH",  "|c" .. C.dim .. "—|r")
        SetRow("gapV",  "|c" .. C.dim .. "—|r")
        SetRow("gapCX", "|c" .. C.dim .. "—|r")
        SetRow("gapCY", "|c" .. C.dim .. "—|r")
        for _, f in ipairs(_hlB) do f:Hide() end
        return
    end

    -- Gap mode is active — show live gap to hovered frame
    local frameB = _hovered
    if not frameB or frameB == _target then
        SetRow("gapFrameB", "|c" .. C.dim .. "hover over a second frame…|r")
        SetRow("gapH",  "|c" .. C.dim .. "—|r")
        SetRow("gapV",  "|c" .. C.dim .. "—|r")
        SetRow("gapCX", "|c" .. C.dim .. "—|r")
        SetRow("gapCY", "|c" .. C.dim .. "—|r")
        for _, f in ipairs(_hlB) do f:Hide() end
        return
    end

    local gap = GetGapInfo(_target, frameB)
    if not gap then
        SetRow("gapFrameB", "|c" .. C.warn .. "could not read frame B|r")
        return
    end

    UpdateHighlightB(frameB)
    SetRow("gapFrameB", "|c" .. C.white .. gap.nameB .. "|r")

    local function GapStr(px)
        local N2 = gap.N
        if math.abs(px) < 0.01 then
            return "|c" .. C.good .. "0 px  (touching)|r"
        end
        local aligned = (math.abs(px % N2) < 0.02 or math.abs(math.abs(px) % N2) < 0.02)
        local col = aligned and C.good or C.warn
        return string.format("|c%s%.2f px|r  %s",
            col, px,
            px < 0 and "|c" .. C.warn .. "(overlap)|r" or "")
    end

    local function CtrStr(px)
        local col = math.abs(px) < 0.5 and C.good or C.warn
        local note = math.abs(px) < 0.5 and "  ✓ centred" or ""
        return string.format("|c%s%+.2f px|r%s", col, px, note)
    end

    SetRow("gapH",  GapStr(gap.hGap))
    SetRow("gapV",  GapStr(gap.vGap))
    SetRow("gapCX", CtrStr(gap.cxDelta))
    SetRow("gapCY", CtrStr(gap.cyDelta))
end

-- =============================================================================
-- PRINT TO CHAT
-- =============================================================================

function Inspector:PrintCurrentInfo()
    if not _target then
        print("|cff7ec8e3PixelPerfectUI:|r No frame selected in inspector.")
        return
    end
    local info = GetFrameInfo(_target)
    if not info then
        print("|cff7ec8e3PixelPerfectUI:|r Could not read frame data.")
        return
    end

    local N     = info.N
    local nearW = math.floor(info.pxW / N + 0.5) * N
    local nearH = math.floor(info.pxH / N + 0.5) * N
    local wOk   = math.abs(info.pxW - nearW) < 0.02
    local hOk   = math.abs(info.pxH - nearH) < 0.02

    print(string.format("|cff7ec8e3[PP Inspector]|r  %s  |cff888888(%s)|r", info.name, info.objType))
    print(string.format("  Parent: %s  |  %s  level %d", info.parentName, info.strata, info.level))
    print(string.format("  Size:   |cffffffff%.2fpx × %.2fpx|r  (%.4f × %.4f units)",
        info.pxW, info.pxH, info.w, info.h))
    print(string.format("  Pos:    left=%.2fpx  bottom=%.2fpx", info.pxL, info.pxB))
    if info.edgePx > 0 then
        print(string.format("  Backdrop edge: %.2fpx", info.edgePx))
    end
    if info.hasOuterChildren then
        print(string.format("  Total (incl. border children): %.2fpx × %.2fpx",
            info.totalPxW, info.totalPxH))
    end
    if wOk and hOk then
        print("  Alignment: |cff33dd55pixel-perfect ✓|r")
    else
        if not wOk then
            print(string.format("  |cffff9933Width correction:|r  %dpx → SetWidth(%.4f)",
                nearW, PPUI:PixelsToRegionUnits(nearW)))
        end
        if not hOk then
            print(string.format("  |cffff9933Height correction:|r  %dpx → SetHeight(%.4f)",
                nearH, PPUI:PixelsToRegionUnits(nearH)))
        end
    end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

function Inspector:Start()
    CreateHighlight()
    CreateIntercept()
    BuildPanel()
    _active  = false   -- reset before enabling to flush hover state
    _locked  = false
    _hovered = nil
    _target  = nil
    _active  = true
    _intercept:Show()
    _panel:Show()
    print("|cff7ec8e3PixelPerfectUI:|r Inspector active — "
        .. "|cffffffffHover|r to inspect, "
        .. "|cffffffffLeft-click|r to lock, "
        .. "|cffffffffRight-click|r to exit.")
end

function Inspector:Stop()
    _active  = false
    _locked  = false
    _gapMode = false
    if _intercept then _intercept:Hide() end
    for _, f in ipairs(_hl)  do f:Hide() end
    for _, f in ipairs(_hlB) do f:Hide() end
    if _panel then _panel:Hide() end
    _hovered = nil
    _target  = nil
end

function Inspector:Toggle()
    if _active then self:Stop() else self:Start() end
end

function Inspector:IsActive()
    return _active
end

-- Expose on PPUI for slash command and GUI button
function PPUI:ToggleInspector()
    ns.Inspector:Toggle()
end
