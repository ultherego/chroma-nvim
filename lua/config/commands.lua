-- User commands.

-- Opening a file whose path you already know, with Tab completing it — the
-- other question from the one `<leader>ff` answers. Native completion rather
-- than fzf-lua's `complete.file()`, which does something else entirely.
vim.api.nvim_create_user_command("FindFile", function(args)
  -- Measured: what arrives has already had the command line's escaping
  -- removed, so `two\ words/x` is a real space here and `:edit` opens it.
  -- `fnameescape` on top changed the outcome of nothing constructible.
  vim.cmd("edit " .. args.args)
end, {
  nargs = 1,
  complete = "file",
  desc = "Open a file by path, completing it with Tab",
})

local function set_autoformat(enabled, buffer_local)
  -- An if, not `enabled and nil or true`: that idiom cannot yield nil.
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
