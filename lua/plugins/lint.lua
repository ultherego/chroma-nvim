-- Lint layer.
--
-- nvim-lint fills the gaps that language servers leave. Its canonical home is
-- Codeberg (codeberg.org/mfussenegger/nvim-lint); the GitHub repository used
-- here is the author's own mirror and tracks it.
--
-- WHAT IS NOT HERE, AND WHY:
--
-- tflint is absent on purpose. It ships an LSP mode and nvim-lspconfig exposes
-- a config for it, so it is enabled as a language server in plugins/lsp.lua
-- and attaches to Terraform buffers by itself. Registering it here as well
-- would report every finding twice.

return {
  {
    "mfussenegger/nvim-lint",
    event = { "BufReadPost", "BufNewFile", "BufWritePost" },
    config = function()
      local lint = require("lint")

      lint.linters_by_ft = {
        yaml = { "yamllint" },
        dockerfile = { "hadolint" },

        -- Ansible playbooks are detected as `yaml.ansible` by nvim-ansible in
        -- the DevOps layer. ansible-lint is slow enough that it is treated as
        -- a write-time linter below rather than running on every InsertLeave.
        --
        -- The linter is `ansible_lint` with an underscore; the Mason package
        -- it runs is `ansible-lint` with a hyphen.
        ["yaml.ansible"] = { "ansible_lint" },
      }

      -- Linters that are cheap enough to run while typing. Everything else
      -- runs on write and on demand only. Spawning ansible-lint on every
      -- InsertLeave is a noticeable drag on a large role.
      local fast = { yamllint = true, hadolint = true }

      -- Single source of truth. The manual keymap and the autocmd both call
      -- this, so "lint now" can never mean something different from "lint on
      -- save" — which it did when the actionlint rule lived only in the
      -- autocmd.
      local function linters_for(buf, only_fast)
        local names = {}

        for _, name in ipairs(lint.linters_by_ft[vim.bo[buf].filetype] or {}) do
          if not only_fast or fast[name] then
            table.insert(names, name)
          end
        end

        -- GitHub Actions workflows keep the plain `yaml` filetype rather than
        -- getting one of their own. A dedicated filetype would take them out
        -- of yamlls's filetype list and cost the schema validation that makes
        -- editing them worthwhile, so actionlint is selected by path instead.
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
