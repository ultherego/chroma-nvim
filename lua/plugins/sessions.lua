-- Sessions.
--
-- The contract reserved a Sessions group but named no plugin, so the choice
-- came from a survey. snacks has no session module, so there was nothing to
-- deduplicate against.
--
--   persisted.nvim     543★, pushed 2026-04, 0 open issues, MIT   <- chosen
--   auto-session      1855★, pushed 2026-06, 28 open issues, MIT
--   persistence.nvim  1004★, pushed 2025-10, 9 open issues, Apache-2.0
--
-- auto-session is the most active but carries the largest surface; persistence
-- is the smallest but has had no push in nine months. persisted sits between
-- them with no open issues, and the snacks dashboard already knows how to
-- surface its sessions.
--
-- Why a session manager belongs in a DevOps config at all: project.nvim finds
-- the root and changes directory, but coming back to an infrastructure
-- repository means coming back to the seven files you had open across it. That
-- is what this restores.

return {
  {
    "olimorris/persisted.nvim",
    event = "BufReadPre",
    -- Also on the command. With only the event, `:Persisted load` typed from
    -- the dashboard — before any file has been read — fails with E492,
    -- which is exactly when restoring a session is most useful.
    cmd = "Persisted",
    opts = {
      autostart = true,
      -- A session per branch. Infrastructure repositories tend to have a
      -- long-lived branch per environment, and the files that matter on
      -- `prod` are rarely the files that matter on a feature branch.
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
