-- Tests for `:checkhealth chroma`.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---Runs the health check and returns its report as one string.
---@return string
local function report()
  vim.cmd("checkhealth chroma")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("silent! bwipeout!")
  return text
end

local T = new_set()

T["core tooling"] = new_set()

-- Regression: Mason unpacks with unzip and gzip, and the core tooling list asked
-- about neither, so a missing one surfaced as an archive error.
T["core tooling"]["asks about every tool Mason needs"] = function()
  local text = report()

  for _, cmd in ipairs({ "git", "curl", "tar", "unzip", "gzip" }) do
    eq({ cmd, text:find("`" .. cmd .. "`", 1, true) ~= nil }, { cmd, true })
  end
end

T["core tooling"]["says what each one is needed for"] = function()
  local text = report()

  eq(text:find("unpacking Mason packages", 1, true) ~= nil, true)
end

T["core tooling"]["still reports the sections it always did"] = function()
  local text = report()

  for _, section in ipairs({ "Neovim", "Core tooling", "Plugin lockfile" }) do
    eq({ section, text:find(section, 1, true) ~= nil }, { section, true })
  end
end

T["neovim"] = new_set()

-- The version is a diagnostic, not the gate. Chroma runs on any Neovim that
-- provides the API it calls, which is what lets 0.13 work without a release
-- here saying it may.
T["neovim"]["passes on this editor and names it"] = function()
  local text = report()

  eq(text:find("every editor API this configuration calls is present", 1, true) ~= nil, true)
  eq(text:find(tostring(vim.version()), 1, true) ~= nil, true)
end

-- And the check is a check: remove an API and it says which one went, and what
-- used to call it. Without this the section would pass on an editor missing
-- everything, which is the failure a version comparison was there to catch.
T["neovim"]["reports an editor API that is gone, and who wanted it"] = function()
  local saved = vim.lsp.config
  vim.lsp.config = nil

  local ok, text = pcall(report)
  vim.lsp.config = saved
  assert(ok, text)

  eq(text:find("vim.lsp.config", 1, true) ~= nil, true)
  eq(text:find("declaring every language server", 1, true) ~= nil, true)
  eq(text:find("missing 1 of the editor APIs", 1, true) ~= nil, true)
end

return T
