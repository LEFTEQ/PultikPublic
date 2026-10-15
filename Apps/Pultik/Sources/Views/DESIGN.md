# Pultík design system (D11)

Apple's macOS 26 language in native SwiftUI, vitrinka's default palette,
Switcheroo's density. macOS 26+ only: Liquid Glass APIs are used directly,
with no fallback branches. Record: `docs/specs/2026-10-08-copilot-shell-decisions.md`
D11, which supersedes Panel Home D6 where they differ. Tokens live in
`Theme.swift`, and views consume them. Never retype a literal. The HTML mock
kit that takes are drawn with mirrors this file one-to-one (`kit.css`), and
its `topbar.html` is the decided top bar every frame pastes unchanged.

## 1. Two layers

| Layer | What sits there | How it is drawn |
|---|---|---|
| **Control** (Liquid Glass) | the top bar (full-width search field + scope chip and the app badge, then the module strip that is the switcher), segmented controls, toolbars and detail verbs, the status footer, popovers | The panel root is one `GlassEffectContainer`. The window glass is `.glassEffect(.regular.tint(Theme.canvas.opacity(0.78)), in: .rect(cornerRadius: 26))`: tinted toward the canvas, so a red or busy wallpaper never tints the chrome and red stays an accent. Controls on that glass use vibrant fills (`.fill.quaternary`, white 6–14 %), never a second glass, and still read as floating: a specular rim (a 1 pt `strokeBorder` gradient, white 55 % at the top-leading edge → 3 % → 16 % at the bottom-trailing), an inner shadow along the lower edge (`.fill(.quaternary.shadow(.inner(color: .black.opacity(0.3), radius: 2.5, y: -2)))`) and a soft drop shadow onto the content below (`.shadow(color: .black.opacity(0.5), radius: 13, y: 10)`). Controls floating over content use `.buttonStyle(.glass)` / `.glassProminent` |
| **Content** (near-black) | lists, tables, detail, charts, tiles | One opaque sheet, `Theme.canvas`, inset 8 pt inside the glass with concentric corners (`ConcentricRectangle` / `.rect(corner: .containerConcentric)`). Tiles are quiet `Theme.surface` fills with a 1 pt top highlight, not glass and not stroked boxes |

Rules: never stack glass on glass. Glass is never used for data. Content
scrolls under the top bar with `.scrollEdgeEffectStyle(.soft, for: .top)`.
The panel is always dark (`.preferredColorScheme(.dark)` on the root), and
`.tint(Theme.accent)` is set on the root, so no system blue ever leaks into a
control.

## 2. Colour: one meaning per colour

| Token (`Theme.`) | Hex | Meaning (only this) |
|---|---|---|
| `canvas` | `#141213` | content layer, the near-black warm ink |
| `canvasDeep` | `#0f0e0f` | wells inside content: logs, code, empty meter tracks |
| `surface` | `#1d1a1b` | tiles and grouped rows on the canvas |
| `surfaceRaised` | `#252122` | hovered rows, table header band, raised fills |
| `hairline` | `#292526` | quiet dividers between rows |
| `hairlineStrong` | `#363132` | group dividers, kbd borders, meter tracks |
| `ink` | `#f0eae4` | primary text and hero numbers |
| `ink2` | `#a8a099` | secondary text, meta, units |
| `ink3` | `#8c857f` | micro-labels, column headers, idle values (≥ 4.5:1) |
| `accent` | `#ff3b57` | **selection edge, focus, primary action, brand.** Never a status, never a value colour and never a fill behind a row |
| `accentSoft` | `#ff3b57` @ 12 % | the search field's scope chip and a selected filter chip, only |
| `selection` | white @ 7.5–10 % | the selected row's neutral glass lift (vitrinka's sidebar grey) |
| `ok` | `#53c07e` | healthy, passed, up, alive (pulse) |
| `warn` | `#f5b83d` | needs you, waiting, stale, threshold near |
| `danger` | `#ff6369` | failed, critical, over threshold, overdue |
| `idle` | `ink3` | parked, unknown, no data, blind |
| `eve` | `#bf5af2` | eve and agent identity, glyphs and the eve chip only |
| `data` | `#d6c7b6` | single-series charts: bars, sparkline, the current hour at `ink` |
| `dataMuted` | `#6b625b` | past or secondary series, chart grid labels |
| `heat` | `#e8703a` | activity intensity: heatmap cells (0.18 to 1.0 opacity) and the streak flame |

