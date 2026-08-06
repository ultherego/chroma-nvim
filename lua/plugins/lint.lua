-- Lint layer.
--
-- nvim-lint fills the gaps that language servers leave. Its canonical home is
-- Codeberg (codeberg.org/mfussenegger/nvim-lint); the GitHub repository used
-- here is the author's own mirror and tracks it.
--
-- WHAT IS NOT HERE, AND WHY:
--
-- tflint is absent on purpose. It ships an LSP mode and nvim-lspconfig exposes
-- a config for it, so installing it as a Mason tool already starts it as a
-- language server that attaches to Terraform buffers by itself. Registering it
-- here as well would report every finding twice. See plugins/lsp.lua.

return {
  {
    "mfussenegger/nvim-lint",
    event = { "BufReadPost", "BufNewFile", "BufWritePost" },
    config = function()
      local lint = require("lint")

      lint.linters_by_ft = {
        yaml = { "yamllint" },
        dockerfile = { "hadolint" },

        -- Ansible playbooks are detected as `yaml.ansible`. That filetype is
        -- supplied by nvim-ansible, which arrives with the DevOps layer; until
        -- then this entry simply never matches.
        -- The linter is `ansible_lint` with an underscore; the Mason package
        -- it runs is `ansible-lint` with a hyphen.
        ["yaml.ansible"] = { "ansible_lint" },
      }

      local group = vim.api.nvim_create_augroup("devops_lint", { clear = true })

      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
        group = group,
        callback = function(ev)
          local names = vim.deepcopy(lint.linters_by_ft[vim.bo[ev.buf].filetype] or {})

          -- actionlint understands GitHub Actions workflows, which are plain
          -- `yaml` files. Giving them their own filetype would work, but it
          -- would also take them out of yamlls's filetype list and cost the
          -- schema validation that makes editing them worthwhile. Matching on
          -- the path keeps both.
          local path = vim.api.nvim_buf_get_name(ev.buf)
          if path:match("%.github/workflows/[^/]+%.ya?ml$") then
            table.insert(names, "actionlint")
          end

          if #names > 0 then
            lint.try_lint(names)
          end
        end,
      })
    end,
    keys = {
      {
        "<leader>xl",
        function()
          require("lint").try_lint()
        end,
        desc = "Lint buffer now",
      },
    },
  },
}
