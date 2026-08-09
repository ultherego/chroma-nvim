-- The headless entrypoint the installer drives.
--
-- `install()` is not here: it drives lazy.nvim, Mason and nvim-treesitter, and
-- a test that stubbed all three would prove that the stubs agree with each
-- other. It is covered where it means something — a real installation on a
-- clean XDG, which is the installer's own end-to-end smoke test.
--
-- `verify()` is the half that decides whether an installation is recorded or
-- rolled back, and it is pure enough to check here: it reads the state the
-- editor resolved and says yes or a reason.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local bootstrap = require("chroma.bootstrap")
local state = require("chroma.state")

local T = new_set({
  hooks = {
    pre_case = function()
      state.forget()
    end,
    post_case = function()
      state.forget()
    end,
  },
})

---Runs `fn` with a selection in place, or with none at all.
---@param contents string|nil
---@param fn function
local function with_selection(contents, fn)
  local home = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(home, "chroma"), "p")
  if contents then
    vim.fn.writefile(vim.split(contents, "\n"), vim.fs.joinpath(home, "chroma", "components.json"))
  end

  local saved = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = home
  state.forget()

  local ok, err = pcall(fn)

  vim.env.XDG_CONFIG_HOME = saved
  state.forget()
  vim.fn.delete(home, "rf")
  assert(ok, err)
end

T["verify"] = new_set()

T["verify"]["accepts the installation that was asked for"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform", "vault"] }', function()
    local ok, problem = bootstrap.verify({ "core", "terraform", "vault" })
    eq({ ok, problem }, { true, nil })
  end)
end

-- The installer always writes a selection, so a legacy startup means the file
-- it wrote is not the file the editor read — an installation that came up as
-- something other than what was chosen.
T["verify"]["refuses an installation running everything"] = function()
  with_selection(nil, function()
    local ok, problem = bootstrap.verify({ "core" })
    eq(ok, false)
    eq(problem:find("no selection", 1, true) ~= nil, true)
  end)
end

-- Safe mode starts, which is what safe mode is for, and is not what anybody
-- asked to have installed.
T["verify"]["refuses an installation that came up in safe mode"] = function()
  with_selection('{ "schema": 1, "selected": ["magic"] }', function()
    local notified = vim.notify
    vim.notify = function() end
    local ok, problem = bootstrap.verify({ "core" })
    vim.notify = notified

    eq(ok, false)
    eq(problem:find("safe mode", 1, true) ~= nil, true)
  end)
end

-- The half that matters: an installation that resolved, but not to what the
-- installer selected. Without this, `chroma install --components terraform`
-- could record a success over a Chroma with no Terraform in it.
T["verify"]["refuses when a selected component is not running"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    local ok, problem = bootstrap.verify({ "core", "terraform", "kubernetes" })
    eq(ok, false)
    eq(problem:find("kubernetes", 1, true) ~= nil, true)
  end)
end

T["verify"]["checks that the enabled components' modules load"] = function()
  with_selection('{ "schema": 1, "selected": ["vault"] }', function()
    local ok = bootstrap.verify({ "core", "vault" })
    eq(ok, true)

    -- And notices when one of them does not: the installation would otherwise
    -- be a list of names with nothing behind them.
    local loaded = package.loaded["chroma-vault"]
    package.loaded["chroma-vault"] = nil
    local searchers = package.preload["chroma-vault"]
    package.preload["chroma-vault"] = function()
      error("this module is broken")
    end

    local broken, problem = bootstrap.verify({ "core", "vault" })

    package.preload["chroma-vault"] = searchers
    package.loaded["chroma-vault"] = loaded

    eq(broken, false)
    eq(problem:find("chroma%-vault") ~= nil, true)
  end)
end

-- ---------------------------------------------------------------------------
-- The step the installer actually calls

T["run"] = new_set()

---Runs one Lua command in a Neovim of its own, which is how the installer runs
---these: `run` ends in `cquit`, so it can only be exercised in a process that
---is allowed to exit.
---@param command string
---@param home string XDG_CONFIG_HOME for the child
---@return vim.SystemCompleted
local function headless(command, home)
  local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "--noplugin",
      "-u",
      vim.fs.joinpath(root, "tests", "minimal_init.lua"),
      "-c",
      command,
      "-c",
      "qa!",
    }, { env = { XDG_CONFIG_HOME = home }, text = true })
    :wait()
  vim.fn.delete(home, "rf")
  return result
end

T["run"]["exits non-zero when a step fails"] = function()
  local home = vim.fn.tempname()
  vim.fn.mkdir(home, "p")

  local result = headless('lua require("chroma.bootstrap").run("verify", { "core", "kubernetes" })', home)

  eq(result.code ~= 0, true)
  eq((result.stdout .. result.stderr):find("verify failed", 1, true) ~= nil, true)
end

T["run"]["exits zero when the step is fine"] = function()
  local home = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(home, "chroma"), "p")
  vim.fn.writefile({ '{ "schema": 1, "selected": ["terraform"] }' }, vim.fs.joinpath(home, "chroma", "components.json"))

  local result = headless('lua require("chroma.bootstrap").run("verify", { "core", "terraform" })', home)

  eq(result.code, 0)
  eq((result.stdout .. result.stderr):find("verify ok", 1, true) ~= nil, true)
end

-- In a subprocess, like the two above, and for a reason worth writing down: an
-- earlier version of this case called run() in the test runner itself. run()
-- ends in `cquit` on failure, so it took the whole suite down with it — mid
-- run, with no summary printed. CI reads that summary to decide whether the
-- tests passed, which is the only reason it was noticed at all.
T["run"]["refuses a step it does not know"] = function()
  local result = headless('lua require("chroma.bootstrap").run("reinstall-everything")', vim.fn.tempname())

  eq(result.code ~= 0, true)
  eq((result.stdout .. result.stderr):find("unknown step", 1, true) ~= nil, true)
end

return T
