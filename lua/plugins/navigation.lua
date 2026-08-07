-- Navigation layer: pickers, file management, project roots.

return {
  -- The one icon provider for the whole config: oil recommends it and fzf-lua
  -- supports it natively.
  {
    "nvim-mini/mini.icons",
    lazy = true,
    opts = {},
    init = function()
      -- Plugins that require nvim-web-devicons by name get mini.icons instead.
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },

  -- fzf-lua: requires fzf > 0.36 and Neovim >= 0.9.
  {
    "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    dependencies = { "nvim-mini/mini.icons" },
    -- opts must be a function: the action table below requires a fzf-lua
    -- module, which does not exist until the plugin is on the runtimepath.
    opts = function()
      local actions = require("fzf-lua.actions")
      return {
        -- Uses fzf's own previewer through bat, which is therefore a requirement.
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
            -- Replaces the upstream defaults outright, so they are repeated here.
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
        -- Four oil defaults land on keys Zellij eats, so they are moved and the
        -- originals disabled rather than left dead.
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
