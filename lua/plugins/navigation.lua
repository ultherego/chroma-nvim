-- Navigation layer: pickers, file management, project roots.
--
-- Every plugin here was checked for activity before being written in
-- (contract rule #2). One rejection is recorded below.
--
-- A recurring theme in this file: the local Zellij config captures
-- Ctrl g/q/h/o/b/s/t/p/n and Alt f/h/i/j/k/l/n/o/p in `shared_except "locked"`,
-- so those never reach Neovim. Several plugins here ship defaults that land
-- exactly on those keys, and are remapped rather than left silently dead.

return {
  -- Shared icon provider. Chosen once for the whole config: oil.nvim
  -- recommends mini.icons, and fzf-lua supports it natively, so there is no
  -- reason to also pull in nvim-web-devicons.
  {
    "nvim-mini/mini.icons",
    lazy = true,
    opts = {},
    init = function()
      -- Several plugins (aerial among them) look for nvim-web-devicons by
      -- name rather than asking for icons in the abstract. mini.icons ships
      -- mock_nvim_web_devicons() for exactly this; hooking it into
      -- package.preload means a require of the old name transparently returns
      -- mini.icons, so one provider still serves everything.
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },

  -- fzf-lua: requires fzf > 0.36 (local: 0.74.2) and Neovim >= 0.9.
  {
    "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    dependencies = { "nvim-mini/mini.icons" },
    -- opts must be a function: the action table below requires a fzf-lua
    -- module, which does not exist until the plugin is on the runtimepath.
    -- Evaluating it in a plain table would run at startup and fail.
    opts = function()
      local actions = require("fzf-lua.actions")
      return {
        -- Profile from the README. "fzf-native" uses fzf's own previewer with
        -- bat (present locally) rather than a Lua previewer buffer.
        "fzf-native",
        actions = {
          files = {
            ["enter"] = actions.file_edit_or_qf,
            -- ctrl-v (vsplit) is free in Zellij and keeps its default.
            ["ctrl-v"] = actions.file_vsplit,
            -- Replaces the default ctrl-s, which Zellij takes for scroll mode.
            -- ctrl-t (new tab) is dropped: Zellij owns tabs in this workflow.
            ["ctrl-x"] = actions.file_split,
            -- Replaces alt-h / alt-i / alt-f, all of which Zellij binds to
            -- pane and tab movement. These punctuation keys are free in both.
            ["alt-."] = actions.toggle_hidden,
            ["alt-,"] = actions.toggle_ignore,
            ["alt-/"] = actions.toggle_follow,
            -- This table replaces the upstream defaults outright rather than
            -- merging with them, so the quickfix and location-list actions
            -- have to be restated or they are lost. Both keys are free in
            -- Zellij and keep their upstream bindings.
            ["alt-q"] = actions.file_sel_to_qf,
            ["alt-Q"] = actions.file_sel_to_ll,
          },
        },
      }
    end,
    keys = {
      { "<leader>ff", "<cmd>FzfLua files<cr>", desc = "Files" },
      { "<leader>fg", "<cmd>FzfLua live_grep<cr>", desc = "Grep" },
      { "<leader>fw", "<cmd>FzfLua grep_cword<cr>", desc = "Word under cursor" },
      { "<leader>fb", "<cmd>FzfLua buffers<cr>", desc = "Buffers" },
      { "<leader>fo", "<cmd>FzfLua oldfiles<cr>", desc = "Recent files" },
      { "<leader>fh", "<cmd>FzfLua helptags<cr>", desc = "Help tags" },
      { "<leader>fk", "<cmd>FzfLua keymaps<cr>", desc = "Keymaps" },
      { "<leader>fd", "<cmd>FzfLua diagnostics_document<cr>", desc = "Diagnostics" },
      { "<leader>fr", "<cmd>FzfLua resume<cr>", desc = "Resume last picker" },
    },
  },

  -- oil.nvim: edit a directory as if it were a buffer. Requires Neovim 0.10+.
  -- Upstream states lazy loading is not recommended, hence lazy = false.
  {
    "stevearc/oil.nvim",
    lazy = false,
    dependencies = { "nvim-mini/mini.icons" },
    opts = {
      -- oil takes over directory buffers (`nvim .`, `:e src/`). netrw is
      -- disabled below, so nothing competes for them.
      default_file_explorer = true,
      view_options = {
        show_hidden = true,
      },
      keymaps = {
        -- Four oil defaults land on keys Zellij eats: <C-s>, <C-h>, <C-t>
        -- and <C-p>. Replacements use keys free in both, and the dead
        -- originals are switched off rather than left as decoration.
        ["<C-s>"] = false,
        ["<C-h>"] = false,
        ["<C-t>"] = false,
        ["<C-p>"] = false,
        ["<C-v>"] = { "actions.select", opts = { vertical = true } },
        ["<C-x>"] = { "actions.select", opts = { horizontal = true } },
        -- Preview moves to a g-prefixed key, matching oil's own idiom
        -- (g?, gs, gx, g., g\).
        ["gp"] = "actions.preview",
      },
    },
    keys = {
      -- oil's own convention: open the parent directory of the current file.
      { "-", "<cmd>Oil<cr>", desc = "Open parent directory (oil)" },
      { "<leader>fe", "<cmd>Oil<cr>", desc = "File explorer (oil)" },
    },
  },

  -- yazi.nvim: the full-screen file manager from the contract's workflow.
  -- Local yazi is 26.5.6. open_for_directories stays false (its default) so
  -- oil keeps directory buffers and yazi is only ever opened deliberately.
  {
    "mikavilpas/yazi.nvim",
    version = "*",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      open_for_directories = false,
      keymaps = {
        show_help = "<f1>",
      },
    },
    init = function()
      -- Recommended by yazi.nvim, and consistent with oil owning directory
      -- buffers: netrw is not wanted in either case.
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1
    end,
    keys = {
      { "<leader>fy", "<cmd>Yazi<cr>", mode = { "n", "v" }, desc = "Yazi at current file" },
      { "<leader>fY", "<cmd>Yazi cwd<cr>", desc = "Yazi at working directory" },
      { "<leader>ft", "<cmd>Yazi toggle<cr>", desc = "Resume last yazi session" },
    },
  },

  -- project.nvim — the DrKJeff16 fork, not ahmedkhalf/project.nvim.
  --
  -- The original has had no commit since August 2024, carries 96 open issues
  -- and calls deprecated APIs; upstream itself points at this fork. Requires
  -- Neovim >= 0.11 (local: 0.12.4) and fd (present). Licence differs from
  -- upstream: GPL-2.0 rather than Apache-2.0.
  {
    "DrKJeff16/project.nvim",
    event = "VeryLazy",
    dependencies = { "ibhagwan/fzf-lua" },
    opts = {
      fzf_lua = {
        enabled = true,
        sort = "newest",
        show = "paths",
      },
    },
    keys = {
      { "<leader>pp", "<cmd>Project fzf-lua<cr>", desc = "Projects" },
    },
  },
}
