-- User commands.

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
