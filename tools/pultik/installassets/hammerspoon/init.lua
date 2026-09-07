-- Pultík's Hammerspoon package: grid window placement (Magnet's Grid 1/8 keys),
-- orientation-aware, plus the `.organize` workspace engine (organize.lua).
-- Installed by `pultik install --hammerspoon` as a symlink at
-- ~/.hammerspoon/init.lua; migrated here from PersonalSetup 2026-09-01
-- (docs/specs/2026-09-01-organize-workspaces-decisions.md).
--
-- THE KEYBOARD IS A SCALE MODEL OF THE SCREEN: keyboard row -> screen row,
-- keyboard column -> screen column. ctrl-alt + the key at (row r, col c) drops the
-- FOCUSED window into cell (r, c) of whatever grid the ACTIVE display uses. Any app,
-- always. Keys that fall outside a display's shape do nothing on it.
--
--   ultrawide 5x2   U I O P ú  /  J K L ů §   (>= 3008pt wide, e.g. the Pro Display XDR)
--   landscape 4x2   U I O P    /  J K L ů
--   portrait  3x3   U I O      /  J K L      /  M , .
--   Sidecar   2x2   U I        /  J K
--
--   The wide shape is the 4x2 with one column APPENDED: every key keeps the cell it
--   already had, ú/§ are the new column 5. Nothing that was muscle memory moved.
--
--   ctrl-alt + Q/W/E · A/S/D · Y/X/C -> thirds bands, rotated with the display:
--       landscape  column 1..3, top half / bottom half / full height
--       portrait   row    1..3, left half / right half / full width
--   ctrl-alt + M/,/./-  -> full-height quarter columns 1..4 -- but only where the
--                          grid has fewer than three rows; on the portrait 3x3 those
--                          same keys ARE the grid's third row (resolved per keypress).
--                          They stay QUARTERS on the 5x2 -- they are their own tool,
--                          not "the grid column, full height".
--   ctrl-alt + Enter / arrows -> maximize / half of the screen.
--   ctrl-alt-SHIFT + U  -> tile EVERY window on the active display into its grid.
--
-- That's the whole story. Earlier versions resolved cell occupancy, navigated
-- between tiles, and spawned Warp windows -- all removed on purpose (2026-08-01):
-- the smart dispatch made behaviour unpredictable. One key, one meaning.

require("hs.ipc") -- enables the `hs -c "..."` shell CLI

