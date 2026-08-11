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

-- ---------------------------------------------------------------------------
-- The one feature that asks for more Neovim than Chroma does
--
-- Project tasks reach `vim.secure.read()`, whose command-injection fix landed
-- in 0.12.3. Chroma's own floor is 0.12 and stays there, so an editor between
-- the two is a correct Chroma with one feature missing — and health has to be
-- able to say both things at once.

T["project tasks"] = new_set({
  hooks = {
    post_case = function()
      require("chroma.health").version = vim.version
    end,
  },
})

---The report as seen by an editor claiming to be `version`.
---@param version string
---@return string
local function report_on(version)
  require("chroma.health").version = function()
    return vim.version.parse(version)
  end
  return report()
end

T["project tasks"]["are unavailable below 0.12.3, and say why"] = function()
  local text = report_on("0.12.2")

  eq(text:find("Project tasks unavailable", 1, true) ~= nil, true)
  eq(text:find("0.12.3", 1, true) ~= nil, true)
  -- The reason, not just the number: a version floor with no argument behind
  -- it reads as an arbitrary demand to upgrade.
  eq(text:find("vim.secure.read", 1, true) ~= nil, true)
  eq(text:find("799cbfff8", 1, true) ~= nil, true)
end

T["project tasks"]["are their own section, and a warning rather than a fault"] = function()
  -- Folded into the section above, an editor that provides every API Chroma
  -- calls would either be reported unhealthy for lacking one feature, or —
  -- which is what happened before this — reported as having everything while
  -- one thing refuses to run.
  local text = report_on("0.12.2")

  eq(text:find("Project tasks ~", 1, true) ~= nil, true)

  local reported
  for _, line in ipairs(vim.split(text, "\n")) do
    if line:find("Project tasks unavailable", 1, true) then
      reported = line
    end
  end

  eq(reported ~= nil, true)
  eq(reported:find("WARNING", 1, true) ~= nil, true)
  eq(reported:find("ERROR", 1, true), nil)
end

T["project tasks"]["leave the rest of Chroma reported as healthy"] = function()
  -- Both at once. An editor that provides every API this configuration calls
  -- is a working Chroma even when one feature needs a newer one.
  local text = report_on("0.12.2")

  eq(text:find("every editor API this configuration calls is present", 1, true) ~= nil, true)
  eq(text:find("Project tasks unavailable", 1, true) ~= nil, true)
end

T["project tasks"]["are available from 0.12.3 onwards"] = function()
  for _, version in ipairs({ "0.12.3", "0.12.4", "0.12.10", "0.13.0", "1.0.0" }) do
    local text = report_on(version)
    -- 0.12.10 is the one a string comparison gets wrong.
    eq({ version, text:find("project tasks are available", 1, true) ~= nil }, { version, true })
  end
end

T["project tasks"]["are unavailable on the versions before it"] = function()
  for _, version in ipairs({ "0.12.0", "0.12.1", "0.12.2", "0.11.9" }) do
    local text = report_on(version)
    eq({ version, text:find("Project tasks unavailable", 1, true) ~= nil }, { version, true })
  end
end

T["project tasks"]["treat a prerelease of the floor as below it"] = function()
  -- Semver, and the right answer: 0.12.3-dev is a build of something that is
  -- not 0.12.3 yet, and the fix may or may not be in it.
  eq(report_on("0.12.3-dev"):find("Project tasks unavailable", 1, true) ~= nil, true)
end

T["project tasks"]["are checked without touching a task file or the trust database"] = function()
  -- Trust is evaluated on an explicit Run Task and nowhere else. A health check
  -- that raised the modal, or recorded a decision, would be the one thing the
  -- contract forbids it to do.
  local asked = 0
  local real = vim.secure.read
  vim.secure.read = function(path)
    asked = asked + 1
    return real(path)
  end

  local ok = pcall(report_on, "0.12.2")
  vim.secure.read = real

  eq({ ok, asked }, { true, 0 })
end

return T
