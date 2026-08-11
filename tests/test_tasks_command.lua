-- Preparing the argument vector and the environment.
--
-- The measurement behind this file: on Neovim 0.12.4 `jobstart` checks the
-- first element of the array before it reads the `env` and `cwd` it was given,
-- so an executable that exists only in the task's PATH, or only in the task's
-- directory, raises E475 while being perfectly present. Every case here is
-- about handing the process layer something that cannot be misread that way —
-- and about leaving every other element exactly as the task wrote it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local command = require("chroma.tasks.command")

local saved = {}

---A directory to work in.
---@return string
local function tree()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

---An executable script at `path`.
---@param path string
local function executable(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "#!/bin/sh", "echo hello" }, path)
  eq(vim.uv.fs_chmod(path, tonumber("755", 8)), true)
end

---A file that exists and cannot be executed.
---@param path string
local function unrunnable(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "not a program" }, path)
  eq(vim.uv.fs_chmod(path, tonumber("644", 8)), true)
end

---@param argv string[]
---@param env table|nil
---@return table
local function task(argv, env)
  return { id = "x", name = "X", cwd = { mode = "project" }, argv = argv, env = env }
end

local T = new_set({
  hooks = {
    pre_case = function()
      saved.path = vim.env.PATH
    end,
    post_case = function()
      vim.env.PATH = saved.path
    end,
  },
})

-- ---------------------------------------------------------------------------
-- Finding the executable

T["argv[0]"] = new_set()

T["argv[0]"]["resolves a bare name through the task's own PATH"] = function()
  -- The case that made resolution necessary at all: a company wrapper that
  -- lives in the repository and is put on the PATH by the task. The editor has
  -- never heard of it.
  local root = tree()
  executable(vim.fs.joinpath(root, "tools", "company-cli"))
  vim.env.PATH = "/usr/bin"

  local prepared, problem =
    command.prepare(task({ "company-cli", "deploy" }, { PATH = vim.fs.joinpath(root, "tools") }), root)

  eq(problem, nil)
  eq(prepared.argv[1], vim.fs.joinpath(root, "tools", "company-cli"))
end

T["argv[0]"]["resolves a path-like name against the task's directory"] = function()
  -- `./scripts/deploy` means the project's script, not one below wherever the
  -- editor happens to be standing.
  local root = tree()
  executable(vim.fs.joinpath(root, "scripts", "deploy"))

  local prepared, problem = command.prepare(task({ "./scripts/deploy" }), root)

  eq(problem, nil)
  eq(prepared.argv[1], vim.fs.joinpath(root, "scripts", "deploy"))
end

T["argv[0]"]["keeps an absolute name as written"] = function()
  local root = tree()
  local path = vim.fs.joinpath(root, "bin", "tool")
  executable(path)

  local prepared, problem = command.prepare(task({ path }), root)

  eq(problem, nil)
  eq(prepared.argv[1], path)
end

T["argv[0]"]["reads a relative PATH entry as relative to the task's directory"] = function()
  -- What the child would do: `execvp` runs after the `chdir`, so `bin` on the
  -- PATH is the project's bin.
  local root = tree()
  executable(vim.fs.joinpath(root, "bin", "deploy"))

  local prepared, problem = command.prepare(task({ "deploy" }, { PATH = "bin:/usr/bin" }), root)

  eq(problem, nil)
  eq(prepared.argv[1], vim.fs.joinpath(root, "bin", "deploy"))
end

T["argv[0]"]["reads an empty PATH entry as the task's directory"] = function()
  -- POSIX, and what `execvp` in the child would do: an empty entry means the
  -- current directory, which for the child is where the task runs. Dropping it
  -- would refuse a command a shell in the same place would have found.
  local root = tree()
  executable(vim.fs.joinpath(root, "deploy"))

  local prepared, problem = command.prepare(task({ "deploy" }, { PATH = ":/usr/bin" }), root)

  eq(problem, nil)
  eq(prepared.argv[1], vim.fs.joinpath(root, "deploy"))
end

