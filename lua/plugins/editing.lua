-- Editing layer.

return {
  -- Surround: gsa add, gsd delete, gsr replace.
  {
    "nvim-mini/mini.surround",
    keys = {
      { "gsa", desc = "Add surrounding", mode = { "n", "v" } },
      { "gsd", desc = "Delete surrounding" },
      { "gsr", desc = "Replace surrounding" },
      { "gsf", desc = "Find surrounding (right)" },
      { "gsF", desc = "Find surrounding (left)" },
      { "gsh", desc = "Highlight surrounding" },
    },
    opts = {
      mappings = {
        add = "gsa",
        delete = "gsd",
        find = "gsf",
        find_left = "gsF",
        highlight = "gsh",
        replace = "gsr",
        -- Not remapped: these are suffixes appended to the above, not
        -- standalone keys.
        suffix_last = "l",
        suffix_next = "n",
      },
    },
  },

  -- Auto-pairs. No conflict with blink.cmp: blink's default preset accepts
  -- with <C-y>, not <CR>, so the two never fight over the return key.
  {
    "nvim-mini/mini.pairs",
    event = "InsertEnter",
    opts = {},
  },

  -- Richer a/i text objects: function calls, arguments, tags, brackets and
  -- quotes, each with next/last variants. `ci(`, `daf`, `vin"` and so on.
  {
    "nvim-mini/mini.ai",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },

  -- The test framework: runs inside Neovim, needs no luarocks, and is loaded
  -- only by tests/minimal_init.lua.
  {
    "nvim-mini/mini.test",
    lazy = true,
  },

  -- TODO / FIXME / HACK highlighting, and a way to list them.
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    keys = {
      -- Not ]t and [t as upstream suggests: those are 0.12 tag-navigation defaults.
      { "<leader>xt", "<cmd>TodoFzfLua<cr>", desc = "Todo comments" },
      { "<leader>xT", "<cmd>TodoQuickFix<cr>", desc = "Todo comments to quickfix" },
    },
  },
}