**Banned:** `Color.blue`, `.accentColor` without the root tint, system link
blue, blue-grey neutrals, and vitrinka's `#4f9cf9` "in-review" blue (in review
reads `warn`). Running reads as `ok` drawn as a spinning ring, which is a
different shape from a passed check.

**Selection** is a neutral glass lift — the `selection` fill, a 1 pt top
highlight and a 1 pt shadow — plus a thin 2 pt `accent` leading edge
(vitrinka's menu rule). It is never a red fill: the rows that get selected
are usually failures, and a red-tinted selected row reads exactly like a
failing one. Red fills (`danger` @ 8–16 %) mean danger only. **Focus** is a
2 pt `accent` ring, except on the search field: it is always focused, so it
keeps a neutral 1 pt hairline and the red lives on its caret and scope chip.
**Segmented controls** keep the system's neutral glass
thumb: the accent marks the selected *object*, not the control state.

**Project identity** (`ProjectGlyph.tint`) is a gradient fill used inside the
glyph square only, never on text, dots or bars. exampleapp `#e8703a`, assistant-service
`#bf5af2`, vitrinka `#d84a62`, booking `#bb8a33`, example `#3aa06b`, pultik
`#a0705a`, toolkit `#b5916b` (tan), build-server `#6b625b`, forge `#8a7a3c`. No
identity hue sits between 180° and 265°: a periwinkle glyph reads as the
banned blue.

## 3. Typography

The system font throughout. SwiftUI picks SF Pro Text below 20 pt and SF Pro
Display at 20 pt and above. Figures always use `.monospacedDigit()`. Hero
and stat numbers are **SF Pro Rounded** (`.fontDesign(.rounded)`); a flat SF
Pro hero is a bug. (The HTML kit embeds SF Pro, SF Pro Rounded and SF Mono
subsets, because the board's Chromium has no Apple fonts and ignores
`ui-rounded`.)

| Token (`Theme.Typo.`, since `Theme.Type` is the metatype) | SwiftUI | Use |
|---|---|---|
| `hero` | `.system(size: 44, weight: .bold)` + `.fontDesign(.rounded)` + `.monospacedDigit()` | the one number a tile leads with (`.contentTransition(.numericText())`) |
| `heroUnit` | `.title3.weight(.medium)`, `ink2` | unit after the hero, baseline-aligned, 6 pt gap |
| `stat` | `.system(size: 22, weight: .semibold)` + `.fontDesign(.rounded)` + `.monospacedDigit()` (18 pt in compact strips) | stat strip values |
| `detailTitle` | `.system(size: 20, weight: .semibold)` | the detail header's object title |
| `title` | `.system(size: 13, weight: .semibold)` | tile titles, row titles that need weight |
| `body` | `.system(size: 13)` | row titles, prose |
| `meta` | `.system(size: 11)`, `ink2` | second lines, captions, deltas |
| `micro` | `.system(size: 10, weight: .semibold, design: .monospaced)` + `.tracking(1.4)` + `.textCase(.uppercase)`, `ink3` | section and column labels, tile kickers, kbd hints. This is vitrinka's nav voice |
| `figure` | `.system(size: 12, design: .monospaced)` | table figures, ids (`FIX-1365`, `#8812`), durations, branches |
| `code` | `.system(size: 11.5, design: .monospaced)` | logs and diffs on `canvasDeep` |

Hierarchy is carried by size and weight before colour: hero, then stat, then
title, then body, then meta, then micro. Content titles stay sentence case.
Only `micro` is uppercase.

A figure and its unit are **one `Text` run in one font** (`5.5 GB free`,
`83 °C`, `3274 rpm`). In prose — meta lines, the footer, captions — figures
use the surrounding body font with `.monospacedDigit()`; the monospaced
design (`figure`) is for table cells, ids, branches and code only. Monospaced
digits followed by a proportional unit leave a double-width gap.

## 4. Spacing and corners

The grid is 4 pt with half-steps: `2 4 6 8 10 12 14 16 20 24`. The panel's
outer inset is 8. Tile padding is 14, gaps between tiles are 10, rows inside
a tile have a 6 pt horizontal inset, and the gap between label and value is 4.
A tile has one content edge, its 14 pt padding: headings, captions, meters,
buttons, group headings and every row's text and figures end on it. Only a
row's hover or selection band and a table's header band bleed the 6 pt row
inset past it, so their text still lands on the content edge.

Corners are concentric: `inner = outer − inset`.

| Shape | Radius | API |
|---|---|---|
| panel | 26 | window glass shape |
| content sheet (inset 8) | 18 | `.rect(corner: .containerConcentric)` |
| tile | 14 (corner tiles concentric) | `RoundedRectangle(cornerRadius: 14, style: .continuous)` |
| row, hover, selection | 8 | same, `.continuous` |
| small and medium controls | 8 | macOS 26 keeps rounded rects for density |
| search, chips, segmented, large buttons, footer pills | capsule | `Capsule()`, `.buttonBorderShape(.capsule)` |
| kbd hint | 4 | |
| project glyph | size × 0.28 | |

## 5. Density (borrowed from Switcheroo)

- Table rows are 22 pt: `figure` 12 pt, 3 pt vertical padding. Two-line list
  rows are 38 pt (3 + 17 title + 1 + 14 meta + 3), and single-line list rows
  are 28 pt.
- **An id never ellipsizes** (`EXAMPLEAPP-API-9Q`, `#412`, `FIX-1365`). Ids lead
  the meta line, so only the prose after them truncates; where an id must
  sit mid-line it gets `.layoutPriority(1)` and the prose truncates instead.
  Columns are sized so no Now subtitle truncates at 1240 pt.
- Lists whose titles are the content (Work tasks) allow two-line titles
  (`.lineLimit(2)`); ids and `n/m` progress move to the meta line.
- Name every pool, box or host (`devbox a 5.5 GB free`), never a bare letter.
- Every tile leads with data: a hero, a stat strip or the first row. There is
  no empty header band and no prose intro.
- Figures are right-aligned in fixed-width columns (`.frame(width:alignment:.trailing)`),
  so digits stack. Value colour comes from its threshold (`ok`, `warn`,
  `danger`), and the label stays `ink3`.
- Meters are 4 pt tall, with the label and value on the same line above them.
- Charts are small and labelled in place: hour bars are 56–72 pt tall,
  sparklines 72×16, and the heatmap uses 10 pt cells with a 2 pt gap.
- Nothing is empty. If a source has nothing, the tile collapses to one
  "All quiet" line, and when the source is unreachable the tile disappears.
- Glyph, title, meta and trailing figure share one baseline in a row
  (`ListRow`); a table's figures share fixed-width columns.

## 6. One number format (`PultikFormat`, `Sources/Support/PultikFormat.swift`)

| Kind | Format | Examples |
|---|---|---|
| ratio of sizes | `used/total UNIT`. The unit appears once and is SI decimal. Use one decimal for TB, and for values under 10 | `119/147 GB`, `1.4/1.7 TB`, `0/96 GB`, `5.5 GB free` |
| ratio of counts | `n/m` | `9/32`, `6/6`, `0/7`, `5/5` |
| percent | integer, except rates where tenths matter (errors, cache, shares) | `93%`, `58%`, `0.0%`, `98.0%` |
| delta | signed, `ink2` unless the delta itself is a verdict | `+139%`, `+83%` |
| duration | `Xs`, `Xm Ys`, `Xh Ym`, `Xd`, with no space inside a component | `3s`, `1m 1s`, `3m 12s`, `2h`, `9d` |
| relative time | duration + `ago`. Units: `s` (seconds), `m` (minutes), `h` (hours), `d` (days) | `4m ago`, `3h 12m ago`, `1d ago` |
| clock | 24-hour `HH:MM` | `09:00`, `as of 15:12` |
| date | `MMM d`, plus the year only when it is not this year. ISO only inside detail metadata | `Oct 2`, `Oct 21` |
| large count | 3 significant figures + `K` or `M`. A hero `B` keeps two decimals | `8.11 B tokens`, `600 M` |
| latency, temperature, speed | value, space, unit | `8 ms`, `83 °C`, `3274 rpm` |

## 7. States

| State | Look | Notes |
|---|---|---|
| loading (first launch, no snapshot) | `surfaceRaised` skeleton bars at the real row geometry, shimmering at most 1.2 s | D8 snapshots make this rare |
| stale | values at 60 % opacity plus an `ink3` caption `as of 15:08` with `clock` | the snapshot is older than its schedule |
| prod blind | hollow `idle` ring, `blind since 14:52` in `warn` | prod is never green from a snapshot |
| partial | dashed `hairlineStrong` chip, e.g. `logs not shipped` | the coverage gap is named |
| unreachable | tiles and rails are **hidden**; the module and its strip chip stay, the chip without a signal | never an alert or modal (CLAUDE.md) |
| all quiet | one row: `ok` check, `All quiet`, `as of 15:12` | never a blank tile |
| needs you | `warn` dot, and the count appears in the status strip | |

## 8. Component catalog

Each component is one SwiftUI view in `Sources/Views/Kit/`, and each has a
`kit.css` class of the same name.

| Component (`.css`) | Anatomy | macOS 26 SwiftUI |
|---|---|---|
| **HeroStat** (`.hero`) | micro label · 44 pt rounded number + unit · delta line (`meta`, signed, coloured only when it is a verdict) | `Text` + `.contentTransition(.numericText())`, `.animation(.snappy)`; HStack `.lastTextBaseline` |
| **StatStrip** (`.stat-strip`) | 3–5 cells: micro label, 22 pt value, `meta` caption; cells separated by hairlines | `Grid` with `GridRow`, `Divider().frame(height:)` |
| **DataTable** (`.dtable`) | micro header band on `surfaceRaised`; 22 pt rows; leading identity column, trailing fixed-width figure columns coloured by threshold; group headings in `micro` | `Grid(alignment: .leading)` or `Table` with `.tableStyle(.inset)` and `.alternatingRowBackgrounds(.disabled)` |
| **SegmentedControl** (`.seg`) | recessed capsule track with a specular rim; neutral glass thumb (lens fill, bright top-leading edge, lifted shadow); labels with optional counts. Its selection always agrees with the search scope (`CI × failed` selects `Failed 3`) | `Picker(...).pickerStyle(.segmented)`, `.controlSize(.small)` |
| **Chip** (`.chip`) | capsule, 20 pt tall, `micro` or `meta` text; variants: neutral, ok, warn, danger, eve, dashed (partial), selected (accent). **Check chips**: the failing check leads, `danger` fill + ring with an `xmark` (`jobs stuck`); passing checks stay neutral with a 5 pt `ok` dot (`● API 8 ms`) | `Text` + `.padding(.horizontal, 7)` + `.background(tint.opacity(0.14), in: Capsule())` |
| **StatusDot** (`.dot`) | 7 pt dot: ok, warn, danger or idle; `.ring` hollow = blind; `.pulse` = alive; `.spin` = running | `Circle()`; pulse uses `.symbolEffect(.pulse)` on `circle.fill`; spin uses `ProgressView().controlSize(.mini)` tinted `ok` |
| **MeterBar** (`.meter`) | label · value on one line; 4 pt capsule track (`hairlineStrong`); fill coloured by threshold (< 70 % ok, < 90 % warn, else danger); an optional floor tick | `Gauge(value:).gaugeStyle(.linearCapacity)` with a custom `GaugeStyle` |
| **HourBars** (`.hours`) | 24 slots, 00→now; past bars in `data`, the current hour in `ink`, failures stacked in `danger`; axis labels 00·06·12·18 in `micro` | Swift Charts `BarMark`, `.chartXAxis` stride 6, `.chartYAxis(.hidden)` |
| **Heatmap** (`.heatmap`) | 12 weeks × 7 days, 10 pt cells, radius 2; a scale caption on the heading line (`best 25 B · Sep 24`); empty past days `ink` @ 6 %; future days hollow 1 pt outlines at `ink` @ 22 %; `heat` at `0.18 + 0.82 × √(v/max)`; today ringed in `ink`; a `less ▪▪▪▪ more · ▢ ahead` legend | Swift Charts `RectangleMark`, cornerRadius 2; future cells `.foregroundStyle(.clear)` + an outlined `RectangleMark` |
| **Sparkline** (`.spark`) | 72×16 area plus line in `data`; area fades from 35 % to 0 % | Swift Charts `AreaMark` + `LineMark`, `.interpolationMethod(.catmullRom)` |
| **ProjectGlyph** (`.glyph`) | 18 or 20 pt square, radius × 0.28, identity gradient, white SF Symbol at 0.5 × size | `RoundedRectangle` + `LinearGradient` + `Image(systemName:)` |
| **ListRow** (`.row`) | glyph or dot · title (`body`) · meta line led by the id · trailing figure, time or chip; hover `surfaceRaised`; selected = neutral `selection` lift + 2 pt accent leading edge, never a red fill | `Button` with a custom `ButtonStyle`; selection held by object id |
| **DeploymentCard** (`.dep`) | verdict dot (pulsing when critical) · name · firing chip; check chips (failing first); mini HourBars of err/warn with the 24h totals; the top issue with its id | `VStack` of the parts above; chips in a flow `Layout` |
| **DetailHeader** (`.dhead`) | glyph · `detailTitle` · status chip; meta line in `figure`; verb row: one `glassProminent` primary in accent, then `.glass` verbs, each with a kbd hint | `.buttonStyle(.glassProminent)` tinted `accent`, `.buttonStyle(.glass)`, `.keyboardShortcut` |
| **ContextBand** (`.cband`) | one `surface` strip under the detail header: the related object (PR, deployment, task), with its chips and a trailing `⌘↵ open` | `HStack` on `Theme.surface` with radius 8 |
| **LogWell** (`.well`) | `canvasDeep` inset, `code` lines with a gutter; the failing line gets a `danger` rule and an 8 % wash; long lines wrap | `ScrollView` + `LazyVStack` of `Text`, `.textSelection(.enabled)` |
| **KbdHint** (`.kbd`) | `⌘R`, `↵`, `⌘1`, in `micro` on a 1 pt `hairlineStrong` border, radius 4 | `Text` with `.overlay(RoundedRectangle(cornerRadius: 4).stroke(...))` |
| **TopBar** (`.topbar`, `topbar.html`) | two rows, 100 pt, identical in every module except the current chip and the search state: the SearchField at full width with the app badge at its right, then the ModuleStrip | `VStack(spacing: 8)` on the window glass, padding 12/14 |
| **SearchField** (`.search`) | 36 pt vibrant capsule (specular rim, inner shadow, drop shadow): magnifying glass, scope chip with the module's glyph (`CI ×`, accent-soft; none on Home), query, accent caret, trailing result count, a hairline, `modules ⌘1–9` and `esc` kbd. Always focused, so a neutral 1 pt hairline and never a red ring | `TextField` with `.textFieldStyle(.plain)` in a capsule with a `.fill.quaternary` background and a `white.opacity(0.14)` stroke; `.tint(Theme.accent)` colours the caret; scope chip is a `Button`; Backspace on an empty field removes the scope |
| **ModuleStrip** (`.mods` › `.mod`) | the status strip *is* the switcher (D5-A): nine 34 pt vibrant capsules, Home · PRs · CI · Prod · Devbox · Work · Sessions · Estate · Mac on ⌘1–9, sharing the row's width. Each is a glyph, a name and its live signal at its trailing end (a warn count pill, `✗ 3 failed`, prod dots, `30 stale`, `✋ 2 waiting`, `🔔 8 firing`, `disk 94%`). The current module is the neutral `selection` lift plus a 2 pt accent leading edge and an accent glyph, never a red fill. A module in danger (Prod while a deployment is critical) is the one danger-washed capsule and widens to say why (`ExampleApp prod · jobs stuck +1`) | `HStack(spacing: 6)` of `Button`s with a custom capsule `ButtonStyle` on `.fill.quaternary` (no glass on glass); `.keyboardShortcut("1"…"9")`; the lift moves with `matchedGeometryEffect` |
| **StatusFooter** (`.footer`) | 3 pt progress line on top (`ok`→`warn`→`danger` by value), **labelled at its end** in `micro` (`ohexampleapp 5h 93% left`); the bar below never repeats that value: sync state, the live pulse (sessions running), a sparkline with its figure, waiting count, the account's weekly quota, tokens today; trailing refresh, settings and quit | `ViewThatFits` drops the sparkline first, then the tokens; `Capsule` track + fill |
| **Tile** (`.tile`) | `surface` fill, radius 14, padding 14, micro kicker + trailing caption, a 1 pt top highlight | `.background(Theme.surface, in: .rect(cornerRadius: 14))`, `.overlay(alignment: .top)` highlight |
| **Button** (`.btn`) | `.btn.prim` is red prominent glass; `.btn` is neutral glass; `.btn.plain` is text-only `ink2` | `.glassProminent` + `.tint(Theme.accent)`, `.glass`, `.plain` |
| **RunBadge** (`RunBadgeView`) | one CI run on a change request: its state's shape (✗ / spinning dot / ✓ / –), the workflow, the failing job in `danger` or the passed/total count, a live timer while running, the lane and its queue in `warn`; `danger`-washed when it failed; the ⇥ focus ring is a 2 pt accent capsule | `Button` on a `Capsule` fill; `TimelineView(.periodic)` only while the panel is presented; `.contentTransition(.symbolEffect(.replace))` |
| **StackCard** (`StackedDetail`) | a card sliding up over the detail, which stays dimmed (42 %) with its header and badges peeking 92 pt above; deeper cards 14 pt lower; a click on the dimmed layer or Esc slides the top one away | `ZStack` + `Theme.Motion.card` transition, `push`/`pop` springs |
| **DetailTabs** (`DetailTabs`) | a detail's tabs (PR workbench): titles with counts (a verdict count in `danger`), the shown one in `ink` and `title` weight over a 2 pt accent underline that glides; a hairline under the row; while entered, trailing `← →` tabs · `esc` list hints | `HStack` of plain `Button`s; `matchedGeometryEffect` underline; `Theme.Motion.tab` |
| **CodeCanvas** (`CodeCanvasView`) | a diff in the selected code theme (`CodePalette` over `Packages/Theme`, Settings ▸ Code), not `Theme`: the theme's canvas, added/removed washes, gutters and marks (soft, see the themes record), the gutter's two figure columns and ± marker, hunk bands, a sticky file header with status letter and `+a −r`; wrapped under the gutter; a 3 pt accent mark on lines with a comment | AppKit: `NSScrollView` over a flipped view, one opaque `RGBA8Uint` layer per row near the viewport drawn with CoreText |
| **GFM** (`GFMBlockView`) | a description in Pultík's own blocks: headings, paragraphs with `ink` underlined links, `canvasDeep` code wells, tables, task boxes, quotes on a hairline rule, alerts on a tinted rule (note `data`, tip `ok`, important `eve`, warning `warn`, caution `danger`), `<details>` as a disclosure | swift-markdown AST → `GFMBlock`; `Text(AttributedString)`, `Grid`, `AsyncImage` |

## 9. Never

- Blue anything, including system link blue: every link is `ink` with an
  `arrow.up.right` symbol.
- Glass on glass, or glass under data.
- Colour as the only signal: a status always has a shape (dot, ring, ✗, ✓)
  or text.
- A second meaning for a colour: the accent is never "error", and `danger`
  is never "selected". A selected row or module chip is never red-filled,
  and the search field never wears a red ring.
- An ellipsized id, an unlabelled progress line, or a bare pool letter.
- A segmented control or list that disagrees with the search scope it sits
  under.
- Rainbow categorical charts. Charts are single-series `data`, or a status
  split (err `danger`, warn `warn`).
- A tile without data, a placeholder string, an alert for an unreachable
  backend, or prod green from a snapshot.

## 10. Motion (`Theme.Motion`)

Every animated change takes a token, and every token degrades to a 0.15 s
crossfade under Reduce Motion (`accessibilityReduceMotion`).

| Token | Use | Curve |
|---|---|---|
| `status` | a badge, chip or dot changing state; its symbol replaces with a one-shot effect | ease-in-out 0.22 s |
| `push` | a card sliding up over its detail | spring 0.34 s, bounce 0.12 |
| `pop` | a card sliding away — shorter, flat | spring 0.24 s, no bounce |
| `focus` | the ⇥ ring moving | snappy 0.14 s |
| `swap` | a module body swapping in once the strip's keys settle | snappy 0.18 s |

Timers count with `.contentTransition(.numericText())` and tick only while
the panel is presented. Never a raw curve in a view.