T["argv[0]"]["keeps looking past a name it cannot execute"] = function()
  -- A shell would. Stopping at the first entry that merely exists would hide
  -- the real tool further along and refuse a task that works everywhere else.
  local root = tree()
  unrunnable(vim.fs.joinpath(root, "first", "deploy"))
  executable(vim.fs.joinpath(root, "second", "deploy"))

  local prepared, problem = command.prepare(
    task({ "deploy" }, { PATH = ("%s:%s"):format(vim.fs.joinpath(root, "first"), vim.fs.joinpath(root, "second")) }),
    root
  )

  eq(problem, nil)
  eq(prepared.argv[1], vim.fs.joinpath(root, "second", "deploy"))
end

-- ---------------------------------------------------------------------------
-- Refusing

T["refusals"] = new_set()

T["refusals"]["refuses a name that is nowhere on the task's PATH"] = function()
  local root = tree()

  local prepared, problem = command.prepare(task({ "definitely-not-here" }, { PATH = root }), root)

  eq(prepared, nil)
  eq(problem:find("definitely-not-here", 1, true) ~= nil, true)
end

T["refusals"]["refuses a file that exists and is not executable"] = function()
  local root = tree()
  unrunnable(vim.fs.joinpath(root, "scripts", "deploy"))

  local prepared, problem = command.prepare(task({ "./scripts/deploy" }), root)

  eq(prepared, nil)
  eq(problem:find("not an executable file", 1, true) ~= nil, true)
end

T["refusals"]["refuses a directory that has the name of a command"] = function()
  -- A directory answers yes to an execute check — that is what makes it
  -- traversable — so the type has to be asked about as well.
  local root = tree()
  vim.fn.mkdir(vim.fs.joinpath(root, "bin", "deploy"), "p")

  local prepared, problem = command.prepare(task({ "deploy" }, { PATH = vim.fs.joinpath(root, "bin") }), root)

  eq(prepared, nil)
  eq(problem ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Everything else the task wrote

T["arguments"] = new_set()

T["arguments"]["leaves argv[1..] byte for byte"] = function()
  -- Nothing is normalised, quoted, escaped or resolved. A relative inventory
  -- path is the program's to interpret; a semicolon is a semicolon because
  -- nothing here goes near a shell.
  local root = tree()
  local path = vim.fs.joinpath(root, "tool")
  executable(path)

  local arguments = {
    "-i",
    "../inventories/dev/hosts.yml",
    "-e",
    "message=hello world",
    "--tags",
    "foo;bar",
    "$HOME",
    "*.tf",
  }

  local prepared = command.prepare(task(vim.list_extend({ path }, arguments)), root)

  eq(#prepared.argv, #arguments + 1)
  for index, argument in ipairs(arguments) do
    eq(prepared.argv[index + 1], argument)
  end
end

-- ---------------------------------------------------------------------------
-- The environment

T["environment"] = new_set()

T["environment"]["carries the task's overrides"] = function()
  local root = tree()
  local path = vim.fs.joinpath(root, "tool")
  executable(path)

  local prepared = command.prepare(task({ path }, { AWS_PROFILE = "production" }), root)

  eq(prepared.env, { AWS_PROFILE = "production" })
end

T["environment"]["is empty when the task declares none"] = function()
  -- Empty, not absent: what the process inherits is Neovim's environment, and
  -- an override table with nothing in it says exactly that.
  local root = tree()
  local path = vim.fs.joinpath(root, "tool")
  executable(path)

  eq(command.prepare(task({ path })).env, {})
end

T["environment"]["does not carry the inherited environment into the overrides"] = function()
  -- The merge belongs to the process layer. Copying the editor's environment
  -- in here would freeze it at the moment the plan was prepared and show it,
  -- entry by entry, in a preview meant to show what the task changes.
  local root = tree()
  local path = vim.fs.joinpath(root, "tool")
  executable(path)

  local prepared = command.prepare(task({ path }, { AWS_PROFILE = "production" }), root)

  eq(prepared.env.PATH, nil)
  eq(prepared.env.HOME, nil)
end

return T
