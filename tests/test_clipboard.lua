-- Tests for what reaches the system clipboard.
--
-- The clipboard here is a provider made of two functions, so nothing leaves the
-- test process: Neovim calls `copy` with what it would hand to the system, and
-- that is what the cases read.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local sent = {}
local saved = {}

local T = new_set({
  hooks = {
    pre_case = function()
      sent = {}
      saved.clipboard, saved.option = vim.g.clipboard, vim.o.clipboard

      vim.g.clipboard = {
        name = "chroma-test",
        copy = {
          ["+"] = function(lines)
            table.insert(sent, lines)
          end,
          ["*"] = function(lines)
            table.insert(sent, lines)
          end,
        },
        paste = {
          ["+"] = function()
            return sent[#sent] or {}
          end,
          ["*"] = function()
            return sent[#sent] or {}
          end,
        },
      }
      -- The provider is chosen once per session; this makes it choose again.
      vim.g.loaded_clipboard_provider = nil
      vim.cmd("runtime autoload/provider/clipboard.vim")

      package.loaded["config.options"] = nil
      require("config.options")

      vim.cmd.enew({ bang = true })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first line", "second line", "third line" })
    end,
    post_case = function()
      vim.g.clipboard = saved.clipboard
      vim.o.clipboard = saved.option
      vim.g.loaded_clipboard_provider = nil
      vim.cmd("runtime autoload/provider/clipboard.vim")
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

-- Asserted on the option as well as on what happens, and not for tidiness.
-- Measured: Neovim batches clipboard writes made through 'clipboard' until the
-- running command ends, and a test case is one command — so with
-- `unnamedplus` back in place every case below still passed, the deletes
-- reaching the clipboard only after the assertions had run.
T["'clipboard' itself sends nothing anywhere"] = function()
  eq(vim.o.clipboard, "")
end

T["a yank reaches the system clipboard"] = function()
  vim.cmd("normal! ggyy")

  eq(#sent, 1)
  eq(sent[1], { "first line", "" })
end

-- Regression: with `clipboard=unnamedplus` every delete went there as well, so
-- holding `dd` replaced whatever had been copied with the last line removed.
T["deleting, changing and x leave the system clipboard alone"] = function()
  vim.cmd("normal! ggyy")
  eq(#sent, 1)

  vim.cmd("normal! jdd")
  vim.cmd("normal! ggdw")
  vim.cmd("normal! x")
  vim.cmd("normal! cwreplaced")

  eq(#sent, 1)
  eq(sent[1], { "first line", "" })
end

T["a deleted line can still be put back from inside the editor"] = function()
  vim.cmd("normal! ggddjp")

  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "second line", "third line", "first line" })
  eq(#sent, 0)
end

T["a yank into a named register stays in that register"] = function()
  vim.cmd([[normal! gg"ayy]])

  eq(#sent, 0)
  eq(vim.fn.getreg("a"), "first line\n")
end

return T
