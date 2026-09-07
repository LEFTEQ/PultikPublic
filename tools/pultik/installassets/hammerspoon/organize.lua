-- The `.organize` workspace engine: route every Warp window (and configured
-- apps) to the display its project belongs on, tile each display's grid, and
-- spawn Warp windows for layout projects that have none.
--
-- WINDOW -> PROJECT IS OBSERVED, NEVER DIVINED. A Warp window is born with a
-- cwd-shaped title, and the title snaps back to the cwd whenever a Claude
-- session isn't overriding it. A persistent watcher records every path-like
-- title it sees into a registry keyed by window id; Claude's session titles
-- ("✳ Devbox CLI redesign") are simply ignored and never erase an entry. At
-- organize time the lookup is a pure registry read. Windows that predate the
-- watcher AND are mid-Claude-session get a one-time fallback: the session
-- title reverse-looked-up in ~/.claude/history.jsonl, which records prompts
-- with their project cwd. Still-unknown windows fall into the `rest` rule --
-- which is where unknowns belong semantically anyway.
--
-- Layouts come from Pultík's settings.json (`workspaces.layouts`), so the app,
-- the palette and this engine can never disagree; the built-in default below
-- serves until the app writes one. Displays are referenced by ordered
-- name-match lists, so an unplugged display degrades (laptop-only collapses
-- everything onto the built-in) instead of erroring.
--
-- Spaces are deliberately NOT targeted in v1: hs.spaces window moves are slow
-- (~0.4s each) and occasionally silently fail (measured notes in init.lua).
-- Decision record: docs/specs/2026-09-01-organize-workspaces-decisions.md.

local M = {}

local WARP_BUNDLE = "dev.warp.Warp-Stable"
local APP_SUPPORT = os.getenv("HOME") .. "/Library/Application Support/Pultik"
local SETTINGS_PATH = APP_SUPPORT .. "/settings.json"
local REGISTRY_PATH = APP_SUPPORT .. "/organize-registry.json"
local HISTORY_PATH = os.getenv("HOME") .. "/.claude/history.jsonl"
local PROJECT_ROOT = os.getenv("HOME") .. "/Work/Projects"

-- Shipped default: assistant-service + ExampleApp on the XDR, vitrinka + the Booking
-- org on the built-in, everything else on the Studio Display. Every role lists
-- "Built-in" last because the built-in display is the one screen that is
-- always attached.
local DEFAULT_WORKSPACES = {
  layouts = {
    default = {
      displays = {
        xdr = { "Pro Display XDR", "Built-in" },
        macbook = { "Built-in" },
        studio = { "Studio Display", "Built-in" },
      },
      rules = {
        { project = "assistant-service", to = "xdr" },
        { project = "example-org/ExampleApp", to = "xdr" },
        { project = "vitrinka", to = "macbook" },
        { project = "Booking", to = "macbook" },
        { rest = true, to = "studio" },
      },
    },
  },
}

--------------------------------------------------------------------------------
-- Project resolution
--------------------------------------------------------------------------------

-- Warp elides long cwds from the left: "..-Technologies/vitrinka",
-- "../infra/build-server-infra". A title is treated as path-like when it carries
-- no whitespace -- Claude session titles are prose and always contain spaces,
-- project directories here never do. Cheap, and wrong only for a directory
-- with a space in its name, which this estate does not have.
local function isPathLike(title)
  return title ~= nil and title ~= "" and not title:find("%s")
end

