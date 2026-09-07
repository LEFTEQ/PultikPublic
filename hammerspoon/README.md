# Hammerspoon package

The managed window-management config: orientation-aware grid keys, band keys,
Space switching, app summon, arrange-all — and the `.organize` workspace
engine (`organize.lua`). Installed by `pultik install --hammerspoon`, which
symlinks `~/.hammerspoon/init.lua` here (repo checkout when present, embedded
copy otherwise). Migrated from PersonalSetup 2026-09-01; decision record:
`../docs/specs/2026-09-01-organize-workspaces-decisions.md`, plus the
historical grid decision logs still in PersonalSetup's `docs/specs/`.

`.organize [layout]` (Pultík palette) routes every Warp window to the display
its project belongs on, tiles each display's grid, and spawns windows for
missing projects. Window→project identity is observed, never divined: a
persistent watcher records every path-like Warp title into a registry
(`~/Library/Application Support/Pultik/organize-registry.json`); Claude
session titles never erase an entry. Layouts live under `workspaces.layouts`
in Pultík's `settings.json`; a built-in default ships in `organize.lua`.
Debug helpers: `hs -c 'Organize.status()'` (what the registry knows),
`hs -c 'Organize.layouts()'`, `hs -c 'Organize.run("default")'`.

## What the keys do

Everything is driven from Hammerspoon. The grid follows the **active display**, so
one key set works on every monitor.

The keyboard is a **scale model of the screen**: keyboard row → screen row, keyboard
column → screen column. A display using C columns × R rows takes the top-left C×R
corner of the key block, so one key set covers every shape without per-display config.
Keys outside a display's shape do nothing there.

```
  U  I  O  P  ú     ultrawide 5×2   U I O P ú / J K L Ů §
  J  K  L  Ů  §     landscape 4×2   U I O P   / J K L Ů
  M  ,  .  -        portrait  3×3   U I O     / J K L     / M , .
                    Sidecar   2×2   U I       / J K
```

The 5×2 is the 4×2 with a column **appended**, not a re-layout: `U`…`P` and `J`…`Ů`
keep the exact cells they had, and `ú` / `§` are the new column 5. Only rows 1–2 have
a fifth key — no grid is five columns *and* three rows, and the `M , . -` row has no
fifth key to give.

| Keys | Action |
|---|---|
| `⌃⌥` + the grid block above | Move the focused window into that cell. Any app, always. |
| `⌃⌥⇧` + `U` | **Tile every window on the active display** into its grid |
| `⌃⌥` + `Y X C` | Thirds bands — landscape: full-height columns 1–3 · portrait: full-width rows 1–3 |
| `⌃⌥` + `Q W E` | Same thirds, top half (landscape) / left half (portrait) |
| `⌃⌥` + `A S D` | Same thirds, bottom half (landscape) / right half (portrait) |
| `⌃⌥` + `M , . -` | Full-height quarter columns 1–4 — but only where the grid has fewer than 3 rows; on the portrait 3×3 these keys are the grid's third row instead. They stay *quarters* on the 5×2, so there they no longer line up with grid columns |
| `⌃⌥` + `↩` | Maximize (fills the screen frame, not native fullscreen) |
| `⌃⌥` + arrows | Half the screen on the side the arrow points to |
| `⌥⌘` + `←` `→` | Move the focused window one desktop over on its display, and follow it |
| `⇧⌥⌘` + arrows | Push the focused window to the neighbouring display |
| `fn⇧` + `←` `→` | Previous / next desktop on the pointer's display |
| `fn⇧` + `1`–`6` | Jump to that desktop on the pointer's display |
| `F1` | Summon Brave Browser — launches it if not running, hides it if already frontmost |
| `F2` | Summon Vitrinka — same |

Bare F-keys are safe to bind here because `com.apple.keyboard.fnState = 1` (the F-row
sends real F1/F2, not brightness), and every system binding on those keycodes requires
`⌘fn`, which Carbon matches exactly.

Grid shape is resolved per display, on every keypress:

| Display | Shape | Why |
|---|---|---|
| landscape, ≥ 3000pt wide | 5×2 | Pro Display XDR 3008×1662 → 602×831 cells; four columns there are 752pt, wider than anything needs |
| anything else wider than tall | 4×2 | the default |
| anything taller than wide | 3×3 | e.g. the Studio Display pivoted 270° — 1620×2850 → 540×950 cells |
| Sidecar (pinned by UUID) | 2×2 | 1194pt wide; a 4×2 there would give 298pt columns |

