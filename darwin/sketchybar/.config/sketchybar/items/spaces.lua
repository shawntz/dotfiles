local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

local spaces = {}


-- Only show workspaces 1-5 
local all_workspaces = {"1", "2", "3", "4", "5"}

for i, workspace in ipairs(all_workspaces) do
  local space = sbar.add("item", "space." .. workspace, {
    icon = {
      font = { family = settings.font.numbers },
      string = workspace,
      padding_left = 15,
      padding_right = 8,
      color = colors.white,
      highlight_color = colors.red,
    },
    label = {
      padding_right = 20,
      color = colors.grey,
      highlight_color = colors.white,
      font = "sketchybar-app-font:Regular:16.0",
      y_offset = -1,
    },
    padding_right = 1,
    padding_left = 1,
    background = {
      color = colors.bg1,
      border_width = 1,
      height = 26,
      border_color = colors.black,
    },
    popup = { background = { border_width = 5, border_color = colors.black } }
  })

  spaces[workspace] = space

  -- Single item bracket for space items to achieve double border on highlight
  local space_bracket = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2
    }
  })

  -- Padding space
  sbar.add("item", "space.padding." .. workspace, {
    script = "",
    width = settings.group_paddings,
  })

  local space_popup = sbar.add("item", {
    position = "popup." .. space.name,
    padding_left= 5,
    padding_right= 0,
    background = {
      drawing = true,
      image = {
        corner_radius = 9,
        scale = 0.2
      }
    }
  })


  space:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "other" then
      space_popup:set({ background = { image = "space." .. workspace } })
      space:set({ popup = { drawing = "toggle" } })
    else
      sbar.exec("aerospace workspace " .. workspace)
    end
  end)

  space:subscribe("mouse.exited", function(_)
    space:set({ popup = { drawing = false } })
  end)
end

local space_window_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

local spaces_indicator = sbar.add("item", {
  padding_left = -3,
  padding_right = 0,
  icon = {
    padding_left = 8,
    padding_right = 9,
    color = colors.grey,
    string = icons.switch.on,
  },
  label = {
    width = 0,
    padding_left = 0,
    padding_right = 8,
    string = "Spaces",
    color = colors.bg1,
  },
  background = {
    color = colors.with_alpha(colors.grey, 0.0),
    border_color = colors.with_alpha(colors.bg1, 0.0),
  }
})

-- Simplified function to update workspace icons (only 1-5)
local function update_workspace_icons()
  for workspace_num = 1, 5 do
    local workspace = tostring(workspace_num)
    if spaces[workspace] then
      sbar.exec("aerospace list-windows --workspace " .. workspace .. " --format '%{app-name}' 2>/dev/null", function(result)
        local icon_line = ""
        local no_app = true
        local apps = {}
        
        if result and result ~= "" then
          for app_name in result:gmatch("[^\r\n]+") do
            if app_name and app_name ~= "" then
              apps[app_name] = true
              no_app = false
            end
          end
          
          for app_name, _ in pairs(apps) do
            local lookup = app_icons[app_name]
            local icon = ((lookup == nil) and app_icons["Default"] or lookup)
            icon_line = icon_line .. icon
          end
        end

        if no_app then
          icon_line = " —"
        end
        
        if spaces[workspace] then
          spaces[workspace]:set({ label = { string = icon_line } })
        end
      end)
    end
  end
end

-- Subscribe to aerospace focus change to update highlighting and icons
space_window_observer:subscribe("aerospace_workspace_change", function(env)
  update_workspace_icons()
  
  -- Update highlighting for workspaces 1-5
  local focused_workspace = env.FOCUSED_WORKSPACE
  if focused_workspace then
    for workspace_num = 1, 5 do
      local workspace = tostring(workspace_num)
      if spaces[workspace] then
        local selected = workspace == focused_workspace
        local space_bracket_name = "space." .. workspace .. ".bracket"
        
        spaces[workspace]:set({
          icon = { 
            color = selected and colors.white or colors.with_alpha(colors.white, 0.3),
          },
          label = { 
            color = selected and colors.white or colors.with_alpha(colors.grey, 0.4),
          },
          background = { 
            border_color = selected and colors.white or colors.bg2,
            color = selected and colors.bg1 or colors.with_alpha(colors.bg1, 0.2),
            border_width = selected and 2 or 1,
          }
        })
        
        -- Update bracket highlighting with much more contrast
        sbar.set(space_bracket_name, {
          background = { 
            border_color = selected and colors.bg1 or colors.with_alpha(colors.bg2, 0.3),
            border_width = selected and 3 or 2,
            color = selected and colors.with_alpha(colors.bg1, 0.2) or colors.transparent,
          }
        })
      end
    end
  end
end)


spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
  local currently_on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({
    icon = currently_on and icons.switch.off or icons.switch.on
  })
end)

spaces_indicator:subscribe("mouse.entered", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 1.0 },
        border_color = { alpha = 1.0 },
      },
      icon = { color = colors.bg1 },
      label = { width = "dynamic" }
    })
  end)
end)

spaces_indicator:subscribe("mouse.exited", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 0.0 },
        border_color = { alpha = 0.0 },
      },
      icon = { color = colors.grey },
      label = { width = 0, }
    })
  end)
end)

spaces_indicator:subscribe("mouse.clicked", function(env)
  sbar.trigger("swap_menus_and_spaces")
end)

-- Initial setup of workspace icons and highlighting
update_workspace_icons()

-- Set initial highlighting for workspace 1
sbar.exec("aerospace list-workspaces --focused", function(result)
  local focused_workspace = result and result:match("(%d+)") or "1"
  
  -- Update highlighting for all workspaces
  for workspace_num = 1, 5 do
    local workspace = tostring(workspace_num)
    if spaces[workspace] then
      local selected = workspace == focused_workspace
      local space_bracket_name = "space." .. workspace .. ".bracket"
      
      spaces[workspace]:set({
        icon = { 
          color = selected and colors.white or colors.with_alpha(colors.white, 0.3),
        },
        label = { 
          color = selected and colors.white or colors.with_alpha(colors.grey, 0.4),
        },
        background = { 
          border_color = selected and colors.white or colors.bg2,
          color = selected and colors.bg1 or colors.with_alpha(colors.bg1, 0.2),
          border_width = selected and 2 or 1,
        }
      })
      
      sbar.set(space_bracket_name, {
        background = { 
          border_color = selected and colors.bg1 or colors.with_alpha(colors.bg2, 0.3),
          border_width = selected and 3 or 2,
          color = selected and colors.with_alpha(colors.bg1, 0.2) or colors.transparent,
        }
      })
    end
  end
end)

