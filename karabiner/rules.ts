import fs from "fs";
import { KarabinerRules } from "./types";
import { createHyperSubLayers, app, webapp, open, hyperYabai, rectangle, shell } from "./utils";

const rules: KarabinerRules[] = [
  // Define the new command key
  {
    description: "New Command Key",
    manipulators: [
      {
        description: "Tab -> Command Key",
        from: {
          key_code: "tab",
          modifiers: {
            optional: ["any"],
          },
        },
        to: [
          {
            key_code: "left_command",
            hold_down_milliseconds: 500,
          },
        ],
        to_if_alone: [
          {
            key_code: "tab",
          },
        ],
        type: "basic",
      },
    ],
  },
  // Define the Hyper key itself
  {
    description: "Hyper Key (⌃⌥⇧⌘)",
    manipulators: [
      {
        description: "Caps Lock -> Hyper Key",
        from: {
          key_code: "caps_lock",
          modifiers: {
            optional: ["any"],
          },
        },
        to: [
          {
            set_variable: {
              name: "hyper",
              value: 1,
            },
          },
        ],
        to_after_key_up: [
          {
            set_variable: {
              name: "hyper",
              value: 0,
            },
          },
        ],
        to_if_alone: [
          {
            key_code: "escape",
          },
        ],
        type: "basic",
      },
    ],
  },
  ...createHyperSubLayers({
    // yabai triggers (replacement for skhd)
    j: hyperYabai("-m window --focus south"),
    k: hyperYabai("-m window --focus north"),
    h: hyperYabai("-m window --focus west"),
    l: hyperYabai("-m window --focus east"),
    u: hyperYabai("-m display --focus west"),
    i: hyperYabai("-m display --focus east"),
    o: hyperYabai("-m space --rotate 270"),
    y: hyperYabai("-m space --space --mirror y-axis"),
    x: hyperYabai("-m space --space --mirror x-axis"),
    t: hyperYabai("-m window --toggle float --grid 4:4:1:1:2:2"),
    f: hyperYabai("-m window --toggle zoom-fullscreen"),
    b: hyperYabai("-m window space --balance"),
    v: {
      j: hyperYabai("-m window --swap south"),
      k: hyperYabai("-m window --swap north"),
      h: hyperYabai("-m window --swap west"),
      l: hyperYabai("-m window --swap east"),
      u: hyperYabai("-m window --display west; /run/current-system/sw/bin/yabai -m display --focus west;"),
      i: hyperYabai("-m window --display east; /run/current-system/sw/bin/yabai -m display --focus east;"),
    },
    c: {
      j: hyperYabai("-m window --warp south"),
      k: hyperYabai("-m window --warp north"),
      h: hyperYabai("-m window --warp west"),
      l: hyperYabai("-m window --warp east"),
    },
    w: {
      h: hyperYabai("-p window --space prev"),
      n: hyperYabai("-m window --space next"),
      u: hyperYabai("-m space --focus 1"),
      i: hyperYabai("-m space --focus 2"),
      o: hyperYabai("-m space --focus 3"),
      p: hyperYabai("-m space --focus 4"),
      open_bracket: hyperYabai("-m space --focus 5"),
      close_bracket: hyperYabai("-m space --focus 6"),
      backslash: hyperYabai("-m space --focus 7"),
    },
    e: {
      u: hyperYabai("-m window --space 1; /run/current-system/sw/bin/yabai -m space --focus 1;"),
      i: hyperYabai("-m window --space 2; /run/current-system/sw/bin/yabai -m space --focus 2;"),
      o: hyperYabai("-m window --space 3; /run/current-system/sw/bin/yabai -m space --focus 3;"),
      p: hyperYabai("-m window --space 4; /run/current-system/sw/bin/yabai -m space --focus 4;"),
      open_bracket: hyperYabai("-m window --space 5; /run/current-system/sw/bin/yabai -m space --focus 5;"),
      close_bracket: hyperYabai("-m window --space 6; /run/current-system/sw/bin/yabai -m space --focus 6;"),
      backslash: hyperYabai("-m window --space 7; /run/current-system/sw/bin/yabai -m space --focus 7;"),
    },
 
    // most frequent apps don't require "a" sublayer
    return_or_enter: app("kitty", 1),
    g: app("Google Chrome", 2),
    
    // a = Open "a"pplications
    a: {
      h: app("HEY", 3),
      s: app("Slack", 4),
      p: app("1Password"),
      m: app("Music"),
      f: app("Finder", 6),
      i: app("Messages"),
      b: app("Bear", 7),
      d: app("Todoist", 5),
      z: app("zoom.us"),
    },

    // s = "System"
    s: {
      u: {
        to: [
          {
            key_code: "volume_increment",
          },
        ],
      },
      j: {
        to: [
          {
            key_code: "volume_decrement",
          },
        ],
      },
      i: {
        to: [
          {
            key_code: "display_brightness_increment",
          },
        ],
      },
      k: {
        to: [
          {
            key_code: "display_brightness_decrement",
          },
        ],
      },
      l: {
        to: [
          {
            key_code: "q",
            modifiers: ["right_control", "right_command"],
          },
        ],
      },
      p: {
        to: [
          {
            key_code: "play_or_pause",
          },
        ],
      },
      semicolon: {
        to: [
          {
            key_code: "fastforward",
          },
        ],
      },
      // "D"o not disturb toggle
      d: open(
        `raycast://extensions/yakitrak/do-not-disturb/toggle?launchType=background`
      ),
      // "T"heme
      t: open(`raycast://extensions/raycast/system/toggle-system-appearance`),
      c: open("raycast://extensions/raycast/system/open-camera"),
    },

    // utils
    spacebar: {
      // vim key bindings
      h: {
        to: [{ key_code: "left_arrow" }],
      },
      j: {
        to: [{ key_code: "down_arrow" }],
      },
      k: {
        to: [{ key_code: "up_arrow" }],
      },
      l: {
        to: [{ key_code: "right_arrow" }],
      },

      // Magicmove via homerow.app
      m: {
        to: [{ key_code: "f", modifiers: ["left_option"] }],
      },

      // Scroll mode via homerow.app
      s: {
        to: [{ key_code: "j", modifiers: ["left_option"] }],
      },
      u: {
        to: [{ key_code: "page_down" }],
      },
      i: {
        to: [{ key_code: "page_up" }],
      },
    },

    // m = Apple *M*usic which isn't "m" because we want it to be on the left hand
    m: {
      p: {
        to: [{ key_code: "play_or_pause" }],
      },
      n: {
        to: [{ key_code: "fastforward" }],
      },
      b: {
        to: [{ key_code: "rewind" }],
      },
    },

    // r = "Raycast"
    r: {
      p: open("raycast://extensions/thomas/color-picker/pick-color"),
      e: open(
        "raycast://extensions/raycast/emoji-symbols/search-emoji-symbols"
      ),
      c: open("raycast://extensions/raycast/raycast/confetti"),
      h: open(
        "raycast://extensions/raycast/clipboard-history/clipboard-history"
      ),
    },
  }),
];

fs.writeFileSync(
  "karabiner.json",
  JSON.stringify(
    {
      global: {
        show_in_menu_bar: false,
      },
      profiles: [
        {
          name: "Default",
          complex_modifications: {
            rules,
          },
        },
      ],
    },
    null,
    2
  )
);
