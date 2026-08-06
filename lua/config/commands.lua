-- User commands.
--
-- Only commands that are config-wide belong here. Anything owned by a single
-- plugin is defined in that plugin's spec, so removing the plugin removes its
-- commands with it.
--
-- These set plain variables and are therefore safe to define at startup: they
-- do not require conform to be loaded, and conform reads them when deciding
-- whether to format on save.
--
-- The global and buffer-local flags are kept strictly separate. An earlier
-- version set both at once when disabling globally, which left every buffer
-- visited in the meantime with a sticky local flag that :FormatEnable could
-- not clear — formatting stayed off in those buffers with nothing to show why.
-- Clearing sets the flag back to nil rather than false, so "no local opinion"
-- stays distinguishable from "explicitly enabled here".

local function set_autoformat(enabled, buffer_local)
  -- Written as an if, not as `enabled and nil or true`. That idiom looks like
  -- a ternary but cannot yield nil: `true and nil` is nil, and `nil or true`
  -- is true, so enabling would set the very flag it means to clear. Caught by
  -- testing the round trip rather than by reading the line.
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
