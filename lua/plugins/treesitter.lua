-- Treesitter layer.

local parsers = require("config.parsers")

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    -- Upstream is explicit: this plugin does not support lazy-loading.
    lazy = false,
    build = ":TSUpdate",
    config = function()
      -- Only what is missing: install() on the full list checks every parser on
      -- every start.
      local installed = {}
      for _, name in ipairs(require("nvim-treesitter.config").get_installed("parsers")) do
        installed[name] = true
      end

      local missing = vim.tbl_filter(function(name)
        return not installed[name]
      end, parsers)

      local installing = nil
      if #missing > 0 then
        installing = require("nvim-treesitter").install(missing)
      end

      local group = vim.api.nvim_create_augroup("devops_treesitter", { clear = true })

      -- 'foldmethod' and 'foldexpr' are window options, not buffer options.
      local function set_folding(buf)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          -- [win][0] is `:setlocal` for this window-buffer pair.
          vim.wo[win][0].foldmethod = "expr"
          vim.wo[win][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
        end
      end

      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(ev)
          if vim.b[ev.buf].devops_treesitter then
            set_folding(ev.buf)
          end
        end,
      })

      --- Starts treesitter for one buffer, if there is a parser for it by now.
      --- Idempotent: the flag is what stops the retry below repeating the work.
      ---@param buf integer
      local function enable(buf)
        if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].devops_treesitter then
          return
        end

        -- Fails for any filetype without an installed parser, which is
        -- expected and not an error worth reporting.
        if not pcall(vim.treesitter.start, buf) then
          return
        end

        vim.b[buf].devops_treesitter = true
        set_folding(buf)

        -- Treesitter indentation is deliberately NOT enabled.
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(ev)
          enable(ev.buf)
        end,
      })

      -- install() is asynchronous. On a first start the parsers land some time
      -- after this, and a file opened in between has already had its FileType —
      -- with nothing installed to start, and nothing to try again later. It stayed
      -- unhighlighted and unfoldable until the buffer was reopened.
      --
      -- Guarded because `await` belongs to nvim-treesitter's own task type rather
      -- than to a documented interface: if it changes shape, this goes back to
      -- doing nothing, which is what it did before.
      if installing then
        pcall(function()
          installing:await(vim.schedule_wrap(function()
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_loaded(buf) then
                enable(buf)
              end
            end
          end))
        end)
      end
    end,
  },
}
