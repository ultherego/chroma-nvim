-- Editing layer.

return {
  -- On `gs` rather than the default `s`, which shadows a built-in.
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
        -- Suffixes appended to the above, not standalone keys.
        suffix_last = "l",
        suffix_next = "n",
      },
    },
  },

  -- No conflict with blink.cmp: its default preset accepts with <C-y>, not
  -- <CR>, so the two never fight over the return key.
  {
    "nvim-mini/mini.pairs",
    event = "InsertEnter",
    opts = {},
  },

  -- Richer a/i text objects: `ci(`, `daf`, `vin"` and so on.
  {
    "nvim-mini/mini.ai",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },

  -- The test framework, loaded only by tests/minimal_init.lua.
  {
    "nvim-mini/mini.test",
    lazy = true,
  },

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
