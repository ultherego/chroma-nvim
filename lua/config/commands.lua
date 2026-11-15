-- User commands.

-- Opening a file whose path you already know, with Tab completing it — the
-- other question from the one `<leader>ff` answers. Native completion rather
-- than fzf-lua's `complete.file()`, which does something else entirely.
vim.api.nvim_create_user_command("FindFile", function(args)
  -- Measured: what arrives has already had the command line's escaping removed
  -- and `~` and `$VAR` expanded, so it is the name itself — `two\ words/x` is a
  -- real space, and `50\%.txt` is a real `%`. Pasted back into an Ex command it
  -- was read a second time: `%` became the current file, `#` raised E194, and
  -- everything after a `|` ran as a command of its own. Handed over as an
  -- argument instead, with both of those readings switched off.
  vim.cmd({ cmd = "edit", args = { args.args }, magic = { file = false, bar = false } })
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
