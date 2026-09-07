#!/usr/bin/env bash
# Drive a running DEBUG Pultík panel without touching the mouse, keyboard or
# focus. Talks to Sources/Support/PanelDriver.swift over a distributed
# notification; the Release app has no listener.
#
#   tools/panel-drive.sh open                      # summon (⌥Space path)
#   tools/panel-drive.sh close
#   tools/panel-drive.sh query '<text>'            # set the palette text
#   tools/panel-drive.sh paste                     # query = clipboard contents
#   tools/panel-drive.sh key enter [cmd,opt,shift] # enter|tab|up|down|left|right|esc
#   tools/panel-drive.sh capture /tmp/panel.png    # the panel window as PNG
#   tools/panel-drive.sh state [/tmp/state.json]   # palette state as JSON (prints it)
#   tools/panel-drive.sh metrics [/tmp/mem.json]   # footprint + summon time, also hidden
#
# Launch the app first, e.g.
#   PULTIK_KEEP_PANEL_OPEN=1 /tmp/pultik-dd/Build/Products/Debug/Pultik.app/Contents/MacOS/Pultik &
set -euo pipefail

cmd="${1:-}"; shift || true
case "$cmd" in
  open|close) ;;
  query) PD_TEXT="${1-}" ;;
  paste) cmd=query; PD_TEXT="$(pbpaste)" ;;
  key) PD_KEY="${1:?key name}"; PD_MODS="${2-}" ;;
  capture) PD_PATH="${1:?png path}" ;;
  state) PD_PATH="${1:-/tmp/pultik-panel-state.json}" ;;
  metrics) PD_PATH="${1:-/tmp/pultik-panel-metrics.json}" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac

post() {
  PD_CMD="$cmd" PD_TEXT="${PD_TEXT-}" PD_KEY="${PD_KEY-}" PD_MODS="${PD_MODS-}" PD_PATH="${PD_PATH-}" \
  osascript -l JavaScript -e '
    ObjC.import("Foundation");
    const env = $.NSProcessInfo.processInfo.environment;
    const get = k => ObjC.unwrap(env.objectForKey(k)) || "";
    const info = { cmd: get("PD_CMD") };
    for (const k of ["text", "key", "mods", "path"]) { const v = get("PD_" + k.toUpperCase()); if (v) info[k] = v; }
    $.NSDistributedNotificationCenter.defaultCenter
      .postNotificationNameObjectUserInfoDeliverImmediately("dev.example.pultik.debug", $(), $(info), true);
  '
}

case "$cmd" in
  capture|state|metrics)
    rm -f "$PD_PATH"
    post
    for _ in $(seq 1 40); do [ -s "$PD_PATH" ] && break; sleep 0.1; done
    [ -s "$PD_PATH" ] || { echo "panel-drive: no response at $PD_PATH (is a Debug Pultík running with the panel open?)" >&2; exit 1; }
    if [ "$cmd" = state ] || [ "$cmd" = metrics ]; then cat "$PD_PATH"; fi
    ;;
  *)
    post
    sleep 0.35   # let the view settle before the next command
    ;;
esac