Pins in `SHAPE_BY_SCREEN` beat every rule; orientation beats width.

Width is measured in **points off `frame()`**, not pixels — HiDPI scaling is already
divided out, so the XDR reads 3008 rather than its 6016 native pixels. It clears the
threshold by only 8pt: switching it to "Larger Text" scaling (2560pt) drops it back to
4×2. Run `hs -c 'WarpSlots.shape()'` after any resolution change rather than assuming.

Orientation and width are both read off the display's live **frame**, not off a UUID —
pivoting or rescaling a monitor in System Settings changes the grid with no config
edit. A UUID pin in `SHAPE_BY_SCREEN` still overrides the rule for a display that
needs something odd.

## Measured findings

These are the non-obvious things. Each was established by measurement, not assumption.

### macOS Spaces navigation follows the MOUSE POINTER, not keyboard focus

With focus firmly on the Pro Display XDR but the pointer on the built-in display,
"move left a space" moved the **built-in**. Move the pointer to the XDR and the same
key moved the XDR.

An earlier test appeared to show it following focus — that was the `focus()` call
itself switching that display's Space as a side effect, not the shortcut. Worth
knowing how easily this one produces a false positive.

### "Switch to Desktop N" is hardwired to one Spaces set

Regardless of focus or pointer, `⌘⇧2` always acted on the built-in display's Spaces.
These shortcuts are useless for multi-display setups. `macos/desktop-shortcuts.sh`
still provisions them (they work fine on a single display) but `init.lua` no longer
uses them — it composes every switch from "move left/right a space" steps instead.

### `hs.spaces.gotoSpace()` opens Mission Control

It does not switch Spaces directly — Apple restricted the private API, so Hammerspoon
falls back to opening Mission Control and clicking the target desktop. That produces a
~1s flash of the full window overview on every switch. It is **not an animation**, so
no animation setting removes it. Reduce Motion does nothing for it.

The fix is to synthesize macOS's own Space shortcuts instead.

### macOS Accessibility cannot see windows on other Spaces

- `app:allWindows()` returns `0` while the app demonstrably has windows
- reading `frame()` / `title()` of an off-Space window **blocks until the AX call
  times out** (>30s, wedging Hammerspoon)
- `hs.spaces.windowsForSpace()` + `bundleID()` *do* work across Spaces — app-level
  lookups are safe, window-level property reads are not

Scanning all Spaces to find where an app lives costs **~2.6s**; checking the current
Space costs **~2ms**. Keep the scan off the hot path — that thousand-fold difference
was the cause of a 10-second keypress latency.

### `hs.accessibilityState()` lies

It reported `false` while window access demonstrably worked (macOS 26 TCC desync).
Trust behavior, not the probe. A Hammerspoon restart resyncs it.

### The Dock reads its animation prefs only at launch

`workspaces-swoosh-animation-off` and `expose-animation-duration` were already set on
this machine but had never taken effect — the Dock process predated the pref write by
22 hours. `killall Dock` applies them.

### fn is not a Carbon modifier

`hs.hotkey.bind` accepts only cmd/alt/ctrl/shift. Anything involving `fn` needs a raw
`hs.eventtap` that reads the flag itself.

macOS also rewrites `fn`+arrow into Home/End — but **inconsistently**: the same combo
arrived as Home/End (115/119) on some presses and Left/Right (123/124) on others. The
tap accepts all four keycodes.

### Czech layout: bind raw keycodes, never characters

The number row types `+ěščřžýáíé`, and `Ů` sits on the `;` key. `hs.keycodes.map`
resolves characters through the *active* layout and silently falls back to US,
logging `key '6' not found in active keymap`. It happened to return the right code,
but that is luck. Number-row physical keycodes:

```
1..9,0  ->  18, 19, 20, 21, 23, 22, 26, 28, 25, 29
```

Note the order: 5=23, 6=22, 7=26, 8=28, 9=25.

### Magnet stores its shortcuts as plain JSON

