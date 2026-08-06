-- User commands.
--
-- Only commands that are config-wide belong here. Anything owned by a single
-- plugin is defined in that plugin's spec, so removing the plugin removes its
-- commands with it.
--
-- These two set a plain global flag and are therefore safe to define at
-- startup: they do not require conform to be loaded, and conform reads the
-- flag when deciding whether to format on save.

local function set_autoformat(enabled, scope_is_buffer)
  if scope_is_buffer then
    vim.b.disable_autoformat = not enabled
  else
    vim.g.disable_autoformat = not enabled
    vim.b.disable_autoformat = not enabled
  end
  vim.notify(
    ("Format on save %s%s"):format(enabled and "enabled" or "disabled", scope_is_buffer and " (this buffer)" or ""),
    vim.log.levels.INFO
  )
end

vim.api.nvim_create_user_command("FormatDisable", function(args)
  -- :FormatDisable! disables it for the current buffer only.
  set_autoformat(false, args.bang)
end, {
  desc = "Disable format on save (! for this buffer only)",
  bang = true,
})

vim.api.nvim_create_user_command("FormatEnable", function()
  set_autoformat(true, false)
end, {
  desc = "Re-enable format on save",
})
