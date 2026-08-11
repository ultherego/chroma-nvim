-- Where a task runs, and everything that must not decide it.
--
-- The containment invariant is the reason this file is long: a working
-- directory that escapes the project is a command running against somebody
-- else's infrastructure, and every way out of a directory — `..`, a symlink,
-- a name that merely starts the same — has a case here.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local cwd = require("chroma.tasks.cwd")

local saved = {}

---A project root, created.
---@param name string|nil a name inside the throwaway directory
---@return table source
local function project(name)
  local root = vim.fn.tempname()
  if name then
    root = vim.fs.joinpath(root, name)
  end
  vim.fn.mkdir(root, "p")

  return { root = root, path = vim.fs.joinpath(root, ".chroma", "tasks.json") }
end

---A task with the given cwd.
---@param mode string
---@param path string|nil
---@return table
local function task(mode, path)
  return { id = "x", name = "X", cwd = { mode = mode, path = path }, argv = { "true" } }
end

local T = new_set({
  hooks = {
    pre_case = function()
      saved.cwd = vim.uv.cwd()
    end,
    post_case = function()
      vim.cmd.cd(saved.cwd)
    end,
  },
})

-- ---------------------------------------------------------------------------
-- The two modes

T["modes"] = new_set()

T["modes"]["project runs at the project root"] = function()
  local source = project()

  local directory, problem = cwd.resolve(source, task("project"))

  eq(problem, nil)
  eq(directory, vim.uv.fs_realpath(source.root))
end

T["modes"]["relative runs below it"] = function()
  local source = project()
  vim.fn.mkdir(vim.fs.joinpath(source.root, "terraform", "prod"), "p")

  local directory, problem = cwd.resolve(source, task("relative", "terraform/prod"))

  eq(problem, nil)
  eq(directory, vim.uv.fs_realpath(vim.fs.joinpath(source.root, "terraform", "prod")))
end

T["modes"]["project reads nothing but the root"] = function()
  -- The schema refuses a `path` beside `project`, so the resolver has no
  -- business looking at one: two readers of the same field are two chances to
  -- disagree about which directory an apply runs in.
  local source = project()
  vim.fn.mkdir(vim.fs.joinpath(source.root, "elsewhere"), "p")

  local directory = cwd.resolve(source, task("project", "elsewhere"))

  eq(directory, vim.uv.fs_realpath(source.root))
end

-- ---------------------------------------------------------------------------
-- Staying inside the project

T["containment"] = new_set()

T["containment"]["refuses a path that climbs out"] = function()
  local source = project()

  local directory, problem = cwd.resolve(source, task("relative", "../.."))

  eq(directory, nil)
  eq(problem:find("escapes the project root", 1, true) ~= nil, true)
end

T["containment"]["refuses a symlink that leads out"] = function()
  -- Resolved before it is compared, so a link is not a way around the rule.
  local source = project()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  eq(vim.uv.fs_symlink(outside, vim.fs.joinpath(source.root, "escape")), true)

  local directory, problem = cwd.resolve(source, task("relative", "escape"))

  eq(directory, nil)
  eq(problem:find("escapes the project root", 1, true) ~= nil, true)
end

T["containment"]["refuses a sibling whose name merely starts the same"] = function()
  -- `/project` is a textual prefix of `/project-evil`. The comparison is by
  -- path components, and this is the case that tells the two apart.
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "project"), "p")
  vim.fn.mkdir(vim.fs.joinpath(root, "project-evil"), "p")

  local source = { root = vim.fs.joinpath(root, "project") }
  local directory, problem = cwd.resolve(source, task("relative", "../project-evil"))

  eq(directory, nil)
  eq(problem:find("escapes the project root", 1, true) ~= nil, true)
end

T["containment"]["accepts a project reached through a symlink"] = function()
  -- The root is resolved too, so a project whose path is itself a link is a
  -- perfectly ordinary project — and the directory that comes back is the real
  -- one, which is where the process will actually run.
  local real = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(real, "subdir"), "p")

  local link = vim.fn.tempname()
  eq(vim.uv.fs_symlink(real, link), true)

  local directory, problem = cwd.resolve({ root = link }, task("relative", "subdir"))

  eq(problem, nil)
  eq(directory, vim.fs.joinpath(vim.uv.fs_realpath(real), "subdir"))
end

-- ---------------------------------------------------------------------------
-- What has to be a directory

T["directories"] = new_set()

T["directories"]["refuses a working directory that does not exist"] = function()
  local source = project()

  local directory, problem = cwd.resolve(source, task("relative", "not-here"))

  eq(directory, nil)
  eq(problem:find("does not exist", 1, true) ~= nil, true)
end

T["directories"]["refuses a regular file"] = function()
  -- realpath succeeds for a file and containment would pass; neither makes it
  -- somewhere a process can run.
  local source = project()
  vim.fn.writefile({ "" }, vim.fs.joinpath(source.root, "main.tf"))

  local directory, problem = cwd.resolve(source, task("relative", "main.tf"))

  eq(directory, nil)
  eq(problem:find("is not a directory", 1, true) ~= nil, true)
end

T["directories"]["refuses a project root that is no longer a directory"] = function()
  -- Discovery looked a moment ago. Between then and here the root can become a
  -- file, and comparing against it as though it were still a directory would
  -- accept a containment check that means nothing.
  local root = vim.fn.tempname()
  vim.fn.writefile({ "" }, root)

  local directory, problem = cwd.resolve({ root = root }, task("project"))

  eq(directory, nil)
  eq(problem:find("project root", 1, true) ~= nil, true)
end

T["directories"]["refuses a project root that has gone"] = function()
  local source = project()
  vim.fn.delete(source.root, "rf")

  local directory, problem = cwd.resolve(source, task("project"))

  eq(directory, nil)
  eq(problem:find("does not exist", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- What the editor is doing has nothing to do with it

T["the editor"] = new_set()

T["the editor"]["answers the same wherever Neovim happens to be"] = function()
  -- Discovery used the working directory once, to know where to start. After
  -- that a task's directory belongs to the project it was declared in — `:cd`
  -- between reading a plan and agreeing to it must not move where it runs.
  local source = project()
  vim.fn.mkdir(vim.fs.joinpath(source.root, "plays"), "p")

  local somewhere = vim.fn.tempname()
  vim.fn.mkdir(somewhere, "p")
  vim.cmd.cd(somewhere)
  local first = cwd.resolve(source, task("relative", "plays"))

  local elsewhere = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(elsewhere, "plays"), "p")
  vim.cmd.cd(elsewhere)
  local second = cwd.resolve(source, task("relative", "plays"))

  eq(first, vim.uv.fs_realpath(vim.fs.joinpath(source.root, "plays")))
  eq(second, first)
end

return T
