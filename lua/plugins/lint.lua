-- Lint layer.

return {
  {
    "mfussenegger/nvim-lint",
    event = { "BufReadPost", "BufNewFile", "BufWritePost" },
    config = function()
      local lint = require("lint")

      lint.linters_by_ft = {
        yaml = { "yamllint" },
        dockerfile = { "hadolint" },

        -- nvim-ansible detects playbooks as `yaml.ansible`; ansible-lint is slow,
        -- so it is not one of the fast linters below.
        ["yaml.ansible"] = { "ansible_lint" },
      }

      -- Cheap enough to run while typing; everything else waits for a write.
      local fast = { yamllint = true, hadolint = true }

      -- Both the keymap and the autocmd call this, so "lint now" and "lint on
      -- save" cannot drift apart.
      local function linters_for(buf, only_fast)
        local names = {}

        for _, name in ipairs(lint.linters_by_ft[vim.bo[buf].filetype] or {}) do
          if not only_fast or fast[name] then
            table.insert(names, name)
          end
        end

        -- Workflows keep the plain `yaml` filetype, so actionlint is chosen by path.
        if not only_fast then
          local path = vim.api.nvim_buf_get_name(buf)
          if path:match("/%.github/workflows/[^/]+%.ya?ml$") then
            table.insert(names, "actionlint")
          end
        end

        -- A linter whose binary is missing produces an opaque error from deep
        -- inside nvim-lint, so absent tools are skipped quietly instead.
        return vim.tbl_filter(function(name)
          local linter = lint.linters[name]
          local cmd = type(linter) == "table" and linter.cmd or nil
          return cmd == nil or vim.fn.executable(cmd) == 1
        end, names)
      end

      local function try_lint(buf, only_fast)
        local names = linters_for(buf, only_fast)
        if #names > 0 then
          lint.try_lint(names)
        end
      end

      local group = vim.api.nvim_create_augroup("devops_lint", { clear = true })

      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
        group = group,
        callback = function(ev)
          try_lint(ev.buf, false)
        end,
      })

      vim.api.nvim_create_autocmd("InsertLeave", {
        group = group,
        callback = function(ev)
          try_lint(ev.buf, true)
        end,
      })

      vim.api.nvim_create_user_command("Lint", function()
        try_lint(vim.api.nvim_get_current_buf(), false)
      end, { desc = "Run every linter for this buffer" })
    end,
    keys = {
      { "<leader>xl", "<cmd>Lint<cr>", desc = "Lint buffer now" },
    },
  },
}
