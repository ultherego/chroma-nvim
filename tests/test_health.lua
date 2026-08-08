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

return T
