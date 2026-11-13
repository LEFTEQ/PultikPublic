-- Read-only keyboard input-source watcher: tells the owner when the selected
-- input source leaves Czech, and logs what was frontmost so whatever keeps
-- switching it to "U.S."/"ABC" unasked can be named. No TIS* caller turned up
-- on disk (vt-8296), so this watches instead of guessing.
--
-- IT NEVER CHANGES THE INPUT SOURCE: no setLayout, no setMethod, and
-- currentSourceID() is only ever called with no argument (given one, it
-- selects that source). Switching back to Czech stays the owner's keypress.
--
-- Every change is appended to ~/Library/Logs/pultik-keyboard-watch.log; the
-- alert and notification are rate-limited. A Mac with no Czech layout enabled
-- has nothing to watch, so the module stays idle there.

local M = {}

local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/pultik-keyboard-watch.log"
local ALERT_EVERY = 10 -- seconds between alerts; the log still records every change

-- Source IDs as hs.keycodes.currentSourceID() reports them for Czech.
local CZECH = {
  ["com.apple.keylayout.Czech"] = true, -- QWERTZ, the layout this Mac uses
  ["com.apple.keylayout.Czech-QWERTY"] = true,
}

local lastSource, lastAlert, callback = nil, 0, nil

-- Local time with its offset, e.g. 2026-11-06T13:45:02+01:00.
local function timestamp()
  local now = os.time()
  local offset = os.date("%z", now)
  return os.date("%Y-%m-%dT%H:%M:%S", now) .. offset:sub(1, 3) .. ":" .. offset:sub(4)
end

local function enabledSources()
  local ids = {}
  for _, id in ipairs(hs.keycodes.layouts(true)) do ids[#ids + 1] = id end
  for _, id in ipairs(hs.keycodes.methods(true)) do ids[#ids + 1] = id end
  return table.concat(ids, ",")
end

local function czechEnabled()
  for _, id in ipairs(hs.keycodes.layouts(true)) do
    if CZECH[id] then return true end
  end
  return false
end

local function appendLog(line)
  local f, err = io.open(LOG_PATH, "a")
  if not f then
    print("keyboard_watch: cannot open " .. LOG_PATH .. ": " .. tostring(err))
    return
  end
  f:write(line, "\n")
  f:close()
end

local function changed()
  local source = hs.keycodes.currentSourceID()
  -- The notification can fire more than once per switch; only a real change counts.
  if source == lastSource then return end
  local from = lastSource
  lastSource = source

  local name = hs.keycodes.currentMethod() or hs.keycodes.currentLayout() or source
  local front = hs.application.frontmostApplication()
  local app = front and front:name() or "?"
  -- Secure Event Input (password fields, Secure Keyboard Entry) is a known
  -- reason macOS swaps input sources, so it is logged beside the app.
  appendLog(string.format("%s from=%s to=%s name=%q app=%q bundle=%s secure=%s enabled=%s",
    timestamp(), tostring(from), source, name, app, front and front:bundleID() or "?",
    tostring(hs.eventtap.isSecureInputEnabled()), enabledSources()))

  if CZECH[source] then return end
  local now = hs.timer.secondsSinceEpoch()
  if now - lastAlert < ALERT_EVERY then return end
  lastAlert = now
  local detail = string.format("now %s; frontmost %s", name, app)
  hs.alert.show("Keyboard left Czech: " .. detail, 4)
  hs.notify.new({ title = "Keyboard left Czech", informativeText = detail }):send()
end

function M.start()
  M.stop()
  if not czechEnabled() then
    print("keyboard_watch: no Czech layout enabled, idle")
    return
  end
  lastSource = hs.keycodes.currentSourceID()
  appendLog(string.format("%s start source=%s enabled=%s", timestamp(), lastSource, enabledSources()))
  -- Held here as well as by hs.keycodes, so nothing collects it while watching.
  callback = changed
  hs.keycodes.inputSourceChanged(callback)
end

-- `hs -c 'KeyboardWatch.stop()'` silences it until the next reload. Calling
-- inputSourceChanged() bare keeps hs.keycodes' own layout-map refresh.
function M.stop()
  if not callback then return end
  hs.keycodes.inputSourceChanged()
  callback = nil
end

return M
