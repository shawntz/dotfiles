return {
  {
    "nvim-lualine/lualine.nvim",
    opts = {
      options = {
        theme = "auto",
        component_separators = "",
        section_separators = "",
        globalstatus = true,

        -- THIS is critical for transparency
        disabled_filetypes = {},
      },
      sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = {
          {
            "filename",
            color = { bg = "NONE" },
          },
        },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = {
          {
            "filename",
            color = { bg = "NONE" },
          },
        },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
    },
  },
}
