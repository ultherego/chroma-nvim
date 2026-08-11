-- User commands.

-- Opening a file whose path you already know, with Tab completing it.
--
-- This is the other question from the one `<leader>ff` answers. The fuzzy
-- finder is for "it is called something like config and it is somewhere under
-- roles"; this is for "roles/web/tasks/main.yml", where a fuzzy match over the
-- whole tree is more work than typing the path.
--
-- Native completion, deliberately. fzf-lua has `complete.file()`, but it does
-- something else — it reads a path out of the current line, opens a picker and
-- writes the result back into the buffer — and turning Tab inside `FzfLua
-- files` into shell-style completion would mean fighting what fzf's prompt is
-- for. `complete = "file"` is the completion Neovim already has, and it costs
-- nothing to keep.
vim.api.nvim_create_user_command("FindFile", function(args)
  -- Measured, because it decides whether this needs escaping: what arrives has
  -- already had the command line's escaping removed. `FindFile two\ words/x`
  -- hands this `two words/x`, with a real space, and handing that straight to
  -- `:edit` opens the right file. `fnameescape` on top of it was tried and
  -- changed the outcome of nothing that could be constructed — a space, a `%`,
  -- a `*` — so it is not here.
  vim.cmd("edit " .. args.args)
end, {
  nargs = 1,
  complete = "file",
  desc = "Open a file by path, completing it with Tab",
})

local function set_autoformat(enabled, buffer_local)
  -- Written as an if, not as `enabled and nil or true`. That idiom looks like
  -- a ternary but cannot yield nil: `true and nil` is nil, and `nil or true`
  local value
  if not enabled then
    value = true
  end

  if buffer_local then
    vim.b.disable_autoformat = value
  else
    vim.g.disable_autoformat = value
  end

  vim.notify(
    ("Format on save %s%s"):format(enabled and "enabled" or "disabled", buffer_local and " (this buffer)" or ""),
    vim.log.levels.INFO
  )
end

vim.api.nvim_create_user_command("FormatDisable", function(args)
  set_autoformat(false, args.bang)
end, {
  bang = true,
  desc = "Disable format on save (! for this buffer only)",
})

vim.api.nvim_create_user_command("FormatEnable", function(args)
  set_autoformat(true, args.bang)
end, {
  bang = true,
  desc = "Enable format on save (! for this buffer only)",
})
