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

T["external tools"] = new_set()

---Puts a directory of fake executables on PATH for one case.
---
---The real PATH is captured once, when this file loads, and restored to that.
---Saving it per call looked equivalent and was not: a case that calls this
---twice saved the first call's temporary directory as the "original", so the
---restore put a deleted directory on PATH and every later file in the suite ran
---without the tools it expected. Measured — it broke 28 cases in terraform and
---vault before this comment existed.
local real_path = vim.env.PATH

---@param names string[]
---@return string dir
local function only_these(names)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for _, name in ipairs(names) do
    local path = vim.fs.joinpath(dir, name)
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
    vim.uv.fs_chmod(path, 493) -- 0755
  end

  vim.env.PATH = dir
  MiniTest.finally(function()
    vim.env.PATH = real_path
    vim.fn.delete(dir, "rf")
  end)

  return dir
end

-- First-present is the rule the installer, `chroma doctor` and the editor all
-- use, so an old terraform never masks a tofu and the three cannot disagree
-- about which binary a machine will run.
T["external tools"]["first answers with the earliest name on PATH"] = function()
  local tools = require("chroma.tools")

  only_these({ "tofu" })
  eq(tools.first({ "terraform", "tofu" }), "tofu")

  only_these({ "terraform", "tofu" })
  eq(tools.first({ "terraform", "tofu" }), "terraform")
end

T["external tools"]["first answers nil when none is there"] = function()
  only_these({})
  eq(require("chroma.tools").first({ "terraform", "tofu" }), nil)
end

T["external tools"]["have answers about one name"] = function()
  local tools = require("chroma.tools")

  only_these({ "kubectl" })
  eq({ tools.have("kubectl"), tools.have("helm") }, { true, false })
end

-- The wording is the substance. A tool the user has not installed is not a
-- fault in Chroma, and the section that lists them says so rather than
-- implying the configuration is broken.
T["external tools"]["are reported as the user's own, not as a failure"] = function()
  local text = report()

  eq(text:find("External tools", 1, true) ~= nil, true)
  eq(text:find("Chroma does not install or manage these", 1, true) ~= nil, true)
end

return T
