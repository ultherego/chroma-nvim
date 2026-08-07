-- Minimal environment for the test suite.

local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

vim.opt.runtimepath:prepend(root)

-- mini.test comes from wherever lazy.nvim put it, so the suite runs against the
-- version the lockfile pins rather than a separately fetched copy.
local mini_test = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "mini.test")
if not vim.uv.fs_stat(mini_test) then
  vim.api.nvim_err_writeln(("mini.test not found at %s — run :Lazy sync first"):format(mini_test))
  vim.cmd("cquit 1")
end

vim.opt.runtimepath:append(mini_test)

require("mini.test").setup()
