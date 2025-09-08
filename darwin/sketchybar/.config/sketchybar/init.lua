-- Add the sketchybar module to the package cpath
package.cpath = package.cpath .. ";/Users/" .. os.getenv("USER") .. "/.local/share/sketchybar_lua/?.so"

-- Require the sketchybar module
sbar = require("sketchybar")

-- Set the bar name, if you are using another bar instance than sketchybar
-- sbar.set_bar_name("bottom_bar")

-- Bundle the entire initial configuration into a single message to sketchybar
sbar.begin_config()
require("bar")
require("default")
require("items")
sbar.end_config()

-- Run the event loop of the sketchybar module (without this there will be no
-- callback functions executed in the lua module)
sbar.event_loop()

local evt = sbar.add("event", "aerospace_workspace_change")           -- create event handle (optional) :contentReference[oaicite:2]{index=2}

-- 3) helper: style used for all “space.$sid” items
local base_style = {
  background = {
    color = 0x44ffffff,
    corner_radius = 5,
    height = 20,
    drawing = "off",  -- off by default, we’ll turn “on” for the focused one
  },
}

-- 4) fetch all Aerospace workspaces and build items
sbar.exec("aerospace list-workspaces --all", function(out)
  -- out is a newline-separated list of workspace ids (strings)
  for sid in string.gmatch(out or "", "[^\n]+") do
    local name = "space." .. sid

    local item = Sbar.add("item", name, {
      position = "left",
      label = { string = sid },
      click_script = "aerospace workspace " .. sid,
    })

    -- apply base style
    item:set(base_style)

    -- subscribe to the aerospace event and toggle highlight
    item:subscribe("aerospace_workspace_change", function(env)
      local focused = env.FOCUSED_WORKSPACE
      item:set({
        background = { drawing = (sid == focused) and "on" or "off" }
      })
    end)
  end
end)