-- All directories that could be a project cwd, cached per run. Depth 3 covers
-- <org>/<repo> and <org>/infra/<repo>; the second find adds in-repo worktrees
-- (<repo>/.worktrees/<branch>), which sit one level deeper and would otherwise
-- be invisible -- a Warp window living in one titles itself with the worktree
-- dir name alone.
local dirCache = nil
local function knownDirs()
  if dirCache then return dirCache end
  dirCache = {}
  local out = hs.execute("find " .. PROJECT_ROOT .. " -maxdepth 3 -type d -not -name '.*' 2>/dev/null; "
    .. "find " .. PROJECT_ROOT .. " -maxdepth 4 -type d -path '*/.worktrees/*' 2>/dev/null")
  for line in out:gmatch("[^\n]+") do dirCache[#dirCache + 1] = line end
  return dirCache
end

-- Resolve a path-like title to an absolute project directory by suffix match:
-- "..-Technologies/vitrinka" must match ".../example-org/vitrinka".
-- The leading ".." elision becomes a wildcard; everything else matches
-- literally. An unresolvable title is kept RAW -- it still participates in
-- rule matching as a plain string, so a rule naming it keeps working.
local function resolveProject(title)
  local t = title:gsub("^~", os.getenv("HOME"))
  if t:sub(1, 1) == "/" then
    return hs.fs.attributes(t, "mode") == "directory" and t or title
  end
  local pattern = t:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  pattern = pattern:gsub("^%%%.%%%.", "[^/]*") .. "$"
  local best = nil
  for _, dir in ipairs(knownDirs()) do
    if dir:find("/" .. pattern) or dir:find("^" .. pattern) then
      -- Prefer the shortest match: ".../vitrinka" over ".../vitrinka/apps".
      if not best or #dir < #best then best = dir end
    end
  end
  return best or title
end

-- Claude session titles carry a status glyph prefix (✳ ◐ ⏺ ✻ …) before the
-- prose. history.jsonl records every typed prompt with its project cwd, and
-- session titles are distilled from prompts -- so a fixed-string grep for the
-- title text usually lands in the right project's entries. Best-effort by
-- design: a miss returns nil and the window routes as `rest`.
local function historyLookup(title)
  local text = title:gsub("^[^%w]*%s+", "")
  -- Short or generic titles ("Claude Code") match unrelated history lines and
  -- would MISROUTE a window; better to fall into `rest` than to guess. Tested
  -- against the live estate 2026-09-01: distinctive titles hit, generic ones
  -- landed on coincidental prompts.
  if #text < 12 or text == "Claude Code" then return nil end
  if hs.fs.attributes(HISTORY_PATH) == nil then return nil end
  local quoted = "'" .. text:gsub("'", [['\'']]) .. "'"
  local out = hs.execute("grep -F " .. quoted .. " " .. HISTORY_PATH .. " 2>/dev/null | tail -1")
  return out:match('"project":"([^"]+)"')
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

local registry = nil -- [tostring(windowID)] = { project = <abs path or raw title>, seen = epoch }

local function loadRegistry()
  if not registry then registry = hs.json.read(REGISTRY_PATH) or {} end
  return registry
end

local function saveRegistry()
  hs.fs.mkdir(APP_SUPPORT)
  hs.json.write(registry, REGISTRY_PATH, true, true)
end

local function record(w)
  local title = w and w:title()
  if not isPathLike(title) then return end
  local id = w:id()
  if not id then return end
  loadRegistry()
  registry[tostring(id)] = { project = resolveProject(title), seen = os.time() }
  saveRegistry()
end

--------------------------------------------------------------------------------
-- Watcher
--------------------------------------------------------------------------------

-- Global (not local) so an hs.reload() replaces the old watcher instead of
-- leaking a second subscription -- same pattern as _spaceTap in init.lua.
function M.start(deps)
  M.arrange = deps and deps.arrange
  if _organizeFilter then _organizeFilter:unsubscribeAll() end
  _organizeFilter = hs.window.filter.new(function(w)
    local app = w and w:application()
    return app ~= nil and app:bundleID() == WARP_BUNDLE
  end)
  _organizeFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowTitleChanged,
  }, function(w) record(w) end)
  -- Seed from whatever is currently resolvable, so the registry is useful on
  -- the very first load instead of only for windows created after it.
  for _, w in ipairs(hs.window.filter.new(false):setAppFilter("Warp", {}):getWindows()) do record(w) end
end

--------------------------------------------------------------------------------
-- Routing
--------------------------------------------------------------------------------

