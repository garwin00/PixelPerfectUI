# PixelPerfectUI

A World of Warcraft addon that ensures every element of your UI sits on a true pixel boundary — no blurry edges, no 1px misalignments, no guesswork.

Designed for players running 4K monitors with ElvUI who have noticed that certain components don't quite line up, borders look soft, or widths don't add up the way they should. This addon explains why that happens and fixes it automatically.

---

## The problem

WoW always treats the screen as 768 units tall, regardless of your monitor's actual resolution. At 4K (2160px), one region unit equals 2.8125 physical pixels — a non-integer. That fractional pixel is why elements drift off-centre, why 1px borders look thicker on one side, and why two components with the same stated width don't visually match.

ElvUI compounds this because it calculates its own `E.mult` value from the UI scale. If the scale is wrong, `E.mult` is wrong, and every border, gap and padding ElvUI draws is slightly off.

## The fix

For pixel-perfect alignment you need:

```
scale × physicalHeight / 768 = N   (where N is a whole number)
```

At 4K with N=2 this gives a scale of **0.7111** — the same visual size as 1080p, and every region unit maps to exactly 2 physical pixels. At 1440p with N=1 the target is **0.5333**, which falls below WoW's 0.64 CVar floor and requires writing directly to `UIParent:SetScale()` to apply.

This addon calculates the correct scale for your resolution automatically, applies it, and syncs ElvUI's internal values to match.

---

## Features

### Automatic scale correction
Calculates and applies the pixel-perfect scale for your resolution on login. Works at any resolution — 1080p, 1440p, 4K, and ultrawide.

### ElvUI sync
Corrects `E.uiScale` and `E.mult` so that ElvUI's 1px borders and padding are drawn at exactly one physical pixel. Hooks `UpdateUIScale` to prevent ElvUI from fighting back and resetting the scale.

### Frame Inspector
Click any frame on screen to see its exact pixel dimensions, position, and whether its width and height land on whole pixels. A gap measurement mode lets you lock two frames and read the horizontal, vertical and centre-to-centre distance between them in both region units and physical pixels.

### Alignment tools
- **Pixel grid overlay** — draws a grid at a configurable interval (8 / 16 / 32 / 64px) over the entire screen to help you place elements precisely
- **Guide lines** — drag horizontal and vertical guide lines anywhere on screen; they snap to pixel boundaries and are saved between sessions
- **Centre crosshair** — marks the exact screen centre

### Pixel snap calculator
Enter any region-unit value and see what it snaps to, how many physical pixels that is, and whether the result is exact.

---

## Installation

1. Download or clone this repository
2. Copy the `PixelPerfectUI` folder into `World of Warcraft/_retail_/Interface/AddOns/`
3. Restart the game or type `/reload`
4. The minimap button appears automatically — left-click to open settings

---

## Usage

Open the settings window with the minimap button or `/pp`.

| Tab | What's here |
|-----|-------------|
| **Scale** | Enable/disable, auto-apply toggle, manual scale slider, Apply / Set Optimal / Reset buttons |
| **ElvUI** | ElvUI sync status, E.mult values, hook toggle, Force Sync button |
| **Tools** | Grid overlay, guide lines, centre crosshair, Frame Inspector |
| **Diagnostics** | Raw CVar values, sub-pixel drift, pixel density (N), snap calculator |

### Slash commands

| Command | Action |
|---------|--------|
| `/pp` | Open / close settings |
| `/pp apply` | Apply pixel-perfect scale now |
| `/pp reset` | Reset UIParent to WoW's default scale |
| `/pp toggle` | Enable or disable without opening the UI |
| `/pp sync` | Force-sync ElvUI E.uiScale and E.mult |
| `/pp inspect` | Open the Frame Inspector (click any frame) |
| `/pp grid` | Toggle the pixel grid overlay |
| `/pp hguide` | Add a horizontal guide at the cursor position |
| `/pp vguide` | Add a vertical guide at the cursor position |
| `/pp guides clear` | Remove all guide lines |
| `/pp center` | Toggle the screen centre crosshair |
| `/pp info` | Print full diagnostic info to chat |
| `/pp status` | Print a one-line status summary to chat |
| `/pp help` | List all commands |

---

## Compatibility

- **Game version:** 12.0.1 (The War Within / Midnight)
- **ElvUI:** Supported. The ElvUI tab will show sync status and let you correct `E.mult` automatically.
- **Other UI addons:** The scale correction applies to `UIParent` globally, so all addons benefit. No specific integration is needed beyond ElvUI.

---

## How the scale is calculated

WoW's virtual coordinate space is always 768 units tall. The number of physical pixels per region unit is:

```
pixels_per_unit = effectiveScale × physicalHeight / 768
```

For pixel-perfect rendering this must be a whole number N. Solving for scale:

```
scale = N × 768 / physicalHeight
```

| Resolution | N | Scale | Notes |
|------------|---|-------|-------|
| 1080p | 1 | 1.0000 | Default — already pixel perfect |
| 1440p | 1 | 0.5333 | Below 0.64 CVar floor — bypass required |
| 4K | 2 | 0.7111 | Same visual size as 1080p |
| 4K | 1 | 0.3556 | Smaller UI — also valid |

WoW's `uiScale` CVar has a hard minimum of 0.64. Values below this are silently ignored when set via `SetCVar`. This addon bypasses that limit by calling `UIParent:SetScale()` directly, which has no floor.

---

## Saved variables

Settings are stored in `PixelPerfectUIDB` in your WTF folder. Guide line positions, grid size, and window position are all persisted automatically.
