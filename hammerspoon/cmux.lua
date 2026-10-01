-- App-specific terminal controls. Grid generation lives in the cmux-grid helper;
-- this module owns only macOS focus, physical keybindings and monitor discovery.
local M = {}
local bundleID = "com.cmuxterm.app"
local binary = os.getenv("HOME") .. "/.local/bin/cmux-grid"
local task, watcher, gridKey, zoomKey
local splitKeys, splitTask = {}, nil
local pendingSplits = {}

-- Drain both pipes while cmux runs; waiting until exit can block the CLI.
-- Keep streamed output so identify's JSON and command errors remain available.
local function commandTask(path, callback, arguments)
  local stdout, stderr = {}, {}
  return hs.task.new(path, function(code, out, err)
    table.insert(stdout, out)
    table.insert(stderr, err)
    callback(code, table.concat(stdout), table.concat(stderr))
  end, function(_, out, err)
    table.insert(stdout, out)
    table.insert(stderr, err)
    return true
  end, arguments)
end

local function isCmux()
  local app = hs.application.frontmostApplication()
  return app and app:bundleID() == bundleID
end

local function supportsGrid()
  local info = hs.application.infoForBundleID(bundleID)
  local major, minor, patch = (info and info.CFBundleShortVersionString or ""):match("^(%d+)%.(%d+)%.(%d+)")
  major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
  return major and (major > 0 or minor > 64 or (minor == 64 and patch >= 25))
end

function M.newWorkspace()
  if not isCmux() or task then return end
  local window = hs.window.focusedWindow()
  if not window then hs.alert.show("cmux: no focused window"); return end
  local screen = window:screen()
  local frame = screen:fullFrame()
  task = commandTask(binary, function(code, stdout, stderr)
    task = nil
    if code ~= 0 then
      local message = stderr ~= "" and stderr or stdout
      hs.printf("cmux-grid failed (%d): %s", code, message)
      hs.alert.show(message, 7)
    end
  end, { "new", "--width", tostring(math.floor(frame.w)),
    "--height", tostring(math.floor(frame.h)), "--screen", screen:name(), "--json" })
  if not task or not task:start() then
    task = nil
    hs.alert.show("Install cmux-grid in ~/.local/bin before opening a grid.", 5)
  end
end

function M.zoom()
  if not isCmux() then return end
  -- Native zoom preserves the split tree and running terminals. Never simulate
  -- it by moving tabs to another workspace or resizing the outer macOS window.
  hs.eventtap.keyStroke({ "cmd", "shift" }, "return", 0, hs.application.frontmostApplication())
end

function M.split(direction)
  if not isCmux() then return end
  if splitTask then table.insert(pendingSplits, direction); return end
  local function fail(message)
    splitTask = nil
    pendingSplits = {}
    hs.printf("cmux split failed: %s", message)
    hs.alert.show("cmux split failed: " .. message, 5)
  end
  local appPath = hs.application.pathForBundleID(bundleID)
  local cmuxCLI = appPath and (appPath .. "/Contents/Resources/bin/cmux")
  if not cmuxCLI or not hs.fs.attributes(cmuxCLI) then
    fail("cmux CLI is missing from the installed app"); return
  end
  -- Resolve the focused UI, never a caller workspace inherited by Hammerspoon.
  splitTask = commandTask(cmuxCLI, function(code, stdout, stderr)
    splitTask = nil
    if code ~= 0 then fail(stderr ~= "" and stderr or stdout); return end
    local state = hs.json.decode(stdout)
    local focused = state and state.focused
    if not focused or not focused.workspace_ref or not focused.surface_ref or not focused.window_ref then
      fail("No focused terminal found"); return
    end
    splitTask = commandTask(cmuxCLI, function(splitCode, output, errors)
      splitTask = nil
      if splitCode ~= 0 then fail(errors ~= "" and errors or output); return end
      if #pendingSplits > 0 then
        if not isCmux() then fail("Queued splits cancelled because cmux lost focus"); return end
        M.split(table.remove(pendingSplits, 1))
      end
    end, { "new-split", direction, "--workspace", focused.workspace_ref,
      "--surface", focused.surface_ref, "--window", focused.window_ref, "--focus", "true" })
    if not splitTask or not splitTask:start() then fail("Could not start split command") end
  end, { "identify", "--no-caller" })
  if not splitTask or not splitTask:start() then fail("Could not inspect focused pane") end
end

function M.start()
  M.stop()
  gridKey = hs.hotkey.new({ "cmd" }, 45, M.newWorkspace) -- physical N
  zoomKey = hs.hotkey.new({ "ctrl", "alt", "shift" }, 36, M.zoom)
  -- Physical WASD stays stable on Czech and English keyboard layouts.
  for key, direction in pairs({ [13] = "up", [0] = "left", [1] = "down", [2] = "right" }) do
    table.insert(splitKeys, hs.hotkey.new({ "alt", "shift" }, key, function() M.split(direction) end))
  end
  local function update()
    -- Leave Cmd+N native while an older cmux is installed. A later app activation
    -- rechecks the bundle so upgrading requires no Hammerspoon config edit.
    if isCmux() and hs.fs.attributes(binary) and supportsGrid() then gridKey:enable(); zoomKey:enable()
    else gridKey:disable(); zoomKey:disable() end
    for _, key in ipairs(splitKeys) do
      if isCmux() then key:enable() else key:disable() end
    end
  end
  watcher = hs.application.watcher.new(update)
  watcher:start()
  update()
end

function M.stop()
  pendingSplits = {}
  for _, key in ipairs(splitKeys) do key:delete() end
  splitKeys = {}
  if watcher then watcher:stop(); watcher = nil end
  if gridKey then gridKey:delete(); gridKey = nil end
  if zoomKey then zoomKey:delete(); zoomKey = nil end
  -- Do not terminate a grid request mid-creation when Hammerspoon reloads.
end

return M
