-- Tests for `:checkhealth devops`.
--
-- Driven through the real command rather than by reaching into the module, for
-- two reasons. The functions that matter are local to it, and the thing worth
-- protecting is the report a user actually sees — a check that exists but never
-- reaches the output is no check at all.
--
-- The assertions are about which questions are asked, not about the answers.
-- Whether `unzip` happens to be installed on the machine running the suite is
-- not this configuration's business; that it is asked about is.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---Runs the health check and returns its report as one string.
---@return string
local function report()
  vim.cmd("checkhealth devops")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("silent! bwipeout!")
  return text
end

local T = new_set()

T["core tooling"] = new_set()

-- Regression: Mason unpacks its packages with unzip and gzip, and the core
-- tooling list did not mention either. Without them an install runs to the
-- point of unpacking and fails there, which surfaces as a Mason error about an
-- archive rather than as a missing tool.
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