-- RAW KEYCODES (physical key positions), never character strings: the active layout
-- is Czech, where the number row types +ěščřžýá and `;` types ů. Keycodes are
-- layout-independent, character lookups are not.
local KEY = {
  U = 32, I = 34, O = 31, P = 35,         -- Magnet "Grid 1/8 Top 1..4"
  J = 38, K = 40, L = 37, Semicolon = 41, -- Magnet "Grid 1/8 Bottom 1..4" (Ů on Czech)
  -- Column 5, used only by the ultrawide shape: the two keys physically right of
  -- P and Ů. On Czech they type ú and §; on ANSI they are [ and '.
  LBracket = 33, Quote = 39,
  -- The physical row below J/K/L/ů. Keycode 44 is the key right of "." -- types "-"
  -- on Czech (ANSI slash position).
  M = 46, Comma = 43, Period = 47, Dash = 44,
  -- Y/X/C are the physical bottom-left keys (ANSI Z/X/C positions; QWERTZ types yxc).
  Q = 12, W = 13, E = 14,
  A = 0, S = 1, D = 2,
  Y = 6, X = 7, C = 8,
}

-- The grid's three physical keyboard rows. A shape of C columns by R rows uses the
-- top-left C x R corner of this table -- which is why one key set serves 5x2, 4x2,
-- 3x3 and 2x2 without a single per-display key mapping.
--
-- The table is deliberately RAGGED: only rows 1-2 carry a fifth key, because no
-- grid is five columns AND three rows, and the physical row below M/,/.- has no
-- fifth key to give. ipairs() walks each row to its own length, so row 3 simply
-- stays four wide.
local GRID_ROWS = {
  { KEY.U, KEY.I, KEY.O, KEY.P, KEY.LBracket },
  { KEY.J, KEY.K, KEY.L, KEY.Semicolon, KEY.Quote },
  { KEY.M, KEY.Comma, KEY.Period, KEY.Dash },
}

-- The grid FOLLOWS THE ACTIVE DISPLAY: the screen is resolved on every keypress from
-- the focused window (falling back to the pointer, then the main screen). One key set
-- therefore works on every monitor, no display is named in config.
local LANDSCAPE_SHAPE = { cols = 4, rows = 2 }
local PORTRAIT_SHAPE = { cols = 3, rows = 3 } -- e.g. the Studio Display pivoted 270°

-- A landscape display at least this wide (points, not pixels -- HiDPI scaling is
-- already divided out of frame()) gets a fifth column instead of four fat ones.
-- 3008pt is the Pro Display XDR at its default scaling: 5 columns of 601pt, still
-- wider than a 4x2 column on the 2056pt built-in. The next widest display here is
-- that built-in, so the threshold has no near miss to worry about on the low side --
-- but the XDR clears it by only 8pt, so switching it to "Larger Text" scaling
-- (2560pt) would drop it back to 4x2. Check `WarpSlots.shape()` after any
-- resolution change rather than assuming.
local ULTRAWIDE_MIN_WIDTH = 3000
local ULTRAWIDE_SHAPE = { cols = 5, rows = 2 }

-- Per-display overrides, keyed by display UUID. A 4x2 on the 1194px-wide Sidecar
-- would give 298px columns -- unusable for a terminal -- so it gets 2x2 instead.
-- A pin beats the orientation rule below, so an odd display can always be forced.
local SHAPE_BY_SCREEN = {
  ["E9D7C7AF-C085-497F-A07B-948BC0E98235"] = { cols = 2, rows = 2 }, -- Sidecar (AirPlay)
}

local function activeScreen()
  local w = hs.window.focusedWindow()
  local s = w and w:screen()
  if s then return s end
  return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

-- Orientation is a physical fact read straight off the frame, NOT off the shape:
-- pivoting a monitor in System Settings must change the grid with no config edit,
-- and the UUID of a display that gets re-paired is not stable enough to rely on.
local function isPortrait(screen)
  local f = screen:frame()
  return f.h > f.w
end

local function shapeFor(screen)
  local pin = screen and SHAPE_BY_SCREEN[screen:getUUID()]
  if pin then return pin.cols, pin.rows end
  if not screen then return LANDSCAPE_SHAPE.cols, LANDSCAPE_SHAPE.rows end
  if isPortrait(screen) then return PORTRAIT_SHAPE.cols, PORTRAIT_SHAPE.rows end
  -- Width, like orientation, is read off the live frame rather than a UUID, so
  -- rescaling or re-pairing a display re-decides the shape with no config edit.
  if screen:frame().w >= ULTRAWIDE_MIN_WIDTH then
    return ULTRAWIDE_SHAPE.cols, ULTRAWIDE_SHAPE.rows
  end
  return LANDSCAPE_SHAPE.cols, LANDSCAPE_SHAPE.rows
end

local function cellRect(screen, cols, rows, col, row)
  local f = screen:frame()
  local cw, ch = f.w / cols, f.h / rows
  return hs.geometry.rect(f.x + (col - 1) * cw, f.y + (row - 1) * ch, cw, ch)
end

-- Every placement funnels through here: a nil rect means "this key has no meaning on
-- this display", which must be a silent no-op rather than an error or a guess.
local function placeFocused(rect)
  if not rect then return end
  local w = hs.window.focusedWindow()
  if not w then return end
  w:setFrame(rect, 0)
  w:focus()
end

local function moveFocusedToCell(col, row)
  local screen = activeScreen()
  local cols, rows = shapeFor(screen)
  if col > cols or row > rows then return end
  placeFocused(cellRect(screen, cols, rows, col, row))
end

-- ctrl-alt + Enter -> maximize (fill the screen frame, not native macOS fullscreen).
-- ctrl-alt + arrow -> half of the screen on the side the arrow points to. Both are
-- pure geometry, so they need no orientation handling.
local function moveFocusedTo(rectFor)
  placeFocused(rectFor(activeScreen():frame()))
end

-- Band placement, ROTATED WITH THE DISPLAY. A band is "slice <idx> of <of> along the
-- long axis, optionally halved along the short one":
--
--   landscape   idx runs across COLUMNS,  half 1 = top,  half 2 = bottom
--   portrait    idx runs down    ROWS,    half 1 = left, half 2 = right
--   half = nil  the full extent of the short axis
--
-- `of` clamps to the display's shape (Sidecar 2x2 -> quarters become halves), and an
-- idx outside the clamped range no-ops rather than producing a sliver of a window.
local BAND_KEYS = {
  [KEY.Q] = { idx = 1, of = 3, half = 1 },
  [KEY.W] = { idx = 2, of = 3, half = 1 },
  [KEY.E] = { idx = 3, of = 3, half = 1 },
  [KEY.A] = { idx = 1, of = 3, half = 2 },
  [KEY.S] = { idx = 2, of = 3, half = 2 },
  [KEY.D] = { idx = 3, of = 3, half = 2 },
  [KEY.Y] = { idx = 1, of = 3 },
  [KEY.X] = { idx = 2, of = 3 },
  [KEY.C] = { idx = 3, of = 3 },
}

-- The quarter bands M/,/./- , indexed by key position so the dual-meaning handler
-- below can reach them without a second keycode table. These are quarters on every
-- landscape shape, including the 5x2 -- on a five-column display they deliberately
-- do NOT line up with grid columns, and full-height column 5 has no key. Making them
-- fifths instead would need a fifth key this keyboard row does not have, and would
-- change what M/,/./- mean on the 4x2 for no gain.
local QUARTER_BANDS = {
  { idx = 1, of = 4 }, { idx = 2, of = 4 }, { idx = 3, of = 4 }, { idx = 4, of = 4 },
}

local function bandRect(screen, spec)
  local cols, rows = shapeFor(screen)
  local portrait = isPortrait(screen)
  local slots = math.min(spec.of, portrait and rows or cols)
  if spec.idx > slots then return nil end

  local f = screen:frame()
  local i = spec.idx - 1
  if portrait then
    local bh = f.h / slots
    local y = f.y + i * bh
    if not spec.half then return hs.geometry.rect(f.x, y, f.w, bh) end
    local x = (spec.half == 1) and f.x or (f.x + f.w / 2)
    return hs.geometry.rect(x, y, f.w / 2, bh)
  end

  local cw = f.w / slots
  local x = f.x + i * cw
  if not spec.half then return hs.geometry.rect(x, f.y, cw, f.h) end
  local y = (spec.half == 1) and f.y or (f.y + f.h / 2)
  return hs.geometry.rect(x, y, cw, f.h / 2)
end

-- M / , / . / - carry two meanings and the display decides which, per keypress:
-- on a three-row grid they are the grid's third row, everywhere else the
-- full-height quarter columns they have always been.
local function moveFocusedToRow3(col)
  local screen = activeScreen()
  local cols, rows = shapeFor(screen)
  if rows >= 3 and col <= cols then
    return placeFocused(cellRect(screen, cols, rows, col, 3))
  end
  placeFocused(bandRect(screen, QUARTER_BANDS[col]))
end

--------------------------------------------------------------------------------
-- Arrange every window on the active display -- ctrl-alt-shift + U
--------------------------------------------------------------------------------
--
-- Exactly "press the right grid key for every window at once": same cells, same
-- geometry as the manual keys. Fewer windows than cells simply leaves gaps -- the
-- grid never reflows, so adding a window never resizes the ones already placed.
--
-- Windows go to the cell NEAREST their current centre (greedy over all
-- window-cell distances, one window per cell), so nothing teleports across the
-- display and the mental map survives the keypress.

-- Non-resizable windows (some preference panes, About boxes) accept a move but not a
-- size, so tiling them leaves a wrongly-sized window sat in a cell that a real window
-- could have used. AX is the only honest way to ask; failures assume resizable.
local function isResizable(w)
  local ok, settable = pcall(function()
    local ax = hs.axuielement.windowElement(w)
    return ax and ax:isAttributeSettable("AXSize")
  end)
  if not ok then return true end
  return settable ~= false
end

-- A window straddling a display edge -- or dragged mostly off every display -- must
-- still belong to SOME screen, or arranging tiles around it while it sits half
-- visible (observed with a Warp window hanging off the built-in display's edge:
-- w:screen() assigned it by larger-share rules, so neither display's arrange
-- touched it). Membership is therefore decided by frame intersection area, with
-- nearest-screen-by-center as the fallback for windows fully outside everything.
local function screenOfWindow(w)
  local wf = w:frame()
  local best, bestArea = nil, 0
  for _, s in ipairs(hs.screen.allScreens()) do
    local i = wf:intersect(s:frame())
    local area = i.w * i.h
    if area > bestArea then best, bestArea = s, area end
  end
  if best then return best end
  local bestD
  for _, s in ipairs(hs.screen.allScreens()) do
    local c, sc = wf.center, s:frame().center
    local d = (c.x - sc.x) ^ 2 + (c.y - sc.y) ^ 2
    if not bestD or d < bestD then best, bestD = s, d end
  end
  return best
end

-- visibleWindows() already drops minimized windows and hidden apps, and returns them
-- most-recently-focused first -- which is the order the overflow wrap below wants.
local function arrangeableWindows(screen)
  local space = hs.spaces.activeSpaceOnScreen(screen)
  local out = {}
  for _, w in ipairs(hs.window.visibleWindows()) do
    if w:isStandard() and not w:isFullScreen() and screenOfWindow(w) == screen and isResizable(w) then
      local onSpace = (space == nil)
      for _, s in ipairs(hs.spaces.windowSpaces(w) or {}) do
        if s == space then onSpace = true break end
      end
      if onSpace then out[#out + 1] = w end
    end
  end
  return out
end

-- Greedy nearest-first matching: sort every (window, cell) pair by squared distance
-- and take them in order, skipping any whose window or cell is already spoken for.
-- Not optimal in the assignment-problem sense, but for <= 9 windows the difference is
-- invisible, and it is O(n^2 log n) with no dependencies. Ties break on index so the
-- same layout always produces the same result.
local function assignNearest(wins, cells)
  local ranked = {}
  for wi, w in ipairs(wins) do
    local wc = w:frame().center
    for ci, cell in ipairs(cells) do
      local cc = cell.center
      local dx, dy = wc.x - cc.x, wc.y - cc.y
      ranked[#ranked + 1] = { w = wi, c = ci, d = dx * dx + dy * dy }
    end
  end
  table.sort(ranked, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.w ~= b.w then return a.w < b.w end
    return a.c < b.c
  end)

  local takenW, takenC, out = {}, {}, {}
  for _, p in ipairs(ranked) do
    if not takenW[p.w] and not takenC[p.c] then
      takenW[p.w], takenC[p.c] = true, true
      out[#out + 1] = { win = wins[p.w], rect = cells[p.c] }
    end
  end
  return out
end

local function arrangeScreen(screen)
  screen = screen or activeScreen()
  local wins = arrangeableWindows(screen)
  if #wins == 0 then return 0 end

  local cols, rows = shapeFor(screen)
  local cells = {}
  for row = 1, rows do
    for col = 1, cols do
      cells[#cells + 1] = cellRect(screen, cols, rows, col, row)
    end
  end

  -- More windows than cells: wrap. The first #cells (most recently focused) each get
  -- a cell to themselves, the next batch stacks on top of them, and so on -- every
  -- window ends up tiled, and the grid geometry never changes to accommodate them.
  for start = 1, #wins, #cells do
    local batch = {}
    for i = start, math.min(start + #cells - 1, #wins) do batch[#batch + 1] = wins[i] end
    for _, a in ipairs(assignNearest(batch, cells)) do a.win:setFrame(a.rect, 0) end
  end
  return #wins
end

--------------------------------------------------------------------------------

local HALF_KEYS = {
  [36]  = function(f) return f end,                                            -- Enter: maximize
  [123] = function(f) return hs.geometry.rect(f.x, f.y, f.w / 2, f.h) end,     -- Left
  [124] = function(f) return hs.geometry.rect(f.x + f.w / 2, f.y, f.w / 2, f.h) end, -- Right
  [126] = function(f) return hs.geometry.rect(f.x, f.y, f.w, f.h / 2) end,     -- Up
  [125] = function(f) return hs.geometry.rect(f.x, f.y + f.h / 2, f.w, f.h / 2) end, -- Down
}

local hotkeys = {}
-- Rows 1 and 2 are grid-only. Row 3 goes through the dual-meaning handler.
for row = 1, 2 do
  for col, key in ipairs(GRID_ROWS[row]) do
    table.insert(hotkeys, hs.hotkey.bind({ "ctrl", "alt" }, key, function()
      moveFocusedToCell(col, row)
    end))
  end
end
for col, key in ipairs(GRID_ROWS[3]) do
  table.insert(hotkeys, hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    moveFocusedToRow3(col)
  end))
end
for key, rectFor in pairs(HALF_KEYS) do
  table.insert(hotkeys, hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    moveFocusedTo(rectFor)
  end))
end
for key, spec in pairs(BAND_KEYS) do
  table.insert(hotkeys, hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    placeFocused(bandRect(activeScreen(), spec))
  end))
end
-- shift = "do it to everything", layered on the grid's own ctrl-alt modifier.
table.insert(hotkeys, hs.hotkey.bind({ "ctrl", "alt", "shift" }, KEY.U, function()
  arrangeScreen()
end))

--------------------------------------------------------------------------------
-- App summon keys -- option+F1 / option+F2
--------------------------------------------------------------------------------
--
-- `com.apple.keyboard.fnState = 1` on this machine, so the F-row sends real F1/F2
-- (keycodes 122/120) rather than brightness media keys. The option modifier keeps
-- bare F1/F2 free for apps that use them (originally bound bare, which swallowed
-- the keys everywhere). Carbon hotkeys match the modifier state exactly, so this
-- cannot collide with the cmd+fn Space shortcuts on the same keycodes.
--
-- Press behaviour: summon, or hide if it is already frontmost. One key to both
-- fetch an app and get it out of the way.

-- Keyed on BUNDLE ID, not display name. Names are unreliable: the running process
-- for Vitrinka is `vitrinka-desktop` and for Warp it is `stable`, so name-based
-- lookups produce false negatives. Bundle IDs also let launchOrFocusByBundleID find
-- an app in ~/Applications, which a bare name does not always resolve.
local APP_KEYS = {
  { key = 122, bundle = "com.brave.Browser",   label = "Brave Browser" }, -- F1
  { key = 120, bundle = "com.example.vitrinka", label = "Vitrinka" },     -- F2
}

-- hs.application.get() can hand back a STALE handle for an app that has quit: it is
-- truthy, but its methods are gone (`attempt to call a nil value (method
-- 'isFrontmost')`). Truthiness is therefore not proof the app is running, and the
-- unguarded call threw before the launch branch was ever reached -- so pressing the
-- key on a quit app did nothing at all.
local function runningApp(bundle)
  local app = hs.application.get(bundle)
  if not app then return nil end
  local ok, alive = pcall(function() return app:isRunning() end)
  if not ok or not alive then return nil end
  return app
end

local function summonApp(bundle, label)
  local app = runningApp(bundle)

  if app then
    local ok, front = pcall(function() return app:isFrontmost() end)
    if ok and front then
      pcall(function() app:hide() end)
      return
    end
    pcall(function() app:unhide() end)
    -- true: bring ALL its windows forward, not just the frontmost one
    pcall(function() app:activate(true) end)
    return
  end

  if not hs.application.launchOrFocusByBundleID(bundle) then
    hs.alert.show("Could not launch " .. (label or bundle))
  end
end

for _, entry in ipairs(APP_KEYS) do
  table.insert(hotkeys, hs.hotkey.bind({ "alt" }, entry.key, function()
    summonApp(entry.bundle, entry.label)
  end))
end

--------------------------------------------------------------------------------
-- Desktop (Space) switching -- fn+shift+arrows
--------------------------------------------------------------------------------
--
-- fn is NOT a Carbon hotkey modifier, so hs.hotkey.bind cannot express this; it
-- needs a raw event tap that reads the fn flag itself.
--
-- macOS also rewrites fn+arrow into Home/End before apps see it -- but MEASURED on
-- this keyboard, the same combo arrives sometimes as Home/End (115/119) and
-- sometimes as Left/Right (123/124). Both forms are therefore accepted.

local SPACE_DELTA = {
  [115] = -1, [123] = -1, -- Home / Left  -> previous desktop
  [119] = 1, [124] = 1, -- End / Right -> next desktop
}

-- Do NOT use hs.spaces.gotoSpace(): it switches by OPENING MISSION CONTROL and
-- clicking the desktop, so every switch flashes the full window overview for ~1s.
-- That is not an animation and no animation setting removes it.
--
-- Instead drive macOS's own "Move left/right a space" shortcuts, which the
-- WindowServer handles directly -- instant, no overview. MEASURED on this machine:
-- they are bound to cmd+fn+F1 / cmd+fn+F2 (symbolic hotkeys 79/81, keycodes
-- 122/120). The fn flag is part of the binding, so the synthesized event must set
-- it or macOS ignores the keystroke entirely.
local SPACE_MOVE_KEY = { [-1] = 122, [1] = 120 } -- F1 = left, F2 = right

local function sendSystemShortcut(keycode, flags)
  local down = hs.eventtap.event.newKeyEvent({}, keycode, true)
  down:setFlags(flags); down:post()
  local up = hs.eventtap.event.newKeyEvent({}, keycode, false)
  up:setFlags(flags); up:post()
end

-- Two things measured here, both counter-intuitive:
--
-- 1. The "Switch to Desktop N" shortcuts always act on ONE Spaces set (the built-in
--    display's) regardless of anything else -- with the XDR focused, Desktop-2 moved
--    the built-in. They are useless for multi-display, so nothing uses them.
-- 2. "Move left/right a space" follows the MOUSE POINTER, not the focused window.
--    With focus firmly on the XDR but the pointer on the built-in, move-left moved
--    the BUILT-IN. Put the pointer on the XDR and the same key moved the XDR.
--
-- So the position must be computed on the POINTER's display, or the step count would
-- be derived from one screen while macOS acts on another.
local function pointerScreen()
  return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

local function focusedScreenDesktop()
  local screen = pointerScreen()
  if not screen then return nil, 0, nil end
  local spaces = hs.spaces.spacesForScreen(screen:getUUID()) or {}
  local active = hs.spaces.activeSpaceOnScreen(screen)
  for i, sp in ipairs(spaces) do
    if sp == active then return i, #spaces, screen end
  end
  return nil, #spaces, screen
end

local function stepSpace(delta)
  local keycode = SPACE_MOVE_KEY[delta]
  if keycode then sendSystemShortcut(keycode, { cmd = true, fn = true }) end
end

-- One step on the focused display. macOS clamps at the ends rather than wrapping;
-- wrapping would mean firing (count-1) steps, which visibly flickers through every
-- desktop in between, so it is deliberately not done here.
local function gotoRelativeSpace(delta)
  stepSpace(delta)
end

-- Jump to desktop N of the FOCUSED display by stepping the difference. Displays here
-- hold at most a handful of desktops, so this is a few steps at ~70ms -- still far
-- faster than Mission Control, and correct on every display.
local function gotoDesktop(n)
  local idx, count = focusedScreenDesktop()
  if not idx or not n or n > count then return false end
  local delta = n - idx
  if delta == 0 then return true end

  local dir = delta > 0 and 1 or -1
  local remaining = math.abs(delta)
  local function fire()
    if remaining <= 0 then return end
    remaining = remaining - 1
    stepSpace(dir)
    if remaining > 0 then hs.timer.doAfter(0.07, fire) end
  end
  fire()
  return true
end

--------------------------------------------------------------------------------
-- Throw window to another Space / display
--------------------------------------------------------------------------------
--
--   option+cmd + left/right        -> move the focused window one desktop (Space)
--                                     over on ITS display, and follow it there.
--   shift+option+cmd + arrows      -> push the focused window to the neighboring
--                                     physical display in that direction.

local function moveWindowToAdjacentSpace(delta)
  local w = hs.window.focusedWindow()
  if not w then return end
  local screen = w:screen()
  local spaces = hs.spaces.spacesForScreen(screen:getUUID()) or {}
  local active = hs.spaces.activeSpaceOnScreen(screen)
  local idx
  for i, sp in ipairs(spaces) do
    if sp == active then idx = i break end
  end
  -- Clamp at the ends, same as macOS's own space switching (no wrap).
  if not idx or not spaces[idx + delta] then return end

  hs.spaces.moveWindowToSpace(w, spaces[idx + delta])
  -- Follow the window. stepSpace acts on the POINTER's display (see the measured
  -- notes above), which in practice is the display you're working on.
  stepSpace(delta)
  hs.timer.doAfter(0.4, function() w:focus() end)
end

-- hs.window's moveOneScreen* pick the nearest screen in that direction and resize
-- the window proportionally to the target screen's frame.
local SCREEN_MOVE = {
  [123] = "moveOneScreenWest",  -- Left
  [124] = "moveOneScreenEast",  -- Right
  [126] = "moveOneScreenNorth", -- Up
  [125] = "moveOneScreenSouth", -- Down
}

table.insert(hotkeys, hs.hotkey.bind({ "alt", "cmd" }, 123, function() moveWindowToAdjacentSpace(-1) end))
table.insert(hotkeys, hs.hotkey.bind({ "alt", "cmd" }, 124, function() moveWindowToAdjacentSpace(1) end))
for key, method in pairs(SCREEN_MOVE) do
  table.insert(hotkeys, hs.hotkey.bind({ "shift", "alt", "cmd" }, key, function()
    local w = hs.window.focusedWindow()
    if w then w[method](w, false, true, 0) end
  end))
end

if _spaceTap then _spaceTap:stop() end
-- fn+shift+<number> jumps straight to that desktop.
local DESKTOP_FROM_KEY = { [18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5, [22] = 6 }

_spaceTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  local fl = e:getFlags()
  if not (fl.fn and fl.shift) then return false end
  if fl.cmd or fl.alt or fl.ctrl then return false end -- leave richer combos alone

  local keycode = e:getKeyCode()

  local delta = SPACE_DELTA[keycode]
  if delta then
    gotoRelativeSpace(delta)
    return true -- swallow, so Home/End does not also jump the cursor in a terminal
  end

  -- Only jump to a desktop that actually exists; pressing fn+shift+8 with 6
  -- desktops open passes the key through instead of firing a dead shortcut.
  local desktop = DESKTOP_FROM_KEY[keycode]
  if desktop then
    local _, count = focusedScreenDesktop()
    if desktop <= count and gotoDesktop(desktop) then return true end
  end

  return false
end)
_spaceTap:start()

-- Exposed for testing from the shell:  hs -c 'WarpSlots.cell(2, 3)'
WarpSlots = {
  hotkeyCount = #hotkeys,
  cell = moveFocusedToCell,     -- WarpSlots.cell(col, row) on the active display
  -- Pure geometry for the same cell, with no focused window involved: the hotkey
  -- path depends on which window is frontmost, which is exactly what a shell test
  -- cannot control. WarpSlots.rect(5, 1) is testable, WarpSlots.cell(5, 1) is not.
  rect = function(col, row, screen)
    screen = screen or activeScreen()
    local cols, rows = shapeFor(screen)
    if col > cols or row > rows then return nil end
    return cellRect(screen, cols, rows, col, row)
  end,
  arrange = arrangeScreen,      -- tile every window on the active display
  shape = function()            -- what grid the active display is using right now
    local s = activeScreen()
    local cols, rows = shapeFor(s)
    return string.format("%s: %dx%d (%s)", s:name(), cols, rows,
      isPortrait(s) and "portrait" or "landscape")
  end,
  summon = summonApp,           -- WarpSlots.summon("com.example.vitrinka")
  desktop = gotoRelativeSpace,  -- one step on the pointer's display
  jump = gotoDesktop,           -- absolute desktop N on that display
}

-- Reload this file on save. init.lua is a SYMLINK into the pultik repo, and
-- pathwatcher does not follow symlinks -- watching only hs.configdir misses edits to
-- the real file, so the resolved directory is watched too. The resolved directory is
-- also where sibling modules (organize.lua) live -- a plain require() would only
-- search hs.configdir, which holds nothing but the symlink.
local packageDir = hs.configdir
hs.pathwatcher.new(hs.configdir, function() hs.reload() end):start()
local realInit = hs.fs.symlinkAttributes(hs.configdir .. "/init.lua", "target")
if realInit then
  local realDir = realInit:match("^(.*)/[^/]+$")
  if realDir and realDir ~= hs.configdir then
    packageDir = realDir
    hs.pathwatcher.new(realDir, function() hs.reload() end):start()
  end
end

-- The organize engine: watcher + registry + `.organize` workspace routing.
-- WarpSlots.arrange is handed over so organize tiles with exactly the same
-- geometry as the manual ctrl-alt-shift-U key.
Organize = dofile(packageDir .. "/organize.lua")
Organize.start({ arrange = arrangeScreen })

hs.alert.show("Hammerspoon: Pultík package loaded")
