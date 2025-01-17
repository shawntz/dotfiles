import fs from "fs";
import { KarabinerRules } from "./types";
import { createHyperSubLayers, app, open, hyperYabai } from "./utils";

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
    // change window focus
    h: hyperYabai("-m window --focus west"),
    j: hyperYabai("-m window --focus south"),
    k: hyperYabai("-m window --focus north"),
    l: hyperYabai("-m window --focus east"),

    r: hyperYabai("-m space --rotate 270"),
    y: hyperYabai("-m space --space --mirror y-axis"),
    x: hyperYabai("-m space --space --mirror x-axis"),
    t: hyperYabai("-m window --toggle float --grid 4:4:1:1:2:2"),
    m: hyperYabai("-m window --toggle zoom-fullscreen"),
    b: hyperYabai("-m window space --balance"),

    f: {
      h: hyperYabai("-m space --focus 1"),
      j: hyperYabai("-m space --focus 2"),
      k: hyperYabai("-m space --focus 3"),
      l: hyperYabai("-m space --focus 4"),
      semicolon: hyperYabai("-m space --focus 5"),
      quote: hyperYabai("-m space --focus 6"),
      n: hyperYabai("-m window --swap west"),
      m: hyperYabai("-m window --swap south"),
      comma: hyperYabai("-m window --swap north"),
      period: hyperYabai("-m window --swap east"),
    },

    g: {
      h: hyperYabai("-m window --space 1; /run/current-system/sw/bin/yabai -m space --focus 1;"),
      j: hyperYabai("-m window --space 1; /run/current-system/sw/bin/yabai -m space --focus 2;"),
      k: hyperYabai("-m window --space 2; /run/current-system/sw/bin/yabai -m space --focus 3;"),
      l: hyperYabai("-m window --space 3; /run/current-system/sw/bin/yabai -m space --focus 4;"),
      semicolon: hyperYabai("-m window --space 4; /run/current-system/sw/bin/yabai -m space --focus 5;"),
      quote: hyperYabai("-m window --space 5; /run/current-system/sw/bin/yabai -m space --focus 6;"),
      comma: hyperYabai("-p window --space prev"),
      period: hyperYabai("-m window --space next"),
    },

    // most frequent apps don't require "o" sublayer
    // o = "o"pen x app
    o: {
      f: app("Firefox", 1),
      g: app("Ghostty", 2),
      r: app("RStudio", 3),
      h: app("HEY", 4),
      p: app("Beeper", 5),
      c: app("Basecamp 3", 6),
      k: app("Google Calendar", 6),
    },

    // s = control the "s"ystem
    s: {
      u: { to: [{ key_code: "volume_increment" }] },
      j: { to: [{ key_code: "volume_decrement" }] },
      i: { to: [{ key_code: "display_brightness_increment" }] },
      k: { to: [{ key_code: "display_brightness_decrement" }] },
      p: { to: [{ key_code: "play_or_pause" }] },
      semicolon: { to: [{ key_code: "fastforward" }] },
      quote: { to: [{ key_code: "rewind" }] },
      l: { to: [{ key_code: "q", modifiers: ["right_control", "right_command"] }] },
      // "D"o not disturb toggle
      d: open(`raycast://extensions/yakitrak/do-not-disturb/toggle?launchType=background`),
    },

    // utils
    d: {
      // vim key bindings
      h: { to: [{ key_code: "left_arrow" }] },
      j: { to: [{ key_code: "down_arrow" }] },
      k: { to: [{ key_code: "up_arrow" }] },
      l: { to: [{ key_code: "right_arrow" }] },

      // Magicmove via homerow.app
      m: { to: [{ key_code: "f", modifiers: ["left_option"] }] },

      // Scroll mode via homerow.app
      semicolon: { to: [{ key_code: "j", modifiers: ["left_option"] }] },
      u: { to: [{ key_code: "page_down" }] },
      i: { to: [{ key_code: "page_up" }] },
    },

    // c = Ray"c"ast
    c: {
      p: open("raycast://extensions/thomas/color-picker/pick-color"),
      e: open("raycast://extensions/raycast/emoji-symbols/search-emoji-symbols"),
      h: open("raycast://extensions/raycast/clipboard-history/clipboard-history"),
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
          virtual_hid_keyboard: { "keyboard_type_v2": "ansi" },
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
