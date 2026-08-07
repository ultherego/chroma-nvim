-- Sessions.

return {
  {
    "olimorris/persisted.nvim",
    event = "BufReadPre",
    -- Also on the command: from the dashboard the event has not fired yet, and
    -- `:Persisted load` would fail with E492.
    cmd = "Persisted",
    opts = {
      autostart = true,
      -- A session per branch: infrastructure repositories tend to keep one branch
      -- per environment.
      use_git_branch = true,
      follow_cwd = true,
      should_save = function()
        -- The dashboard is not worth restoring, and saving it means opening
        -- Neovim into a stale start screen instead of the work.
        return vim.bo.filetype ~= "snacks_dashboard"
      end,
    },
    keys = {
      { "<leader>ss", "<cmd>Persisted select<cr>", desc = "Select session" },
      { "<leader>sl", "<cmd>Persisted load<cr>", desc = "Load session for this directory" },
      { "<leader>sL", "<cmd>Persisted load_last<cr>", desc = "Load last session" },
      { "<leader>sw", "<cmd>Persisted save<cr>", desc = "Save session now" },
      { "<leader>st", "<cmd>Persisted toggle<cr>", desc = "Toggle session recording" },
      { "<leader>sd", "<cmd>Persisted delete_current<cr>", desc = "Delete this session" },
    },
  },
}
