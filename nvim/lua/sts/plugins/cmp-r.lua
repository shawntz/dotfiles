return {
  -- R language autocompletion
  "R-nvim/cmp-r",
  {
    "hrsh7th/nvim-cmp",
    config = function()
      require("cmp").setup({ sources = {{ name = "cmp_r" }}})
      require("cmp_r").setup({
        filetypes = { "r", "rmd", "quarto" },
        doc_width = 58,
        quarto_intel = "~/Downloads/quarto-1.1.251/share/editor/tools/yaml/yaml-intelligence-resources.json"
      })
    end,
  },
}