local function warpWindows()
  local out = {}
  for _, app in ipairs(hs.application.applicationsForBundleID(WARP_BUNDLE)) do
    for _, w in ipairs(app:allWindows()) do
      if w:isStandard() and not w:isFullScreen() then out[#out + 1] = w end
    end
  end
  return out
end

local function projectOf(w)
  loadRegistry()
  local entry = registry[tostring(w:id() or -1)]
  if entry then return entry.project end
  local title = w:title()
  if isPathLike(title) then return resolveProject(title) end
  return historyLookup(title)
end

-- A rule's `project` is matched as a plain substring of the window's project
-- string (absolute path or raw title), with `*` as the one wildcard. Substring
-- is deliberate: "vitrinka" matches both the example-org repo and any
-- worktree under it.
local function ruleMatches(rule, project)
  if not rule.project or not project then return false end
  local pattern = rule.project:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*")
  return project:find(pattern) ~= nil
end

-- First attached screen whose name contains one of the role's ordered match
-- strings. Names, not UUIDs: display names survive re-pairing, and the config
-- stays human-readable.
local function screenForRole(displays, role)
  for _, match in ipairs(displays[role] or {}) do
    for _, s in ipairs(hs.screen.allScreens()) do
      if s:name():find(match, 1, true) then return s end
    end
  end
  return nil
end

-- An empty `"layouts": {}` in settings must fall back to the built-in default,
-- matching the app's WorkspaceLayouts.names() which treats empty as absent --
-- otherwise the palette lists "default" while run("default") finds nothing.
local function configuredLayouts()
  local settings = hs.json.read(SETTINGS_PATH)
  local workspaces = settings and settings.workspaces or DEFAULT_WORKSPACES
  local layouts = workspaces.layouts
  if layouts == nil or next(layouts) == nil then layouts = DEFAULT_WORKSPACES.layouts end
  return layouts
end

local function loadLayout(name)
  return configuredLayouts()[name or "default"]
end

-- Route + tile + spawn. Spawned windows arrive asynchronously, so when any
-- spawn fires the route+tile pass runs a second time after a beat -- the
-- watcher has registered the newcomers by then (their birth title is the cwd).
function M.run(layoutName)
  dirCache = nil
  local layout = loadLayout(layoutName)
  if not layout then
    hs.alert.show("organize: no layout '" .. tostring(layoutName or "default") .. "'")
    return
  end

  -- Prune registry entries whose window is gone; ids recycle rarely enough
  -- that keeping dead entries around is worse than dropping them.
  loadRegistry()
  local live = {}
  for _, w in ipairs(warpWindows()) do live[tostring(w:id() or -1)] = true end
  for id in pairs(registry) do
    if not live[id] then registry[id] = nil end
  end
  saveRegistry()

  local rules = layout.rules or {}
  local restRole = nil
  for _, r in ipairs(rules) do
    if r.rest then restRole = r.to end
  end

  local moved, matchedRules, touched = 0, {}, {}
  local function route(w, project)
    local role = restRole
    for i, r in ipairs(rules) do
      if ruleMatches(r, project) then
        role, matchedRules[i] = r.to, true
        break
      end
    end
    local screen = screenForRole(layout.displays or {}, role)
    if screen then
      if w:screen() ~= screen then
        -- The SOURCE display re-tiles too: a window leaving it leaves a hole,
        -- and "tile each display" (decision 6) means no display keeps gaps.
        local from = w:screen()
        if from then touched[from:id()] = from end
        w:moveToScreen(screen, false, true, 0)
      end
      touched[screen:id()], moved = screen, moved + 1
    end
  end

  for _, w in ipairs(warpWindows()) do route(w, projectOf(w)) end

  -- App rules route every standard window of that bundle, no registry needed.
  for _, r in ipairs(rules) do
    if r.app then
      for _, app in ipairs(hs.application.applicationsForBundleID(r.app)) do
        for _, w in ipairs(app:allWindows()) do
          if w:isStandard() and not w:isFullScreen() then
            local screen = screenForRole(layout.displays or {}, r.to)
            if screen then
              if w:screen() ~= screen then
                local from = w:screen()
                if from then touched[from:id()] = from end
                w:moveToScreen(screen, false, true, 0)
              end
              touched[screen:id()], moved = screen, moved + 1
            end
          end
        end
      end
    end
  end

  -- Spawn a Warp window for every project rule that matched nothing live.
  -- Only rules whose pattern resolves to a real directory can spawn -- a
  -- wildcard like "Booking*" names a family, not a spawnable cwd.
  local spawned = 0
  for i, r in ipairs(rules) do
    if r.project and not matchedRules[i] and r.spawn ~= false then
      local dir = resolveProject(r.project)
      if dir:sub(1, 1) == "/" and hs.fs.attributes(dir, "mode") == "directory" then
        hs.execute('open -a Warp "' .. dir .. '"')
        spawned = spawned + 1
      end
    end
  end

  local function tile()
    if not M.arrange then return end
    for _, screen in pairs(touched) do M.arrange(screen) end
  end
  tile()
  if spawned > 0 then
    hs.timer.doAfter(2.5, function()
      for _, w in ipairs(warpWindows()) do route(w, projectOf(w)) end
      tile()
    end)
  end

  hs.alert.show(string.format("Organized: %d windows%s", moved,
    spawned > 0 and (" (+" .. spawned .. " spawned)") or ""))
  return moved
end

-- Palette support and shell debugging: `hs -c "Organize.layouts()"`.
function M.layouts()
  local names = {}
  for name in pairs(configuredLayouts()) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, "\n")
end

-- What the registry currently knows -- the first thing to check when a window
-- routes somewhere unexpected.
function M.status()
  loadRegistry()
  local lines = {}
  for _, w in ipairs(warpWindows()) do
    local entry = registry[tostring(w:id() or -1)]
    lines[#lines + 1] = string.format("%d  %s  ->  %s", w:id() or -1,
      w:title():sub(1, 48), entry and entry.project or "?")
  end
  return table.concat(lines, "\n")
end

return M
