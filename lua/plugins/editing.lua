-- Editing layer.
--
-- The contract does not name plugins for this layer, so the list comes from
-- asking what Neovim 0.12 still lacks. It lacks less than it used to:
-- commenting (gc/gcc), diagnostic and buffer motions, and treesitter
-- incremental selection are all built in now, so no plugin here duplicates
-- them.
--
-- What remains genuinely missing is surrounding pairs, auto-pairing, richer
-- text objects, and finding the TODOs somebody left in a manifest.
--
-- The mini.nvim modules are used standalone rather than as the mini.nvim
-- bundle, matching how mini.icons is already installed in the navigation
-- layer.

return {
  -- Surround: gsa add, gsd delete, gsr replace.
  --
  -- The upstream default prefix is `s`, which shadows Neovim's built-in `s`
  -- (substitute character) in both normal and visual mode. That is a real
  -- loss for a config whose contract forbids accidental keymaps, so the
  -- prefix is moved to `gs`. Vim's `gs` means "sleep for N seconds" and is
  -- not worth protecting.
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
  --
  -- No treesitter-based specs are added. mini.ai can generate them through
  -- MiniAi.gen_spec.treesitter(), but that needs textobject queries this
  -- config does not install, and inventing the specs would be guesswork.
  {
    "nvim-mini/mini.ai",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },

  -- TODO / FIXME / HACK highlighting, and a way to find them all. More useful
  -- than it sounds in infrastructure repositories, where "TODO: remove before
  -- prod" has a habit of surviving to prod.
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
    keys = {
      -- Upstream suggests ]t and [t for jumping between todos. Those are
      -- Neovim 0.12 defaults for tag navigation (see :help default-mappings),
      -- so they are left alone and the picker carries this instead.
      { "<leader>xt", "<cmd>TodoFzfLua<cr>", desc = "Todo comments" },
      { "<leader>xT", "<cmd>TodoQuickFix<cr>", desc = "Todo comments to quickfix" },
    },
  },
}
