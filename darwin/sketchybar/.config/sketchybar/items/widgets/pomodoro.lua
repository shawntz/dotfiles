local colors = require("colors")
local settings = require("settings")

-- Add events for pomodoro timer
sbar.add("event", "pomodoro_tick")
sbar.add("event", "pomodoro_start_25")
sbar.add("event", "pomodoro_start_15") 
sbar.add("event", "pomodoro_start_5")
sbar.add("event", "pomodoro_start_1")
sbar.add("event", "pomodoro_start_10")
sbar.add("event", "pomodoro_stop")

local pomodoro = sbar.add("item", "widgets.pomodoro", {
  position = "right",
  icon = {
    string = "🍅",
    padding_left = 8,
    padding_right = 8,
    color = colors.red,
  },
  label = {
    drawing = false,  -- Hide the label by default
    padding_right = 6,  -- Reduced padding to match smaller icon spacing
  },
  script = "~/.config/sketchybar/plugins/pomodoro.sh",
  popup = { 
    background = { 
      border_width = 2, 
      border_color = colors.black,
      color = colors.bg1,
    }
  }
})

-- Create popup menu items
local pomodoro_25 = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "🍅",
    color = colors.red,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "25 minutes",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off --trigger pomodoro_start_25; ~/.config/sketchybar/plugins/pomodoro_ticker.sh &",
})

local pomodoro_15 = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "⏱️",
    color = colors.orange,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "15 minutes",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off --trigger pomodoro_start_15; ~/.config/sketchybar/plugins/pomodoro_ticker.sh &",
})

local pomodoro_5 = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "⚡",
    color = colors.yellow,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "5 minutes",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off --trigger pomodoro_start_5; ~/.config/sketchybar/plugins/pomodoro_ticker.sh &",
})

local pomodoro_1 = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "🧪",
    color = colors.blue,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "1 minute (test)",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off --trigger pomodoro_start_1; ~/.config/sketchybar/plugins/pomodoro_ticker.sh &",
})

local pomodoro_10 = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "⚡",
    color = colors.green,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "10 seconds (demo)",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off; ~/.config/sketchybar/plugins/pomodoro.sh pomodoro_start_10; ~/.config/sketchybar/plugins/pomodoro_ticker.sh &",
})

local pomodoro_stop = sbar.add("item", {
  position = "popup." .. pomodoro.name,
  icon = {
    string = "⏹️",
    color = colors.grey,
    padding_left = 12,
    padding_right = 8,
  },
  label = {
    string = "Stop Timer",
    color = colors.white,
    padding_right = 12,
  },
  background = {
    color = colors.bg2,
    height = 30,
  },
  click_script = "sketchybar --set widgets.pomodoro popup.drawing=off --trigger pomodoro_stop",
})

-- Subscribe to timer events and update the label
pomodoro:subscribe({"pomodoro_tick", "pomodoro_start_25", "pomodoro_start_15", "pomodoro_start_5", "pomodoro_start_1", "pomodoro_start_10", "pomodoro_stop"}, function(env)
  pomodoro:set({
    script = "~/.config/sketchybar/plugins/pomodoro.sh",
    update_freq = 0
  })
end)

-- Click to toggle popup
pomodoro:subscribe("mouse.clicked", function(env)
  pomodoro:set({ popup = { drawing = "toggle" } })
end)

-- Keep popup open - only close when clicking outside or on a menu item

-- Hover effects for popup items
pomodoro_25:subscribe("mouse.entered", function(env)
  pomodoro_25:set({ background = { color = colors.with_alpha(colors.red, 0.2) } })
end)
pomodoro_25:subscribe("mouse.exited", function(env)
  pomodoro_25:set({ background = { color = colors.bg2 } })
end)

pomodoro_15:subscribe("mouse.entered", function(env)
  pomodoro_15:set({ background = { color = colors.with_alpha(colors.orange, 0.2) } })
end)
pomodoro_15:subscribe("mouse.exited", function(env)
  pomodoro_15:set({ background = { color = colors.bg2 } })
end)

pomodoro_5:subscribe("mouse.entered", function(env)
  pomodoro_5:set({ background = { color = colors.with_alpha(colors.yellow, 0.2) } })
end)
pomodoro_5:subscribe("mouse.exited", function(env)
  pomodoro_5:set({ background = { color = colors.bg2 } })
end)

pomodoro_1:subscribe("mouse.entered", function(env)
  pomodoro_1:set({ background = { color = colors.with_alpha(colors.blue, 0.2) } })
end)
pomodoro_1:subscribe("mouse.exited", function(env)
  pomodoro_1:set({ background = { color = colors.bg2 } })
end)

pomodoro_10:subscribe("mouse.entered", function(env)
  pomodoro_10:set({ background = { color = colors.with_alpha(colors.green, 0.2) } })
end)
pomodoro_10:subscribe("mouse.exited", function(env)
  pomodoro_10:set({ background = { color = colors.bg2 } })
end)

pomodoro_stop:subscribe("mouse.entered", function(env)
  pomodoro_stop:set({ background = { color = colors.with_alpha(colors.grey, 0.2) } })
end)
pomodoro_stop:subscribe("mouse.exited", function(env)
  pomodoro_stop:set({ background = { color = colors.bg2 } })
end)

-- Background bracket around the pomodoro item
sbar.add("bracket", "widgets.pomodoro.bracket", { pomodoro.name }, {
  background = { color = colors.bg1 }
})

-- Padding
sbar.add("item", "widgets.pomodoro.padding", {
  position = "right",
  width = settings.group_paddings
})