`~/Library/Preferences/com.crowdcafe.windowmagnet.plist` keeps `horizontalCommands`
and `verticalCommands` as ~19KB of **JSON bytes**, not a keyed archive — directly
readable and editable. `plutil` parses them because it accepts JSON.

Reading Magnet's own data also corrected a misreading: "Grid 1/8 Bottom 4" is
`carbonKeyCode: 41` (the `;` position → `Ů`), not 33 (`[` → `Ú`).

Magnet must be quit before editing, or it overwrites on exit.

### Window IDs are not durable; tile positions are

`CGWindowID` is per-launch, and mapping AX elements to it needs a private API. Any
"remember window X = slot 3" map rots across an app update or display reconnect. The
grid therefore resolves slots by **geometry on every press**, never from a remembered
ID.

Matching is two-tier: a window whose centre falls inside the cell owns it; otherwise
the smallest window merely covering the cell centre answers. Plain nearest-centre
breaks the moment one window is maximized — its centre sits at the screen centre and
wins several cells at once while its own cell reports empty.

### `hs.application.get()` returns a stale handle for a quit app

The handle is **truthy but dead** — its methods are gone, so `app:isFrontmost()` throws
`attempt to call a nil value`. That exception fired before the launch branch was
reached, so pressing the summon key on a quit app silently did nothing. Truthiness is
not proof an app is running; verify with `isRunning()` behind a `pcall`.

### Process names lie — key on bundle IDs

Vitrinka's running process is `vitrinka-desktop`; Warp's is `stable`. `pgrep -x Vitrinka`
and `pgrep -x Warp` both report "not running" while the apps are running fine — a false
negative that cost real debugging twice in one session.

Use bundle IDs (`com.example.vitrinka`, `dev.warp.Warp-Stable`, `com.brave.Browser`) for
both lookup and launching. `launchOrFocusByBundleID` also resolves apps in
`~/Applications`, which a bare name does not reliably do.

### Apps live in ~/Applications too

Onyx and Vitrinka are both installed under `~/Applications`, not `/Applications`. The
setup TUI originally checked only the latter and reported both as missing. Any
app-presence check must search both.

### Smart dispatch was removed — one key, one meaning

Earlier versions resolved cell occupancy, navigated between tiles, and spawned Warp
windows off the same keys. Slot resolution can transiently misread (window
mid-maximize, mid-drag, or on another Space), so the same keypress did different
things on different presses — and a spawn that guessed wrong silently multiplied
windows: two strays in one test run. All of it went on 2026-08-01. Every key now has
exactly one meaning, and the only thing a display changes is the grid's shape.

## Testing notes

`init.lua` exposes helpers for driving it from the shell:

```bash
hs -c 'WarpSlots.shape()'        # which display the keys target, and its grid
hs -c 'WarpSlots.cell(2, 3)'     # focused window -> column 2, row 3 of that grid
hs -c 'WarpSlots.arrange()'      # tile every window on the active display
hs -c 'WarpSlots.desktop(1)'     # one desktop step on the pointer's display
hs -c 'WarpSlots.jump(4)'        # absolute desktop jump
```

Four traps when testing this way:

- **Never use `hs.timer.usleep` inside `hs -c`.** It blocks Hammerspoon's main thread,
  so the async poll timers the code depends on never run — instant deadlock. Use
  shell-side `sleep` between separate `hs -c` calls.
- **A terminal running the test steals focus back** when output arrives, which
  silently contaminates any focus- or Space-dependent measurement. Do the whole
  sequence inside one call with `hs.timer.doAfter`, and read the result afterwards.
- **Keep a reference to every `hs.timer.doAfter` handle.** An unreferenced chain of
  them can stop part-way through with nothing logged — a 7-step keystroke test died
  silently at step 4 and completed once the handles were stashed in a table.
- **A slow `hs -c` call still runs; only its reply is lost.** A chunk that does many
  `setFrame` calls can outlive the CLI's reply window, so `hs` returns nothing while
  the side effects apply perfectly. Never read that as "it didn't work" — stash the
  result in a global and read it back in a second call.
- **`w:title()` and `w:application():name()` can stall for tens of seconds** on a busy
  app, wedging an otherwise instant enumeration. `visibleWindows()` + `isStandard()` +
  `screen()` + `frame()` over 31 windows costs ~0.06s; adding titles hung twice. Keep
  them out of any hot path.

